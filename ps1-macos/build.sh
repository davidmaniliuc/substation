#!/bin/bash
# Assembles zig-out/PS1.app.
#
# The static library is linked by ABSOLUTE path rather than by an unsafeFlags
# entry in Package.swift: a relative path there resolves against the linker's
# working directory and breaks the moment the package is built from anywhere
# but its own root.
#
# There is no default.metallib — the offline `metal` compiler ships with Xcode
# and this project builds against Command Line Tools only, so the display
# shader is compiled at runtime from a string. See DisplayShader.swift.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO/ps1-macos"
APP="$REPO/zig-out/PS1.app"

if [ ! -f "$REPO/zig-out/lib/libps1core.a" ]; then
    echo "error: zig-out/lib/libps1core.a is missing — run 'zig build capi-lib' first" >&2
    exit 1
fi

echo "==> swift build -c release"
swift build -c release \
    --package-path "$PKG" \
    -Xlinker -L"$REPO/zig-out/lib" \
    -Xlinker -lps1core

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
