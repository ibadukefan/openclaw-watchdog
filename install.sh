#!/bin/bash
#
# OpenClaw Watchdog Installer
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG_DIR="$HOME/.openclaw/watchdog"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo "🐕 OpenClaw Watchdog Installer"
echo "=============================="
echo ""

# Check for OpenClaw
if ! command -v openclaw &> /dev/null; then
    echo "❌ OpenClaw not found. Please install OpenClaw first."
    echo "   https://github.com/openclaw/openclaw"
    exit 1
fi

echo "✓ OpenClaw found: $(which openclaw)"

# Create directories
echo ""
echo "Creating directories..."
mkdir -p "$WATCHDOG_DIR"
mkdir -p "$WATCHDOG_DIR/snapshots"
chmod 700 "$WATCHDOG_DIR"
chmod 700 "$WATCHDOG_DIR/snapshots"
echo "✓ Created $WATCHDOG_DIR"

# Copy watchdog script
echo ""
echo "Installing watchdog script..."
cp "$SCRIPT_DIR/scripts/openclaw-watchdog.sh" "$WATCHDOG_DIR/"
chmod 700 "$WATCHDOG_DIR/openclaw-watchdog.sh"
echo "✓ Installed watchdog script"

# Install LaunchAgent
echo ""
echo "Installing LaunchAgent..."
mkdir -p "$LAUNCH_AGENTS"

cat > "$LAUNCH_AGENTS/com.spoonseller.openclaw-watchdog.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.spoonseller.openclaw-watchdog</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${HOME}/.openclaw/watchdog/openclaw-watchdog.sh</string>
    </array>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>KeepAlive</key>
    <true/>
    
    <key>StandardOutPath</key>
    <string>${HOME}/.openclaw/watchdog/stdout.log</string>
    
    <key>StandardErrorPath</key>
    <string>${HOME}/.openclaw/watchdog/stderr.log</string>
    
    <key>WorkingDirectory</key>
    <string>${HOME}/.openclaw/watchdog</string>
    
    <key>ProcessType</key>
    <string>Background</string>
    
    <key>LowPriorityBackgroundIO</key>
    <true/>
    
    <key>Nice</key>
    <integer>10</integer>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF

# Fix HOME variable in plist
sed -i '' "s|\${HOME}|$HOME|g" "$LAUNCH_AGENTS/com.spoonseller.openclaw-watchdog.plist"

echo "✓ Installed LaunchAgent"

# Load LaunchAgent
echo ""
echo "Starting watchdog..."
launchctl unload "$LAUNCH_AGENTS/com.spoonseller.openclaw-watchdog.plist" 2>/dev/null || true
launchctl load "$LAUNCH_AGENTS/com.spoonseller.openclaw-watchdog.plist"
echo "✓ Watchdog started"

# Build menu bar app (optional)
echo ""
read -p "Build and install menu bar app? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Building menu bar app..."
    
    if ! command -v swift &> /dev/null; then
        echo "❌ Swift not found. Install Xcode Command Line Tools."
        echo "   xcode-select --install"
    else
        cd "$SCRIPT_DIR"
        swift build -c release
        
        MENU_APP="$SCRIPT_DIR/.build/release/OpenClawWatchdog"
        if [[ -f "$MENU_APP" ]]; then
            cp "$MENU_APP" /usr/local/bin/
            chmod 755 /usr/local/bin/OpenClawWatchdog
            echo "✓ Menu bar app installed to /usr/local/bin/OpenClawWatchdog"
            
            # Add to login items
            osascript -e 'tell application "System Events" to make login item at end with properties {path:"/usr/local/bin/OpenClawWatchdog", hidden:true}' 2>/dev/null || true
            echo "✓ Added to Login Items"
            
            # Start it now
            /usr/local/bin/OpenClawWatchdog &
            echo "✓ Menu bar app started"
        else
            echo "❌ Build failed"
        fi
    fi
fi

echo ""
echo "=============================="
echo "🐕 Installation complete!"
echo ""
echo "The watchdog is now running and will:"
echo "  • Start automatically on login"
echo "  • Monitor your OpenClaw gateway"
echo "  • Alert via Slack and macOS notifications"
echo "  • Auto-recover from crashes"
echo ""
echo "Logs: $WATCHDOG_DIR/watchdog.log"
echo ""
