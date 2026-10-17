#!/bin/bash
# Fully remove the installed app, launch agent, managed hosts section, and
# password-free helper. Pass --remove-config to remove saved sites/schedules.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REMOVE_CONFIG=false
ASSUME_YES=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --remove-config) REMOVE_CONFIG=true ;;
        --yes) ASSUME_YES=true ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "usage: $0 [--remove-config] [--yes] [--dry-run]" >&2; exit 64 ;;
    esac
done

if [ "$DRY_RUN" = true ]; then
    echo "Would unload and remove: $HOME/Library/LaunchAgents/com.sjk.distractorremover.plist"
    echo "Would stop distractorRemover processes"
    echo "Would clear the distractorRemover /etc/hosts section"
    echo "Would remove helper and sudoers rule"
    echo "Would remove: /Applications/distractorRemover.app"
    if [ "$REMOVE_CONFIG" = true ]; then
        echo "Would remove: $HOME/Library/Application Support/distractorRemover"
    else
        echo "Would keep saved config and logs"
    fi
    exit 0
fi

if [ "$ASSUME_YES" != true ]; then
    printf 'Remove distractorRemover and clear its /etc/hosts section? [y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

PLIST="$HOME/Library/LaunchAgents/com.sjk.distractorremover.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
pkill -f "distractor_remover.py" 2>/dev/null || true
pkill -x "distractorRemover" 2>/dev/null || true

/usr/bin/osascript - "$DIR/uninstall_helper.sh" <<'APPLESCRIPT'
on run argv
    set scriptPath to item 1 of argv
    do shell script "/bin/bash " & quoted form of scriptPath & " --clear-hosts" with administrator privileges
end run
APPLESCRIPT

if ! rm -rf "/Applications/distractorRemover.app" 2>/dev/null; then
    /usr/bin/osascript -e 'do shell script "/bin/rm -rf /Applications/distractorRemover.app" with administrator privileges'
fi

if [ "$REMOVE_CONFIG" = true ]; then
    rm -rf "$HOME/Library/Application Support/distractorRemover"
fi

echo "✅ distractorRemover removed."
