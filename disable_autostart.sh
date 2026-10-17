#!/bin/bash
# Disable "launch at login" for distractorRemover.
LABEL="com.sjk.distractorremover"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "$0")" && pwd)"

WAS_RUNNING=false
if pgrep -f "^/Applications/distractorRemover.app/Contents/MacOS/distractorRemover$" >/dev/null 2>&1 || \
   pgrep -f "$DIR/distractor_remover.py" >/dev/null 2>&1; then
    WAS_RUNNING=true
fi

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

if [ "$WAS_RUNNING" = true ]; then
    if [ -x "/Applications/distractorRemover.app/Contents/MacOS/distractorRemover" ]; then
        open "/Applications/distractorRemover.app"
    elif [ -x "$DIR/.venv/bin/python" ]; then
        "$DIR/.venv/bin/python" "$DIR/distractor_remover.py" >/dev/null 2>&1 &
    fi
fi

echo "✅ Autostart disabled. The current app remains available until you Quit it."
