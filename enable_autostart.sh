#!/bin/bash
# Enable "launch at login" for distractorRemover via a LaunchAgent.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.sjk.distractorremover"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents"
SUPPORT="$HOME/Library/Application Support/distractorRemover"
mkdir -p "$SUPPORT"
LOG="$SUPPORT/launch.log"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/.venv/bin/python</string>
        <string>$DIR/distractor_remover.py</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

# Stop any already-running instance so we don't get two menu bar icons.
pkill -f "distractor_remover.py" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "✅ Autostart enabled. distractorRemover will run at every login (and is starting now)."
