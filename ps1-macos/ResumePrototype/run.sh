#!/bin/sh
# PROTOTYPE, throwaway: builds and launches the resume-sheet mockup app.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -parse-as-library -O ResumePrototype.swift -o build/ResumePrototype
exec build/ResumePrototype
