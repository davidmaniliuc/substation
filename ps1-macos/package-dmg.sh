#!/bin/bash
# Packs zig-out/Substation.app into a drag-to-Applications disk image.
#
#   ps1-macos/package-dmg.sh [version]
#
# Writes zig-out/Substation-<version>.dmg and a .sha256 beside it (the digest
# the Homebrew cask pins). Run `zig build macos` first; this packs the bundle
# that step installed and builds nothing itself.
#
# Plain hdiutil rather than create-dmg or appdmg: a release runner then needs
# nothing beyond Xcode, and an /Applications symlink next to the app is all the
# window has to say. The bundle keeps whatever signature xcodebuild gave it
# (ad-hoc today, see docs/RELEASING.md); nothing here re-signs it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/zig-out/Substation.app"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="$REPO/zig-out/Substation-$VERSION.dmg"

if [ ! -d "$APP" ]; then
    echo "error: $APP is missing; run 'zig build macos' first" >&2
    exit 1
fi

# Verify before packing: a bundle whose signature does not hold is one macOS
# reports as "damaged" on the player's machine, long after this could have
# said so.
codesign --verify --deep --strict "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto, not cp -R: it keeps the extended attributes and the signature's
# resource seal exactly as xcodebuild wrote them.
ditto "$APP" "$STAGE/Substation.app"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "Substation $VERSION" \
    -srcfolder "$STAGE" \
    -fs APFS \
    -format ULFO \
    -ov \
    "$DMG" >/dev/null

(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "==> built $DMG"
cat "$DMG.sha256"
