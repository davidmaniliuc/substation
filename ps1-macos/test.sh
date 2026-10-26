#!/bin/bash
# Runs the Swift test suite: the app's views, view models and stores, against
# ScriptedSession. The engine (renderer, session, audio) is tested in Zig by
# `zig build test-metal`, not here.
#
# This used to carry three flags `swift test` could not infer (two -rpath
# entries for Testing.framework and lib_TestingInterop.dylib, and a -plugin-path
# for libTestingMacros.dylib), because the Command Line Tools toolchain scatters
# them in directories SwiftPM does not scan. None of that is needed here: the
# Xcode test runner supplies swift-testing itself.
#
# The test host is the app, and the app links libps1shaders.a (the renderer in
# libps1core.a loads its shader from it), so the archive must exist to link.
#
# No -quiet here, unlike build.sh: xcodebuild's quiet mode suppresses the
# per-test result lines along with the build noise, so the suite passes in
# silence and a failure is reported only by the exit status.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO/ps1-macos"
SYMROOT="$REPO/.build/xcode"

if [ ! -f "$REPO/zig-out/lib/libps1core.a" ]; then
    echo "error: zig-out/lib/libps1core.a is missing; run 'zig build capi-lib' first" >&2
    exit 1
fi
if [ ! -f "$REPO/zig-out/lib/libps1shaders.a" ]; then
    echo "error: zig-out/lib/libps1shaders.a is missing; run 'zig build metallib' first" >&2
    exit 1
fi
exec xcodebuild \
    -project "$PKG/PS1.xcodeproj" \
    -scheme PS1 \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    SYMROOT="$SYMROOT" \
    test
