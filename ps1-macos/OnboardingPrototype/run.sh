#!/bin/sh
# PROTOTYPE, throwaway: builds and launches the onboarding mockup app.
set -e
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -parse-as-library -O OnboardingPrototype.swift -o build/OnboardingPrototype
exec build/OnboardingPrototype
