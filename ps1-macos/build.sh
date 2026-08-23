#!/bin/bash
# Assembles zig-out/PS1.app.
#
# The static library is linked by ABSOLUTE path rather than by an unsafeFlags
# entry in Package.swift: a relative path there resolves against the linker's
# working directory and breaks the moment the package is built from anywhere
# but its own root.
#
# libps1shaders.a carries the offline-compiled Metal display shader as an
# embedded blob (see ps1-macos/Shaders/embed.zig). It is a SEPARATE library
# from libps1core.a because building it needs Xcode's Metal toolchain, which
# Command Line Tools does not ship, and the emulator ABI must not inherit that
# requirement.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO/ps1-macos"
APP="$REPO/zig-out/PS1.app"

if [ ! -f "$REPO/zig-out/lib/libps1core.a" ]; then
    echo "error: zig-out/lib/libps1core.a is missing — run 'zig build capi-lib' first" >&2
    exit 1
fi
if [ ! -f "$REPO/zig-out/lib/libps1shaders.a" ]; then
    echo "error: zig-out/lib/libps1shaders.a is missing — run 'zig build metallib' first" >&2
    exit 1
fi

echo "==> swift build -c release"
swift build -c release \
    --package-path "$PKG" \
    -Xlinker -L"$REPO/zig-out/lib" \
    -Xlinker -lps1core \
    -Xlinker -lps1shaders

BIN="$(swift build -c release --package-path "$PKG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PS1" "$APP/Contents/MacOS/PS1"
cp "$PKG/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature: unsigned SwiftUI apps are killed on launch by Gatekeeper on
# recent macOS. This is not notarization — that is explicitly out of scope.
codesign --force --sign - "$APP" 2>/dev/null || \
    echo "warning: ad-hoc codesign failed; the app may not launch" >&2

echo "==> built $APP"
