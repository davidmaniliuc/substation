#!/bin/bash
# Runs the Swift test suite. Passes any extra args through (e.g. --filter).
#
# The two -rpath flags are NOT optional and are a Command Line Tools problem,
# not a project one: swift-testing's Testing.framework and its
# lib_TestingInterop.dylib ship under CommandLineTools/Library/Developer, which
# is not on the test bundle's runtime search path. Without them the bundle
# builds and links fine and then dies in dlopen before a single test runs.
# They are applied here rather than in Package.swift so the SHIPPED app binary
# does not carry an rpath into a toolchain directory.
#
# XCTest.framework does not exist under Command Line Tools at all, so falling
# back to XCTest instead of swift-testing is not an option.
#
# -plugin-path is the same story one layer earlier, at COMPILE time: the
# compiler auto-scans usr/lib/swift/host/plugins but libTestingMacros.dylib
# sits in a `testing/` subdirectory of it, so @Test expands to nothing and
# every test file fails with "plugin for module 'TestingMacros' not found".
# The symptom alternates confusingly — an incremental run that recompiles
# nothing passes, and only a fresh compile of the test module fails.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
CLT_TEST_PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

if [ ! -f "$REPO/zig-out/lib/libps1core.a" ]; then
    echo "error: zig-out/lib/libps1core.a is missing — run 'zig build capi-lib' first" >&2
    exit 1
fi
# The display tests load the real shader out of this library, exactly as the
# app does, so it is a test dependency and not just a packaging one.
if [ ! -f "$REPO/zig-out/lib/libps1shaders.a" ]; then
    echo "error: zig-out/lib/libps1shaders.a is missing — run 'zig build metallib' first" >&2
    exit 1
fi

exec swift test --package-path "$REPO/ps1-macos" \
    -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core -Xlinker -lps1shaders \
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT_LIB" \
    -Xswiftc -plugin-path -Xswiftc "$CLT_TEST_PLUGINS" \
    "$@"
