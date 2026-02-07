# 🐕 OpenClaw Watchdog

> The ultimate guardian for your OpenClaw gateway. Proactive monitoring, automatic recovery, and a cute bulldog in your menu bar.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

### 🔍 Proactive Monitoring
- **Memory tracking** with leak detection (alerts if memory grows 50MB+ in 10 minutes)
- **Response time monitoring** (warns at 5s, critical at 10s)
- **Disk space alerts** (80% warning, 90% critical)
- **Error rate detection** in gateway logs
- **Config file validation** (auto-restores from backup if corrupted)
- **API connectivity checks** (Anthropic endpoint reachability)
- **Backup drive monitoring** (alerts if external drive unmounted)
- **Cron job health checks**

### 🔄 Automatic Recovery
- **Graceful restart** via SIGUSR1 (tries this first)
- **Hard restart** via launchctl (if graceful fails)
- **Session snapshots** before any restart
- **Emergency backups** before intervention
- **Config auto-restore** from backup

### 📢 Alerting
- **Slack notifications** (via OpenClaw message tool)
- **macOS notifications** with appropriate sounds
- **Memory file logging** (writes to daily `.md` files)
- **Alert cooldowns** (30 min between same alerts)

### 🐕 Menu Bar App
- Real-time status indicator (green/yellow/red)
- Quick stats: memory, disk, gateway status
- View logs directly
- Manual restart button
- Open gateway dashboard

## Installation

### Prerequisites
- macOS 13+
- [OpenClaw](https://github.com/openclaw/openclaw) installed
- Swift 5.9+ (included with Xcode)

### Quick Install

```bash
# Clone the repo
git clone https://github.com/spoonseller/openclaw-watchdog.git
cd openclaw-watchdog

# Run installer
./install.sh
```

### Manual Install

```bash
# 1. Copy the watchdog script
mkdir -p ~/.openclaw/watchdog
cp scripts/openclaw-watchdog.sh ~/.openclaw/watchdog/
chmod 700 ~/.openclaw/watchdog/openclaw-watchdog.sh

# 2. Install LaunchAgent
cp resources/com.spoonseller.openclaw-watchdog.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.spoonseller.openclaw-watchdog.plist

# 3. Build and install the menu bar app (optional)
swift build -c release
cp .build/release/OpenClawWatchdog /usr/local/bin/

# 4. Add menu bar app to Login Items
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/usr/local/bin/OpenClawWatchdog", hidden:true}'
```

## Configuration

The watchdog uses sensible defaults but you can customize thresholds by editing the script:

```bash
# Memory thresholds (MB)
MEMORY_WARNING_MB=500
MEMORY_CRITICAL_MB=800
MEMORY_LEAK_THRESHOLD_MB=50

# Disk thresholds (%)
DISK_WARNING_PERCENT=80
DISK_CRITICAL_PERCENT=90

# Response time thresholds (ms)
RESPONSE_TIME_WARNING_MS=5000
RESPONSE_TIME_CRITICAL_MS=10000

# Check interval (seconds)
CHECK_INTERVAL=60

# Slack alerts
SLACK_ENABLED=true
SLACK_CHANNEL="slack"
```

## Security

See [SECURITY.md](SECURITY.md) for detailed security information.

Key security features:
- No `eval` or dynamic code execution
- Input sanitization on all external data
- Secure file permissions (700 for sensitive dirs, 600 for configs)
- File ownership verification
- No hardcoded secrets
- Timeout on all network operations

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                    OpenClaw Watchdog v3.0                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │   Monitor   │───▶│   Detect    │───▶│   Alert     │         │
│  │   (60s)     │    │   Issues    │    │   & Log     │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│         │                  │                   │                │
│         │                  ▼                   │                │
│         │         ┌─────────────┐              │                │
│         │         │   Recover   │◀─────────────┘                │
│         │         │   (auto)    │                               │
│         │         └─────────────┘                               │
│         │                  │                                    │
│         ▼                  ▼                                    │
│  ┌─────────────────────────────────────────┐                   │
│  │           metrics.json / state.json      │                   │
│  └─────────────────────────────────────────┘                   │
│                          │                                      │
│                          ▼                                      │
│  ┌─────────────────────────────────────────┐                   │
│  │         Menu Bar App (reads state)       │                   │
│  └─────────────────────────────────────────┘                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Files

| Path | Purpose |
|------|---------|
| `~/.openclaw/watchdog/watchdog.log` | Main log file (rotated at 10MB) |
| `~/.openclaw/watchdog/metrics.json` | Current system metrics |
| `~/.openclaw/watchdog/state.json` | Watchdog state (restart attempts, memory history) |
| `~/.openclaw/watchdog/snapshots/` | Session snapshots before restarts |

## Troubleshooting

### Watchdog not starting
```bash
# Check if loaded
launchctl list | grep watchdog

# View stderr
cat ~/.openclaw/watchdog/stderr.log

# Reload
launchctl unload ~/Library/LaunchAgents/com.spoonseller.openclaw-watchdog.plist
launchctl load ~/Library/LaunchAgents/com.spoonseller.openclaw-watchdog.plist
```

### Too many alerts
Increase the cooldown or adjust thresholds in the script.

### Slack alerts not working
Ensure OpenClaw is configured with Slack and the `openclaw message send` command works:
```bash
openclaw message send --channel slack --to robbie --message "test"
```

## Contributing

PRs welcome! Please read [SECURITY.md](SECURITY.md) before contributing.

## License

MIT - See [LICENSE](LICENSE)

## Credits

Built for [OpenClaw](https://github.com/openclaw/openclaw) by [@robbieleffel](https://twitter.com/robbieleffel) and Bob'sYourUncle 🦞
