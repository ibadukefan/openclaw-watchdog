#!/bin/bash
#
# OpenClaw Watchdog v3.0 - The Ultimate Guardian
# ================================================
# Compatible with macOS default bash (3.2)
# PROACTIVE: Detects problems BEFORE crashes
# REACTIVE: Attempts recovery after crashes
# CONNECTED: Alerts via Slack, logs to memory files
# SECURE: Input validation, safe file handling
#

set -o pipefail

# ==================== CONFIGURATION ====================

WATCHDOG_DIR="$HOME/.openclaw/watchdog"
LOGFILE="$WATCHDOG_DIR/watchdog.log"
METRICS_FILE="$WATCHDOG_DIR/metrics.json"
STATE_FILE="$WATCHDOG_DIR/state.json"
ALERT_TIMES_FILE="$WATCHDOG_DIR/alert_times"
MEMORY_HISTORY_FILE="$WATCHDOG_DIR/memory_history"
MEMORY_DIR="$HOME/.openclaw/workspace/memory"
CONFIG_FILE="$HOME/.openclaw/openclaw.json"
BACKUP_DRIVE="/Volumes/MacMini+"

GATEWAY_PORT=18789
GATEWAY_URL="http://127.0.0.1:$GATEWAY_PORT"
ANTHROPIC_API="https://api.anthropic.com"

MAX_RESTART_ATTEMPTS=3
CHECK_INTERVAL=60
ALERT_COOLDOWN=1800
LOG_MAX_SIZE_MB=10
LOG_KEEP_COUNT=5

MEMORY_WARNING_MB=500
MEMORY_CRITICAL_MB=800
MEMORY_LEAK_THRESHOLD_MB=50
DISK_WARNING_PERCENT=80
DISK_CRITICAL_PERCENT=90
ERROR_RATE_THRESHOLD=10
RESPONSE_TIME_WARNING_MS=5000
RESPONSE_TIME_CRITICAL_MS=10000

SLACK_ENABLED=true
SLACK_CHANNEL="slack"

RESTART_ATTEMPTS=0

# ==================== SECURITY FUNCTIONS ====================

sanitize() {
    local input="$1"
    echo "$input" | tr -d ';|&`$(){}[]<>\\"'"'"
}

validate_path() {
    local path="$1"
    local allowed_prefix="$2"
    local resolved=$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")
    case "$resolved" in
        "$allowed_prefix"*) return 0 ;;
        *) return 1 ;;
    esac
}

secure_write() {
    local file="$1"
    local content="$2"
    local mode="${3:-600}"
    local tmp=$(mktemp)
    echo "$content" > "$tmp"
    chmod "$mode" "$tmp"
    mv "$tmp" "$file"
}

verify_ownership() {
    local file="$1"
    local owner=$(stat -f %Su "$file" 2>/dev/null)
    [ "$owner" = "$(whoami)" ]
}

# ==================== INITIALIZATION ====================

init_secure_dirs() {
    mkdir -p "$WATCHDOG_DIR" && chmod 700 "$WATCHDOG_DIR"
    mkdir -p "$WATCHDOG_DIR/snapshots" && chmod 700 "$WATCHDOG_DIR/snapshots"
    mkdir -p "$MEMORY_DIR" && chmod 755 "$MEMORY_DIR"
    
    [ ! -f "$STATE_FILE" ] && secure_write "$STATE_FILE" '{"restart_attempts":0}' 600
    [ ! -f "$ALERT_TIMES_FILE" ] && touch "$ALERT_TIMES_FILE" && chmod 600 "$ALERT_TIMES_FILE"
    [ ! -f "$MEMORY_HISTORY_FILE" ] && touch "$MEMORY_HISTORY_FILE" && chmod 600 "$MEMORY_HISTORY_FILE"
}

# ==================== LOGGING ====================

log() {
    local msg="$1"
    local level="${2:-INFO}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $msg"
    echo "$log_line" >> "$LOGFILE"
    echo "$log_line"
}

log_to_memory() {
    local message="$1"
    local today=$(date '+%Y-%m-%d')
    local memory_file="$MEMORY_DIR/${today}.md"
    local timestamp=$(date '+%H:%M')
    
    if ! validate_path "$memory_file" "$MEMORY_DIR"; then
        return
    fi
    
    if [ ! -f "$memory_file" ]; then
        echo "# $today" > "$memory_file"
        echo "" >> "$memory_file"
        echo "## Watchdog Events" >> "$memory_file"
    fi
    
    if ! grep -q "## Watchdog Events" "$memory_file" 2>/dev/null; then
        echo "" >> "$memory_file"
        echo "## Watchdog Events" >> "$memory_file"
    fi
    
    local safe_msg=$(sanitize "$message")
    echo "- [$timestamp] $safe_msg" >> "$memory_file"
}

rotate_logs() {
    local size_bytes=$(stat -f%z "$LOGFILE" 2>/dev/null || echo 0)
    local max_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))
    
    if [ "$size_bytes" -gt "$max_bytes" ]; then
        log "Rotating logs (size: $((size_bytes / 1024 / 1024))MB)"
        
        local i=$((LOG_KEEP_COUNT - 1))
        while [ $i -ge 1 ]; do
            [ -f "${LOGFILE}.$i" ] && mv "${LOGFILE}.$i" "${LOGFILE}.$((i + 1))"
            i=$((i - 1))
        done
        
        mv "$LOGFILE" "${LOGFILE}.1"
        touch "$LOGFILE"
        chmod 600 "$LOGFILE"
        rm -f "${LOGFILE}.$((LOG_KEEP_COUNT + 1))"
    fi
}

# ==================== ALERTING ====================

get_alert_time() {
    local alert_type="$1"
    grep "^${alert_type}:" "$ALERT_TIMES_FILE" 2>/dev/null | cut -d: -f2 || echo 0
}

set_alert_time() {
    local alert_type="$1"
    local now="$2"
    grep -v "^${alert_type}:" "$ALERT_TIMES_FILE" > "${ALERT_TIMES_FILE}.tmp" 2>/dev/null || true
    echo "${alert_type}:${now}" >> "${ALERT_TIMES_FILE}.tmp"
    mv "${ALERT_TIMES_FILE}.tmp" "$ALERT_TIMES_FILE"
}

send_alert() {
    local alert_type="$1"
    local message="$2"
    local severity="${3:-warning}"
    local now=$(date +%s)
    
    alert_type=$(sanitize "$alert_type")
    message=$(sanitize "$message")
    
    local last_time=$(get_alert_time "$alert_type")
    if [ $((now - last_time)) -lt $ALERT_COOLDOWN ]; then
        return
    fi
    
    set_alert_time "$alert_type" "$now"
    
    log "ALERT [$severity] $alert_type: $message" "ALERT"
    log_to_memory "🚨 [$severity] $message"
    
    local sound="Basso"
    [ "$severity" = "critical" ] && sound="Sosumi"
    osascript -e "display notification \"$message\" with title \"🐕 Watchdog [$severity]\" sound name \"$sound\"" 2>/dev/null
    
    if [ "$SLACK_ENABLED" = "true" ]; then
        send_slack_alert "$alert_type" "$message" "$severity"
    fi
}

send_slack_alert() {
    local alert_type="$1"
    local message="$2"
    local severity="$3"
    
    local emoji="⚠️"
    [ "$severity" = "critical" ] && emoji="🚨"
    [ "$severity" = "info" ] && emoji="ℹ️"
    [ "$severity" = "success" ] && emoji="✅"
    
    local slack_msg="$emoji *Watchdog [$severity]*: $message"
    
    # Run in background - openclaw has its own timeout handling
    /opt/homebrew/bin/openclaw message send \
        --channel "$SLACK_CHANNEL" \
        --to "robbie" \
        --message "$slack_msg" \
        --best-effort \
        --timeout-ms 10000 2>/dev/null &
}

# ==================== STATE MANAGEMENT ====================

save_state() {
    local state_json="{\"restart_attempts\": $RESTART_ATTEMPTS, \"last_check\": $(date +%s)}"
    secure_write "$STATE_FILE" "$state_json" 600
}

load_state() {
    if [ -f "$STATE_FILE" ] && verify_ownership "$STATE_FILE"; then
        RESTART_ATTEMPTS=$(cat "$STATE_FILE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('restart_attempts', 0))" 2>/dev/null || echo 0)
    fi
}

save_metrics() {
    local gateway_pid=$(pgrep -f "openclaw-gateway" | head -1)
    local mem_mb=0
    local cpu=0
    
    if [ -n "$gateway_pid" ]; then
        local mem_kb=$(ps -o rss= -p "$gateway_pid" 2>/dev/null | tr -d ' ')
        [ -n "$mem_kb" ] && mem_mb=$((mem_kb / 1024))
        cpu=$(ps -o %cpu= -p "$gateway_pid" 2>/dev/null | tr -d ' ')
    fi
    
    local disk_percent=$(df -h / | awk 'NR==2 {gsub("%",""); print $5}')
    local backup_mounted=$(mount | grep -q "MacMini+" && echo true || echo false)
    local gateway_running=$(check_gateway_process && echo true || echo false)
    local gateway_healthy=$(check_gateway_health && echo true || echo false)
    local api_reachable=$(check_api_connectivity && echo true || echo false)
    
    local metrics_json="{
    \"timestamp\": $(date +%s),
    \"datetime\": \"$(date '+%Y-%m-%d %H:%M:%S')\",
    \"gateway\": {
        \"pid\": ${gateway_pid:-null},
        \"memory_mb\": ${mem_mb:-0},
        \"cpu_percent\": ${cpu:-0}
    },
    \"system\": {
        \"disk_percent\": ${disk_percent:-0},
        \"backup_drive_mounted\": $backup_mounted
    },
    \"health\": {
        \"gateway_running\": $gateway_running,
        \"gateway_healthy\": $gateway_healthy,
        \"api_reachable\": $api_reachable
    }
}"
    secure_write "$METRICS_FILE" "$metrics_json" 644
}

# ==================== MEMORY HISTORY ====================

add_memory_reading() {
    local mem_mb="$1"
    echo "$mem_mb" >> "$MEMORY_HISTORY_FILE"
    # Keep only last 10 readings
    tail -10 "$MEMORY_HISTORY_FILE" > "${MEMORY_HISTORY_FILE}.tmp"
    mv "${MEMORY_HISTORY_FILE}.tmp" "$MEMORY_HISTORY_FILE"
}

get_oldest_memory() {
    head -1 "$MEMORY_HISTORY_FILE" 2>/dev/null || echo 0
}

get_memory_count() {
    wc -l < "$MEMORY_HISTORY_FILE" 2>/dev/null | tr -d ' ' || echo 0
}

# ==================== SESSION SNAPSHOTS ====================

snapshot_sessions() {
    local snapshot_dir="$WATCHDOG_DIR/snapshots"
    local timestamp=$(date '+%Y%m%d-%H%M%S')
    
    log "Creating session snapshot before restart"
    
    local sessions=$(curl -s --max-time 5 "$GATEWAY_URL/api/sessions" 2>/dev/null)
    
    if [ -n "$sessions" ] && [ "$sessions" != "null" ]; then
        secure_write "${snapshot_dir}/sessions-${timestamp}.json" "$sessions" 600
        log "Session snapshot saved: sessions-${timestamp}.json"
    fi
    
    cp -r "$MEMORY_DIR" "${snapshot_dir}/memory-${timestamp}" 2>/dev/null
    chmod -R 700 "${snapshot_dir}/memory-${timestamp}" 2>/dev/null
    
    ls -t "${snapshot_dir}"/sessions-*.json 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null
    ls -dt "${snapshot_dir}"/memory-* 2>/dev/null | tail -n +11 | xargs rm -rf 2>/dev/null
}

# ==================== HEALTH CHECKS ====================

check_gateway_process() {
    pgrep -f "openclaw-gateway" > /dev/null 2>&1
}

check_gateway_health() {
    local start_ms=$(python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null)
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$GATEWAY_URL/" 2>/dev/null)
    local end_ms=$(python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null)
    
    local response_time=$((end_ms - start_ms))
    echo "$response_time" > "$WATCHDOG_DIR/last_response_time"
    
    if [ "$response_time" -gt "$RESPONSE_TIME_CRITICAL_MS" ]; then
        send_alert "response_slow" "Gateway response time critical: ${response_time}ms" "critical"
    elif [ "$response_time" -gt "$RESPONSE_TIME_WARNING_MS" ]; then
        send_alert "response_slow" "Gateway response time slow: ${response_time}ms" "warning"
    fi
    
    [ "$http_code" = "200" ]
}

check_config_exists() {
    [ -f "$CONFIG_FILE" ]
}

check_api_connectivity() {
    local response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$ANTHROPIC_API" 2>/dev/null)
    [ "$response" != "000" ]
}

check_backup_drive() {
    if ! mount | grep -q "MacMini+"; then
        send_alert "backup_drive" "Backup drive /Volumes/MacMini+ is NOT mounted!" "critical"
        return 1
    fi
    return 0
}

check_config_validity() {
    if ! python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
        send_alert "config_invalid" "Config file is invalid JSON!" "critical"
        restore_config_from_backup
        return 1
    fi
    return 0
}

# ==================== PROACTIVE MONITORING ====================

check_memory_usage() {
    local pid=$(pgrep -f "openclaw-gateway" | head -1)
    [ -z "$pid" ] && return
    
    local mem_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$mem_kb" ] && return
    
    local mem_mb=$((mem_kb / 1024))
    add_memory_reading "$mem_mb"
    
    local count=$(get_memory_count)
    if [ "$count" -ge 10 ]; then
        local oldest=$(get_oldest_memory)
        local growth=$((mem_mb - oldest))
        
        if [ "$growth" -gt "$MEMORY_LEAK_THRESHOLD_MB" ]; then
            send_alert "memory_leak" "Possible memory leak: grew ${growth}MB in ~10 min" "warning"
        fi
    fi
    
    if [ "$mem_mb" -gt "$MEMORY_CRITICAL_MB" ]; then
        send_alert "memory_critical" "Gateway using ${mem_mb}MB RAM" "critical"
        attempt_graceful_restart "Memory critical: ${mem_mb}MB"
    elif [ "$mem_mb" -gt "$MEMORY_WARNING_MB" ]; then
        send_alert "memory_warning" "Gateway using ${mem_mb}MB RAM" "warning"
    fi
}

check_disk_space() {
    local disk_percent=$(df -h / | awk 'NR==2 {gsub("%",""); print $5}')
    
    if [ "$disk_percent" -gt "$DISK_CRITICAL_PERCENT" ]; then
        send_alert "disk_critical" "Disk ${disk_percent}% full" "critical"
    elif [ "$disk_percent" -gt "$DISK_WARNING_PERCENT" ]; then
        send_alert "disk_warning" "Disk ${disk_percent}% full" "warning"
    fi
}

check_error_rate() {
    local log_file="/tmp/openclaw/openclaw-stderr.log"
    [ ! -f "$log_file" ] && return
    
    local mod_time=$(stat -f %m "$log_file" 2>/dev/null || echo 0)
    local now=$(date +%s)
    local age=$((now - mod_time))
    
    if [ "$age" -lt 300 ]; then
        local error_count=$(tail -100 "$log_file" | grep -c -i "error\|exception\|fatal" 2>/dev/null || echo 0)
        
        if [ "$error_count" -gt "$ERROR_RATE_THRESHOLD" ]; then
            send_alert "error_rate" "High error rate: $error_count errors in recent log" "warning"
        fi
    fi
}

check_cron_jobs() {
    local cron_status=$(curl -s --max-time 5 "$GATEWAY_URL/api/cron/status" 2>/dev/null)
    
    if [ -n "$cron_status" ]; then
        local failed=$(echo "$cron_status" | python3 -c "import sys,json; jobs=json.load(sys.stdin).get('jobs',[]); print(' '.join([j['name'] for j in jobs if j.get('lastRun',{}).get('status')=='failed']))" 2>/dev/null)
        if [ -n "$failed" ]; then
            send_alert "cron_failed" "Cron job(s) failed: $failed" "warning"
        fi
    fi
}

# ==================== RECOVERY ACTIONS ====================

attempt_graceful_restart() {
    local reason="$1"
    log "Attempting graceful restart via SIGUSR1: $reason"
    
    local pid=$(pgrep -f "openclaw-gateway" | head -1)
    if [ -n "$pid" ]; then
        snapshot_sessions
        kill -SIGUSR1 "$pid" 2>/dev/null
        sleep 5
        
        if check_gateway_health; then
            log "Graceful restart successful"
            log_to_memory "🔄 Graceful restart successful"
            send_alert "restart_success" "Graceful restart completed" "info"
            return 0
        fi
    fi
    
    log "Graceful restart failed"
    return 1
}

attempt_hard_restart() {
    log "Attempting hard restart (attempt $((RESTART_ATTEMPTS + 1))/$MAX_RESTART_ATTEMPTS)..."
    log_to_memory "⚠️ Hard restart attempt $((RESTART_ATTEMPTS + 1))"
    
    snapshot_sessions
    
    launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null
    sleep 10
    
    if check_gateway_health; then
        log "Gateway recovered!"
        log_to_memory "✅ Gateway recovered"
        send_alert "recovery" "Gateway recovered after hard restart" "success"
        RESTART_ATTEMPTS=0
        return 0
    fi
    
    RESTART_ATTEMPTS=$((RESTART_ATTEMPTS + 1))
    return 1
}

restore_config_from_backup() {
    local backup_dir="$BACKUP_DRIVE/openclaw_backup/configs"
    local latest_backup=$(ls -t "${backup_dir}"/openclaw-*.json 2>/dev/null | head -1)
    
    if [ -n "$latest_backup" ] && verify_ownership "$latest_backup"; then
        cp "$latest_backup" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        log "Restored config from $latest_backup"
        send_alert "config_restored" "Config restored from backup" "warning"
    else
        log "ERROR: No valid config backup found!"
        send_alert "config_no_backup" "Config invalid and NO BACKUP FOUND!" "critical"
    fi
}

emergency_backup() {
    local backup_dir="$BACKUP_DRIVE/openclaw_backup/emergency-$(date +%Y%m%d-%H%M%S)"
    
    if [ -d "$BACKUP_DRIVE" ]; then
        log "Creating emergency backup at $backup_dir"
        mkdir -p "$backup_dir" 2>/dev/null
        if [ -d "$backup_dir" ]; then
            chmod 700 "$backup_dir"
            cp -r "$HOME/.openclaw/" "$backup_dir/" 2>/dev/null
            chmod -R 700 "$backup_dir" 2>/dev/null
            log_to_memory "💾 Emergency backup created"
        else
            log "Could not create backup directory" "WARN"
        fi
    fi
}

# ==================== MAIN LOOP ====================

main_loop() {
    log "=========================================" "INFO"
    log "OpenClaw Watchdog v3.0 (Bash 3.2 Compatible) started" "INFO"
    log "=========================================" "INFO"
    log "Gateway: $GATEWAY_URL" "INFO"
    log "PID: $$" "INFO"
    log "User: $(whoami)" "INFO"
    log "=========================================" "INFO"
    
    log_to_memory "🐕 Watchdog v3.0 started"
    
    load_state
    
    local check_count=0
    local last_cron_check=0
    
    while true; do
        check_count=$((check_count + 1))
        
        rotate_logs
        check_disk_space
        check_backup_drive
        check_config_validity || { sleep $CHECK_INTERVAL; continue; }
        
        if ! check_config_exists; then
            log "CRITICAL: Config file missing!" "CRITICAL"
            send_alert "config_missing" "Config file missing!" "critical"
            sleep $CHECK_INTERVAL
            continue
        fi
        
        if ! check_gateway_process; then
            log "Gateway process not found" "WARN"
            
            check_api_connectivity || send_alert "network_issue" "Gateway down AND API unreachable" "critical"
            
            if [ "$RESTART_ATTEMPTS" -lt "$MAX_RESTART_ATTEMPTS" ]; then
                emergency_backup
                attempt_hard_restart
            else
                send_alert "gateway_down" "Gateway down! Max restart attempts reached." "critical"
                RESTART_ATTEMPTS=0
                sleep $ALERT_COOLDOWN
            fi
            
            save_state
            sleep $CHECK_INTERVAL
            continue
        fi
        
        if ! check_gateway_health; then
            log "Gateway not responding" "WARN"
            
            if ! attempt_graceful_restart "Health check failed"; then
                if [ "$RESTART_ATTEMPTS" -lt "$MAX_RESTART_ATTEMPTS" ]; then
                    emergency_backup
                    attempt_hard_restart
                else
                    send_alert "gateway_unresponsive" "Gateway unresponsive! Manual intervention needed." "critical"
                    RESTART_ATTEMPTS=0
                    sleep $ALERT_COOLDOWN
                fi
            fi
            
            save_state
            sleep $CHECK_INTERVAL
            continue
        fi
        
        check_memory_usage
        check_error_rate
        check_api_connectivity || send_alert "api_unreachable" "Anthropic API unreachable" "warning"
        
        local now=$(date +%s)
        if [ $((now - last_cron_check)) -gt 600 ]; then
            check_cron_jobs
            last_cron_check=$now
        fi
        
        RESTART_ATTEMPTS=0
        save_metrics
        save_state
        
        if [ $((check_count % 10)) -eq 0 ]; then
            log "Heartbeat: All systems healthy" "INFO"
        fi
        
        sleep $CHECK_INTERVAL
    done
}

# ==================== STARTUP ====================

init_secure_dirs
send_alert "startup" "Watchdog v3.0 started" "info"
main_loop
