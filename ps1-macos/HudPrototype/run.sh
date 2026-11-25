#!/bin/sh
# PROTOTYPE, throwaway: builds and launches the HUD mockup app. The volume
# slider is the app's own, compiled in from Sources/PS1.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -parse-as-library -O HudPrototype.swift \
    ../Sources/PS1/VolumeControl.swift ../Sources/PS1/VolumeControlView.swift \
    -o build/HudPrototype
exec build/HudPrototype
