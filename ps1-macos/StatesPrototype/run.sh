#!/bin/sh
# PROTOTYPE, throwaway: builds and launches the resume sheet + Save States panel mockups.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -parse-as-library -O StatesPrototype.swift -o build/StatesPrototype
exec build/StatesPrototype
