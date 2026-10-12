#!/bin/bash
# Packages build/Autotime.app into build/Autotime-<version>.dmg with the drag-to-Applications window.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Autotime.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG=build/Autotime-$VERSION.dmg

swift scripts/make-dmg-background.swift build/dmg
tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff

rm -f "$DMG"
uvx --from dmgbuild==1.6.7 dmgbuild -s scripts/dmg-settings.py \
  -D app="$APP" -D background=build/dmg/background.tiff -D volume_icon=build/AppIcon.icns \
  "Autotime" "$DMG"

IDENTITY="${CODESIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$DMG"
echo "$DMG"
