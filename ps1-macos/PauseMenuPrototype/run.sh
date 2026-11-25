#!/bin/sh
# PROTOTYPE, throwaway: builds and launches the pause-menu sidebar mockup app.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -parse-as-library -O PauseMenuPrototype.swift -o build/PauseMenuPrototype
exec build/PauseMenuPrototype
