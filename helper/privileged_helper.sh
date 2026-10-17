#!/bin/bash
# Root-owned runtime helper. It accepts validated domains on stdin and manages
# only distractorRemover's marked /etc/hosts section; it never reads a
# user-selected path.
set -euo pipefail
export LC_ALL=C

VERSION=4
HOSTS=/etc/hosts
TEST_MODE=false
if [ "$(id -u)" -ne 0 ] && [ -n "${DISTRACTORREMOVER_TEST_HOSTS:-}" ]; then
    HOSTS="$DISTRACTORREMOVER_TEST_HOSTS"
    TEST_MODE=true
fi
MARK_START='# === distractorRemover START (managed automatically — do not edit) ==='
MARK_END='# === distractorRemover END ==='

case "${1:-}" in
    --version)
        echo "$VERSION"
        exit 0
        ;;
    --check)
        [ "$(id -u)" -eq 0 ] || { echo "not root" >&2; exit 10; }
        echo "ready $VERSION"
        exit 0
        ;;
    --apply|--clear|--reset)
        ACTION="$1"
        ;;
    *)
        echo "usage: distractorremover-helper --check|--apply|--clear|--reset" >&2
        exit 64
        ;;
esac

if [ "$(id -u)" -ne 0 ] && [ "$TEST_MODE" != true ]; then
    echo "must run as root" >&2
    exit 10
fi
[ -f "$HOSTS" ] || { echo "hosts file missing" >&2; exit 11; }

if [ "$ACTION" != "--reset" ]; then
    # Every START must be followed by its END before the next START. Equal
    # counts are not enough: reversed or nested markers would make the strip
    # below delete the user's own lines. Leave such a file exactly as it is.
    awk -v start="$MARK_START" -v end="$MARK_END" '
        $0 == start { if (inside) { bad = 1; exit } inside = 1; next }
        $0 == end { if (!inside) { bad = 1; exit } inside = 0; next }
        END { if (bad || inside) exit 1 }
    ' "$HOSTS" || {
        echo "the distractorRemover markers in the hosts file are damaged (missing, reversed or nested); refusing to rewrite" >&2
        exit 12
    }
fi

HOSTS_DIR="$(cd "$(dirname "$HOSTS")" && pwd)"
TMP=$(mktemp "$HOSTS_DIR/.distractorremover.hosts.XXXXXX")
SEEN=$(mktemp /tmp/distractorremover.domains.XXXXXX)
cleanup() { rm -f "$TMP" "$SEEN"; }
trap cleanup EXIT INT TERM

BACKUP=""
if [ "$ACTION" = "--reset" ]; then
    # A reset is intentionally separate from normal apply/clear: it is the
    # explicit recovery path for an orphaned marker. Preserve a byte-for-byte
    # backup first because an incomplete section has an ambiguous boundary.
    BACKUP="${HOSTS}.distractorremover-backup-$(date +%Y%m%d-%H%M%S)-$$"
    cp -p "$HOSTS" "$BACKUP"
    awk -v start="$MARK_START" -v end="$MARK_END" '
        function emit(line) {
            if (line == "") { blanks++; return }
            for (i = 0; i < blanks; i++) print ""
            blanks = 0
            print line
        }
        $0 == start { managed = 1; next }
        $0 == end { managed = 0; next }
        managed && $0 ~ /^(127\.0\.0\.1|::1)\t[a-z0-9.-]+$/ { next }   # only lines in the app format
        managed { managed = 0 }
        { emit($0) }
    ' "$HOSTS" > "$TMP"
else
    # Strip every complete managed section and normalize trailing empty lines
    # to match the app renderer without touching unmanaged non-empty lines.
    awk -v start="$MARK_START" -v end="$MARK_END" '
        $0 == start { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip {
            if ($0 == "") { blanks++; next }
            for (i = 0; i < blanks; i++) print ""
            blanks = 0
            print
        }
    ' "$HOSTS" > "$TMP"
fi
[ -s "$TMP" ] || printf '\n' > "$TMP"

if [ "$ACTION" = "--apply" ]; then
    count=0
    while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        [ "${#domain}" -le 253 ] || { echo "domain too long" >&2; exit 20; }
        [[ "$domain" == *.* ]] || { echo "domain needs a dot: $domain" >&2; exit 21; }
        [[ "$domain" != *..* ]] || { echo "invalid domain: $domain" >&2; exit 22; }
        [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || {
            echo "invalid domain: $domain" >&2; exit 23;
        }
        old_ifs=$IFS
        IFS='.'
        read -r -a labels <<< "$domain"
        IFS=$old_ifs
        for label in "${labels[@]}"; do
            [ "${#label}" -le 63 ] || { echo "domain label too long" >&2; exit 24; }
            [[ "$label" != -* && "$label" != *- ]] || {
                echo "invalid domain label: $label" >&2; exit 25;
            }
        done
        if ! grep -Fqx "$domain" "$SEEN"; then
            printf '%s\n' "$domain" >> "$SEEN"
            count=$((count + 1))
        fi
        [ "$count" -le 512 ] || { echo "too many domains" >&2; exit 26; }
    done

    [ "$count" -gt 0 ] || { echo "no domains supplied" >&2; exit 27; }
    printf '%s\n' "$MARK_START" >> "$TMP"
    while IFS= read -r domain; do
        printf '127.0.0.1\t%s\n' "$domain" >> "$TMP"
        printf '::1\t%s\n' "$domain" >> "$TMP"
    done < "$SEEN"
    printf '%s\n' "$MARK_END" >> "$TMP"
fi

owner=$(stat -f '%u' "$HOSTS")
group=$(stat -f '%g' "$HOSTS")
mode=$(stat -f '%Lp' "$HOSTS")
chown "$owner:$group" "$TMP"
chmod "$mode" "$TMP"
mv -f "$TMP" "$HOSTS"
trap - EXIT INT TERM
rm -f "$SEEN"

dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true
if [ -n "$BACKUP" ]; then
    echo "backup: $BACKUP"
fi
