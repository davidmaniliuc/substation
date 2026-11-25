#!/bin/sh
# PROTOTYPE, throwaway: builds and launches the library mockup app.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -parse-as-library -O LibraryGlassPrototype.swift -o build/LibraryGlassPrototype
exec build/LibraryGlassPrototype
