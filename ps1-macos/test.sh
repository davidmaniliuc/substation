#!/bin/bash
# Runs the Swift test suite.
#
# This used to carry three flags `swift test` could not infer — two -rpath
# entries for Testing.framework and lib_TestingInterop.dylib, and a -plugin-path
# for libTestingMacros.dylib — because the Command Line Tools toolchain scatters
# them in directories SwiftPM does not scan. None of that is needed here: the
# Xcode test runner supplies swift-testing itself.
#
# The display tests load the real shader out of libps1shaders.a, exactly as the
# app does, so it is a test dependency and not just a packaging one.
#
# No -quiet here, unlike build.sh: xcodebuild's quiet mode suppresses the
# per-test result lines along with the build noise, so the suite passes in
# silence and a failure is reported only by the exit status.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO/ps1-macos"
SYMROOT="$REPO/.build/xcode"

if [ ! -f "$REPO/zig-out/lib/libps1core.a" ]; then
    echo "error: zig-out/lib/libps1core.a is missing — run 'zig build capi-lib' first" >&2
    exit 1
fi
if [ ! -f "$REPO/zig-out/lib/libps1shaders.a" ]; then
    echo "error: zig-out/lib/libps1shaders.a is missing — run 'zig build metallib' first" >&2
    exit 1
fi
# Unlike the two above this is a WARNING, not an error. The committed synthetic
# fixture is enough to run the executable half of the bridge gate, and the
# generated fixtures legitimately cannot exist on a machine without games/.
if [ ! -d "$REPO/zig-out/fixtures" ]; then
    echo "note: zig-out/fixtures is missing — the generated-fixture checks will skip." >&2
    echo "      run 'zig build fixtures' to produce them." >&2
fi

exec xcodebuild \
    -project "$PKG/PS1.xcodeproj" \
    -scheme PS1 \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    SYMROOT="$SYMROOT" \
    test
