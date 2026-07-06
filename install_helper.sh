#!/bin/bash
# Installs a small root-owned helper + a NOPASSWD sudoers rule so that
# distractorRemover can update /etc/hosts (block/unblock, including on a
# schedule) without prompting for a password each time.
#
# Run as root (the app invokes it via osascript "with administrator privileges").
# Usage: install_helper.sh <login-username>
set -e

USER_NAME="$1"
if [ -z "$USER_NAME" ]; then
    echo "usage: install_helper.sh <username>" >&2
    exit 64
fi

HELPER=/usr/local/bin/distractorremover-helper
SUDOERS=/etc/sudoers.d/distractorremover   # no dot in name (sudo ignores those)

mkdir -p /usr/local/bin

# --- the privileged helper -------------------------------------------------
cat > "$HELPER" <<'HELPER_EOF'
#!/bin/bash
# distractorRemover privileged helper.
# Copies a user-staged hosts file into /etc/hosts and flushes DNS.
# Locked down: only accepts a file named .../distractorRemover/hosts.staged
# that is owned by the invoking (sudo) user, so it can't be abused to read
# root-only files via world-readable /etc/hosts.
set -e
STAGED="$1"
case "$STAGED" in
    */distractorRemover/hosts.staged) ;;
    *) echo "refusing: unexpected staged path" >&2; exit 2 ;;
esac
[ -f "$STAGED" ] || { echo "refusing: staged file missing" >&2; exit 3; }
OWNER=$(stat -f '%Su' "$STAGED")   # stat follows symlinks -> catches link tricks
if [ -n "$SUDO_USER" ] && [ "$OWNER" != "$SUDO_USER" ]; then
    echo "refusing: staged file not owned by caller" >&2
    exit 4
fi
cp "$STAGED" /etc/hosts
dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true
HELPER_EOF

chown root:wheel "$HELPER"
chmod 755 "$HELPER"

# --- the sudoers rule (validated before install) ---------------------------
TMP_SUDO=$(mktemp)
printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" "$HELPER" > "$TMP_SUDO"
if visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
    install -m 440 -o root -g wheel "$TMP_SUDO" "$SUDOERS"
    rm -f "$TMP_SUDO"
    echo "installed"
else
    rm -f "$TMP_SUDO"
    echo "sudoers validation failed — not installing" >&2
    exit 5
fi
