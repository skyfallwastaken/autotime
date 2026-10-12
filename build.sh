#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

PLUGIN=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib
FLAGS=()
if [ -f "$PLUGIN" ]; then
  FLAGS=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
fi

swift build -c release "${FLAGS[@]}"
BIN="$(swift build -c release --show-bin-path)"

APP=build/Autotime.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Autotime" "$APP/Contents/MacOS/Autotime"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Autotime"

# VERSION (e.g. 1.2.0) and BUILD_NUMBER (monotonic; Sparkle compares it) are set by the release workflow.
[ -n "${VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
[ -n "${BUILD_NUMBER:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable identity keeps the Accessibility permission across rebuilds and Sparkle updates.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
SIGN=(codesign --force --sign "${IDENTITY:--}" --options runtime)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP"
echo "Built $APP $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") (signed with ${IDENTITY:-ad-hoc})"
