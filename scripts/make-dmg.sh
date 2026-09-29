#!/bin/bash
# Builds Island.app for Apple Silicon and Intel and packs it into build/Island-<version>.dmg:
# open the disk image, drag Island onto Applications.
#
#   scripts/make-dmg.sh                    the current version
#   scripts/make-dmg.sh 1.2.0|patch|minor|major   sets a new one first (see version.sh)
#
# The window is laid out by Finder (the first run asks to let the terminal control Finder):
# a background with an arrow (scripts/render-dmg-background.swift), big icons in place, and
# Island's icon on the disk itself.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
    scripts/version.sh "$1"
fi
scripts/build.sh --universal

APP=build/Island.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Island-$VERSION.dmg"
VOLUME="Island"
# Must match the layout in render-dmg-background.swift: a 660×400 window, icon centers.
WINDOW_WIDTH=660
WINDOW_HEIGHT=400
APP_POSITION="170, 200"
APPLICATIONS_POSITION="490, 200"

# diskutil reports its progress ("[42% completed]") on stderr; let only real messages through.
quiet_progress() {
    tr '\r' '\n' | grep -v -E '^ *(\[[0-9]+% completed\] *)*$' >&2 || true
}

WORK=$(mktemp -d)
MOUNT="$WORK/mount"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

STAGING="$WORK/staging"
mkdir -p "$STAGING/.background"
# --norsrc: no extended attributes from this Mac (like quarantine) go into the image.
ditto --norsrc "$APP" "$STAGING/Island.app"
ln -s /Applications "$STAGING/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
SDKROOT="${SDK:-}" swift scripts/render-dmg-background.swift "$STAGING/.background/background.tiff" >/dev/null

# Finder finds disks by name: with another Island disk open it would lay out that one. Images
# built here are ejected; any other has to be ejected by hand. (A disk can't be renamed after the
# layout instead: the background is remembered together with the disk's name.)
while IFS=$'\t' read -r image mount; do
    if [[ "$image" == "$PWD/build/"* ]]; then
        hdiutil detach "$mount" -quiet
    else
        echo "Eject the Island disk first: it's open from $image" >&2
        exit 1
    fi
done < <(hdiutil info | awk -F'\t' '/^image-path/ { sub(/^image-path *: /, ""); image = $0 } $NF ~ /^\/Volumes\/Island( [0-9]+)?$/ { print image "\t" $NF }')

# Writable first, so Finder can save the window's layout into it.
diskutil image create from "$STAGING" "$WORK/rw.dmg" --format RAW --volumeName "$VOLUME" 2>&1 >/dev/null | quiet_progress
mkdir -p "$MOUNT"
hdiutil attach "$WORK/rw.dmg" -mountpoint "$MOUNT" -noautoopen -quiet
# The disk shows Island's icon.
SetFile -a C "$MOUNT"

osascript <<EOF
tell application "Finder"
    set theDisk to (POSIX file "$MOUNT" as alias)
    open theDisk
    -- Finder opens the window a moment later.
    delay 2
    set theWindow to container window of theDisk
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    try
        set sidebar width of theWindow to 0
    end try
    -- The bounds include the title bar; the background fills what's below it.
    set the bounds of theWindow to {200, 120, 200 + $WINDOW_WIDTH, 120 + $WINDOW_HEIGHT + 28}
    set options to the icon view options of theWindow
    set arrangement of options to not arranged
    set icon size of options to 128
    set text size of options to 13
    set background picture of options to file ((theDisk as text) & ".background:background.tiff")
    set position of item "Island.app" of theDisk to {$APP_POSITION}
    set position of item "Applications" of theDisk to {$APPLICATIONS_POSITION}
    -- Reopening makes Finder write the layout to .DS_Store.
    close theWindow
    open theDisk
    delay 1
    close container window of theDisk
end tell
EOF

# Finder writes .DS_Store a moment later.
for _ in $(seq 1 20); do
    [[ -f "$MOUNT/.DS_Store" ]] && break
    sleep 0.5
done
rm -rf "$MOUNT/.fseventsd"
sync
hdiutil detach "$MOUNT" -quiet

# Only the latest image is kept: older ones would just pile up in build/.
rm -f build/Island-*.dmg
# LZFSE: smaller than zlib and opens on any macOS Island runs on.
diskutil image create from "$WORK/rw.dmg" "$DMG" --format ULFO 2>&1 >/dev/null | quiet_progress
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
