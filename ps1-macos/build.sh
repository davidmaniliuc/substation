#!/bin/bash
# Builds zig-out/Substation.app out of PS1.xcodeproj.
#
# This is a wrapper over xcodebuild, not an assembler: Xcode owns the bundle
# layout, Info.plist processing and code signing. The script exists so
# `zig build macos` has one thing to call and so a missing Zig archive fails
# with the build step to run rather than with a linker error.
#
# The two archives are separate on purpose. libps1core.a is the portable
# emulator ABI; libps1shaders.a carries the offline-compiled Metal display
# shader (see ps1-macos/Shaders/embed.zig) and needs Xcode's Metal toolchain to
# produce, which the emulator ABI must not inherit.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO/ps1-macos"
APP="$REPO/zig-out/Substation.app"
SYMROOT="$REPO/.build/xcode"

if [ ! -f "$REPO/zig-out/lib/libps1core.a" ]; then
    echo "error: zig-out/lib/libps1core.a is missing — run 'zig build capi-lib' first" >&2
    exit 1
fi
if [ ! -f "$REPO/zig-out/lib/libps1shaders.a" ]; then
    echo "error: zig-out/lib/libps1shaders.a is missing — run 'zig build metallib' first" >&2
    exit 1
fi

echo "==> xcodebuild -scheme PS1 -configuration Release"
xcodebuild \
    -project "$PKG/PS1.xcodeproj" \
    -scheme PS1 \
    -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    SYMROOT="$SYMROOT" \
    -quiet \
    build

# Copied out rather than built in place: zig-out/Substation.app is the documented
# output path, and keeping it means nothing downstream cares that the bundle is
# now Xcode's work rather than this script's.
echo "==> installing $APP"
mkdir -p "$REPO/zig-out"
rm -rf "$APP"
cp -R "$SYMROOT/Release/Substation.app" "$APP"

echo "==> built $APP"
