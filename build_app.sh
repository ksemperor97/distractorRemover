#!/bin/bash
# Build a self-contained macOS menu-bar app and optionally install it.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

PY="${PYTHON:-$DIR/.venv/bin/python}"
VERSION="$(tr -d '[:space:]' < "$DIR/VERSION")"
if [ ! -x "$PY" ]; then
    echo "❌ Run ./install.sh first." >&2
    exit 1
fi

"$PY" -m pip install -r requirements-build.txt -q
rm -rf build dist

"$PY" -m PyInstaller \
    --noconfirm \
    --clean \
    --specpath build \
    --windowed \
    --name distractorRemover \
    --osx-bundle-identifier com.sjk.distractorremover \
    --add-data "$DIR/schedule_editor.py:." \
    --add-data "$DIR/install_helper.sh:." \
    --add-data "$DIR/uninstall_helper.sh:." \
    --add-data "$DIR/privileged_helper.sh:." \
    --add-data "$DIR/VERSION:." \
    --hidden-import schedule_editor \
    distractor_remover.py

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "dist/distractorRemover.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
    "dist/distractorRemover.app/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" \
        "dist/distractorRemover.app/Contents/Info.plist"

for resource in VERSION schedule_editor.py install_helper.sh uninstall_helper.sh privileged_helper.sh; do
    if [ ! -f "dist/distractorRemover.app/Contents/Resources/$resource" ]; then
        echo "❌ Missing bundled resource: $resource" >&2
        exit 1
    fi
done

codesign --force --deep --sign - "dist/distractorRemover.app"
codesign --verify --deep --strict "dist/distractorRemover.app"

if [ "${1:-}" = "--install" ]; then
    pkill -x distractorRemover 2>/dev/null || true
    rm -rf "/Applications/distractorRemover.app"
    cp -R "dist/distractorRemover.app" /Applications/
    if [ -f "$HOME/Library/LaunchAgents/com.sjk.distractorremover.plist" ]; then
        "$DIR/enable_autostart.sh"
    else
        open "/Applications/distractorRemover.app"
    fi
    echo "✅ Built, installed, and launched /Applications/distractorRemover.app"
else
    echo "✅ Built $DIR/dist/distractorRemover.app"
fi
