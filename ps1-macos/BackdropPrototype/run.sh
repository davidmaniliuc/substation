#!/bin/sh
# PROTOTYPE, throwaway: builds and launches the Substation backdrop mockup.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun -sdk macosx metal -c Backdrop.metal -o build/Backdrop.air
xcrun -sdk macosx metallib build/Backdrop.air -o build/Backdrop.metallib
xcrun swiftc -parse-as-library -O BackdropPrototype.swift -o build/BackdropPrototype
exec build/BackdropPrototype
