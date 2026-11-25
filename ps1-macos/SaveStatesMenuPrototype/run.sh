#!/bin/sh
# PROTOTYPE, throwaway: builds and launches the in-game Save States popover mockups.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -parse-as-library -O SaveStatesMenuPrototype.swift -o build/SaveStatesMenuPrototype
exec build/SaveStatesMenuPrototype
