#!/bin/bash
# Removes the distractorRemover privileged helper + sudoers rule.
# Run as root (invoked by the app via osascript "with administrator privileges").
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--clear-hosts" ]; then
    /bin/bash "$SCRIPT_DIR/privileged_helper.sh" --clear
fi
rm -f /usr/local/bin/distractorremover-helper
rm -f /etc/sudoers.d/distractorremover
echo "removed"
