#!/bin/bash
# Build distractorRemover.app from the Swift package. Needs only the Xcode
# Command Line Tools.
#   --install  also copy it to /Applications and launch it
#   --zip      also make dist/distractorRemover-<version>.zip for a release
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$DIR/dist/distractorRemover.app"
IDENTITY="${CODESIGN_IDENTITY:--}"   # ad-hoc unless a Developer ID is given

swift build -c release --product distractorRemover
BIN="$(swift build -c release --show-bin-path)/distractorRemover"

rm -rf "$DIR/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/distractorRemover"
for resource in privileged_helper.sh install_helper.sh uninstall_helper.sh; do
    install -m 755 "helper/$resource" "$APP/Contents/Resources/$resource"
done

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.sjk.distractorremover</string>
    <key>CFBundleName</key><string>distractorRemover</string>
    <key>CFBundleDisplayName</key><string>distractorRemover</string>
    <key>CFBundleExecutable</key><string>distractorRemover</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "${1:-}" = "--zip" ]; then
    # ditto keeps the code signature intact; plain zip can break it.
    ditto -c -k --keepParent "$APP" "$DIR/dist/distractorRemover-$VERSION.zip"
    echo "✅ Built $APP and dist/distractorRemover-$VERSION.zip (v$VERSION)"
elif [ "${1:-}" = "--install" ]; then
    pkill -x distractorRemover 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/distractorRemover.app"
    cp -R "$APP" /Applications/
    open "/Applications/distractorRemover.app"
    echo "✅ Built, installed, and launched /Applications/distractorRemover.app (v$VERSION)"
else
    echo "✅ Built $APP (v$VERSION)"
fi
