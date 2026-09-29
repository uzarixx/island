#!/bin/bash
# Builds Island.app for Apple Silicon and Intel and packs it into build/Island-<version>.dmg:
# open the disk image, drag Island onto Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh --universal

APP=build/Island.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Island-$VERSION.dmg"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
# --norsrc: no extended attributes from this Mac (like quarantine) go into the image.
ditto --norsrc "$APP" "$STAGING/Island.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Island" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
