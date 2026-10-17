#!/bin/bash
# Installs a small root-owned helper + a NOPASSWD sudoers rule so that
# distractorRemover can update /etc/hosts (block/unblock, including on a
# schedule) without prompting for a password each time.
#
# Run as root (the app invokes it via osascript "with administrator privileges").
# Usage: install_helper.sh <login-username>
set -euo pipefail

USER_NAME="$1"
if [ -z "$USER_NAME" ]; then
    echo "usage: install_helper.sh <username>" >&2
    exit 64
fi
case "$USER_NAME" in
    *[!A-Za-z0-9._-]*) echo "refusing unsafe username" >&2; exit 65 ;;
esac
id "$USER_NAME" >/dev/null 2>&1 || { echo "unknown user: $USER_NAME" >&2; exit 67; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_SOURCE="$SCRIPT_DIR/privileged_helper.sh"
HELPER=/usr/local/bin/distractorremover-helper
SUDOERS=/etc/sudoers.d/distractorremover   # no dot in name (sudo ignores those)

mkdir -p /usr/local/bin
[ -f "$HELPER_SOURCE" ] || { echo "helper source missing" >&2; exit 66; }
# VERSION= in privileged_helper.sh is the single source of the helper version.
EXPECTED_VERSION=$(/bin/bash "$HELPER_SOURCE" --version)
case "$EXPECTED_VERSION" in
    ''|*[!0-9]*) echo "helper source reports an invalid version" >&2; exit 66 ;;
esac

# --- the privileged helper -------------------------------------------------
TMP_HELPER=$(mktemp /usr/local/bin/.distractorremover-helper.XXXXXX)
install -m 755 -o root -g wheel "$HELPER_SOURCE" "$TMP_HELPER"
"$TMP_HELPER" --version | grep -qx "$EXPECTED_VERSION" || {
    rm -f "$TMP_HELPER"
    echo "helper version validation failed" >&2
    exit 4
}

# --- the sudoers rule (validated before install) ---------------------------
TMP_SUDO=$(mktemp /etc/sudoers.d/.distractorremover.XXXXXX)
printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" "$HELPER" > "$TMP_SUDO"
if ! visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
    rm -f "$TMP_SUDO" "$TMP_HELPER"
    echo "sudoers validation failed — not installing" >&2
    exit 5
fi

# Keep the previous pair out of the way until the new pair passes its real
# NOPASSWD health check. The EXIT trap restores both files on every failure.
BACKUP_DIR=$(mktemp -d /tmp/distractorremover-helper-install.XXXXXX)
HAD_HELPER=false
HAD_SUDOERS=false
INSTALL_STARTED=false
COMMITTED=false

rollback_or_cleanup() {
    rc=$?
    trap - EXIT INT TERM HUP
    if [ "$COMMITTED" != true ] && [ "$INSTALL_STARTED" = true ]; then
        if [ "$HAD_HELPER" = true ]; then
            if [ -e "$BACKUP_DIR/helper" ] || [ -L "$BACKUP_DIR/helper" ]; then
                rm -f "$HELPER"
                mv -f "$BACKUP_DIR/helper" "$HELPER"
            fi
        else
            rm -f "$HELPER"
        fi
        if [ "$HAD_SUDOERS" = true ]; then
            if [ -e "$BACKUP_DIR/sudoers" ] || [ -L "$BACKUP_DIR/sudoers" ]; then
                rm -f "$SUDOERS"
                mv -f "$BACKUP_DIR/sudoers" "$SUDOERS"
            fi
        else
            rm -f "$SUDOERS"
        fi
    fi
    rm -f "$TMP_HELPER" "$TMP_SUDO"
    rm -rf "$BACKUP_DIR"
    exit "$rc"
}
trap rollback_or_cleanup EXIT
trap 'exit 130' INT TERM HUP

INSTALL_STARTED=true
if [ -e "$HELPER" ] || [ -L "$HELPER" ]; then
    HAD_HELPER=true
    mv "$HELPER" "$BACKUP_DIR/helper"
fi
if [ -e "$SUDOERS" ] || [ -L "$SUDOERS" ]; then
    HAD_SUDOERS=true
    mv "$SUDOERS" "$BACKUP_DIR/sudoers"
fi

chown root:wheel "$TMP_HELPER"
chmod 755 "$TMP_HELPER"
mv "$TMP_HELPER" "$HELPER"
chown root:wheel "$TMP_SUDO"
chmod 440 "$TMP_SUDO"
mv "$TMP_SUDO" "$SUDOERS"

if ! /usr/bin/sudo -u "$USER_NAME" /usr/bin/sudo -n "$HELPER" --check \
    | grep -qx "ready $EXPECTED_VERSION"; then
    echo "installed helper failed its NOPASSWD health check" >&2
    exit 6
fi

COMMITTED=true
echo "installed v$EXPECTED_VERSION"
