#!/bin/bash
# Island's version, kept in Resources/Info.plist.
#
#   scripts/version.sh                  prints it
#   scripts/version.sh 1.2.0            sets it
#   scripts/version.sh patch|minor|major  bumps it: 1.2.3 → 1.2.4 | 1.3.0 | 2.0.0
#
# Setting a version also raises the build number by one (macOS compares builds by it) and turns
# the Unreleased section of CHANGELOG.md into that version, dated today.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")

if [[ $# -eq 0 ]]; then
    echo "$CURRENT"
    exit 0
fi

IFS=. read -r MAJOR MINOR PATCH <<<"$CURRENT"
case "$1" in
    major) VERSION="$((MAJOR + 1)).0.0" ;;
    minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    *)
        if [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "usage: scripts/version.sh [X.Y.Z | major | minor | patch]" >&2
            exit 1
        fi
        VERSION="$1"
        ;;
esac
if [[ "$VERSION" == "$CURRENT" ]]; then
    echo "Already $VERSION"
    exit 0
fi

# CHANGELOG.md: "## [Unreleased]" keeps its place, empty, and what was under it gets a heading
# of its own; the compare links at the bottom follow.
python3 - "$VERSION" "$(date +%Y-%m-%d)" <<'EOF'
import re
import sys

version, date = sys.argv[1], sys.argv[2]
path = "CHANGELOG.md"
text = open(path).read()
if f"## [{version}]" in text:
    sys.exit(f"CHANGELOG.md already has {version}")
if "## [Unreleased]\n" not in text:
    sys.exit("CHANGELOG.md has no \"## [Unreleased]\" section to turn into this version")

unreleased = re.search(r"## \[Unreleased\]\n(.*?)(?=\n## \[|\n\[Unreleased\]:)", text, re.S)
if not unreleased or not unreleased.group(1).strip():
    print("warning: nothing under Unreleased in CHANGELOG.md", file=sys.stderr)
text = text.replace("## [Unreleased]\n", f"## [Unreleased]\n\n## [{version}] - {date}\n", 1)

previous = re.search(r"^\[Unreleased\]: \.\./\.\./compare/v(.+?)\.\.\.HEAD$", text, re.M)
link = f"../../compare/v{previous.group(1)}...v{version}" if previous else f"../../releases/tag/v{version}"
text = re.sub(
    r"^\[Unreleased\]: .*$",
    f"[Unreleased]: ../../compare/v{version}...HEAD\n[{version}]: {link}",
    text, count=1, flags=re.M,
)
open(path, "w").write(text)
EOF

# After the changelog: if that stops the script, the version stays as it was.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

echo "$CURRENT → $VERSION (build $BUILD)"
