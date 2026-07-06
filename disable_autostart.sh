#!/bin/bash
# Disable "launch at login" for distractorRemover.
LABEL="com.sjk.distractorremover"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "✅ Autostart disabled. (The app keeps running until you Quit it or reboot.)"
