#!/bin/bash
# Builds Island.app into ./build.
#   --run        launch it afterwards
#   --universal  one app for Apple Silicon and Intel Macs (for sharing; slower to build)
set -euo pipefail
cd "$(dirname "$0")"

RUN=false
UNIVERSAL=false
for arg in "$@"; do
    case "$arg" in
        --run) RUN=true ;;
        --universal) UNIVERSAL=true ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

# Command Line Tools don't include the SwiftUI macros plugin the macOS 27 SDK needs for @State,
# so build against the newest 26.x SDK (it already has Liquid Glass) when it's installed.
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
if [[ -n "$SDK" ]]; then
    export SDKROOT="$SDK"
fi

# SwiftPM 6.4's new build system fails on duplicate specs inside Command Line Tools; use the classic one.
BUILD_FLAGS=(-c release)
if swift build --help 2>/dev/null | grep -q -- "--build-system"; then
    BUILD_FLAGS+=(--build-system native)
fi

# Builds for one architecture and prints where the binary is. The triple is always explicit:
# .build/release points at whichever was built last, so it can't be trusted.
build_arch() {
    local triple="$1-apple-macosx14.0"
    swift build "${BUILD_FLAGS[@]}" --triple "$triple" >&2
    echo "$(swift build "${BUILD_FLAGS[@]}" --triple "$triple" --show-bin-path)/DynamicIsland"
}

if $UNIVERSAL; then
    ARM=$(build_arch arm64)
    INTEL=$(build_arch x86_64)
    BINARY=build/DynamicIsland-universal
    mkdir -p build
    lipo -create "$ARM" "$INTEL" -output "$BINARY"
else
    BINARY=$(build_arch "$(uname -m)")
fi

APP=build/Island.app
# Earlier builds were called DynamicIsland.app; two copies would confuse Launch Services.
if [[ -d build/DynamicIsland.app ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u build/DynamicIsland.app 2>/dev/null || true
    rm -rf build/DynamicIsland.app
fi
# Update the bundle in place: deleting and recreating it makes macOS show a blank icon
# until its icon cache catches up.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/DynamicIsland"
cp Resources/Info.plist "$APP/Contents/"
# Languages: macOS picks the one matching the system for permission prompts and system UI.
for LPROJ in Resources/*.lproj; do
    rm -rf "$APP/Contents/Resources/$(basename "$LPROJ")"
    cp -R "$LPROJ" "$APP/Contents/Resources/"
done

# App icon: every size an .iconset needs, generated from a single PNG.
ICON_SOURCE=Resources/AppIcon.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# A stable certificate keeps granted permissions (Accessibility for the middle click, the
# microphone) across rebuilds: macOS ties them to the signature, and an ad-hoc one changes with
# every build. Create the certificate once with scripts/create-signing-identity.sh.
IDENTITY="Dynamic Island Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "warning: no \"$IDENTITY\" certificate, signing ad-hoc: permissions will be asked again after every build" >&2
    codesign --force --sign - "$APP"
fi

# Tell Finder/Dock/LaunchServices the bundle (and its icon) changed.
touch "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

echo "Built $APP"

if $RUN; then
    pkill -x DynamicIsland || true
    while pgrep -x DynamicIsland >/dev/null; do sleep 0.1; done
    # LaunchServices notices the exit a moment later; opening too early fails with -600.
    for _ in 1 2 3 4 5; do open "$APP" 2>/dev/null && break; sleep 0.5; done
fi
