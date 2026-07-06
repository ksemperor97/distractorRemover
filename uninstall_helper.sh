#!/bin/bash
# Removes the distractorRemover privileged helper + sudoers rule.
# Run as root (invoked by the app via osascript "with administrator privileges").
rm -f /usr/local/bin/distractorremover-helper
rm -f /etc/sudoers.d/distractorremover
echo "removed"
