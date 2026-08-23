# ps1-macos as a real Xcode project — design

**Date:** 2026-08-23
**Status:** approved, implementing

## Why

`ps1-macos` is a SwiftPM package whose `.app` is assembled by a bash script:
`build.sh` runs `swift build -c release`, then `mkdir`s a bundle, `cp`s the
binary and `Info.plist` in, and ad-hoc signs it. That was the only option while
this machine had Command Line Tools and no Xcode — `xcodebuild` did not exist
here.

Xcode 26.6 was installed on 2026-08-22 for the Metal toolchain (see the offline
shader work, commit `68be236`). `xcodebuild` is now available, which makes the
hand-assembled bundle the more expensive of the two options rather than the only
one. Everything the script cannot do — app icon from an asset catalog,
entitlements, `Info.plist` variable substitution, a real signing identity,
universal binaries, `xcodebuild test` — is a build-setting line away in a
project, and remains unreachable from the script.

## Reference

Ghostty, whose approach this follows deliberately (the offline shader step
already does). Verified against the repository on 2026-08-23:

- `macos/Ghostty.xcodeproj/project.pbxproj` is **committed**, not generated. No
  XcodeGen, no Tuist.
- It is `objectVersion = 70` and uses **five `PBXFileSystemSynchronizedRootGroup`
  entries**, so `Sources/` and `Tests/` are synchronized folders: adding a
  `.swift` file requires no project-file edit. This is why the whole file is
  1117 lines with only 23 `PBXFileReference` entries.
- There is **no `Package.swift`** for the macOS app. The Xcode project owns the
  Swift sources; the Zig side is consumed as a linked library artifact
  (`GhosttyKit.xcframework`).
- CLI builds go through `macos/build.nu`, which is a thin wrapper over
  `xcodebuild -project … -scheme … -configuration … <action>` with a scrubbed
  environment. Tests use the same wrapper with `--action test`.

## Structure

```
ps1-macos/
  PS1.xcodeproj/        NEW — committed, objectVersion 70, synchronized groups
  Sources/              unchanged  → synchronized into the app target
  Tests/PS1Tests/       unchanged  → synchronized into the test bundle
  Info.plist            unchanged  → now INFOPLIST_FILE
  Shaders/              unchanged  → still zig's input, not Xcode's
  build.sh              rewritten as an xcodebuild wrapper
  test.sh               rewritten as `xcodebuild test`
  Package.swift         DELETED
```

### Targets

**`PS1`** — the app. A synchronized root group over `Sources/` supplies its
files. Its Swift module name stays `PS1`, which is what keeps all twelve
`@testable import PS1` lines in the test suite working unchanged.
`SWIFT_INCLUDE_PATHS = $(SRCROOT)/Sources/CPs1/include` lets the existing
`module.modulemap` resolve, so `import CPs1` in `Ps1Core.swift` and
`DisplayShader.swift` is also unchanged.

**`PS1Tests`** — a unit-test bundle. A synchronized root group over `Tests/`,
with `PS1` as `TEST_HOST`.

**Net Swift source changes: zero.** The conversion touches the build system and
nothing else.

### Linking the Zig libraries

```
LIBRARY_SEARCH_PATHS = $(SRCROOT)/../zig-out/lib
OTHER_LDFLAGS        = -lps1core -lps1shaders
```

`$(SRCROOT)`-relative rather than absolute. The reason `build.sh` passed an
absolute path — a relative path in `Package.swift`'s `unsafeFlags` resolves
against the linker's working directory — does not apply to a build setting,
which Xcode resolves against the project.

Both archives stay Zig's output. `zig build capi-lib` and `zig build metallib`
are unchanged, and the Metal compile stays a **Zig build step rather than an
Xcode build phase**: that keeps `zig build metallib` meaningful on its own and
keeps the Metal toolchain requirement out of Xcode's dependency graph, which is
the separation the shader work established.

## Build and test entry points

`zig build macos` remains the entry point and keeps its shape: it depends on
`capi-lib` and `metallib`, then runs `ps1-macos/build.sh`. The script's body
becomes `xcodebuild -project PS1.xcodeproj -scheme PS1 -configuration Release`
with `SYMROOT` pointed at `.build/xcode`, followed by a copy of the built bundle
to **`zig-out/PS1.app`** — the documented output path is preserved, so nothing
downstream of it changes.

`test.sh` becomes `xcodebuild test -scheme PS1`. Its three Command Line Tools
paths (`-rpath` for `Testing.framework` and `lib_TestingInterop.dylib`,
`-plugin-path` for `libTestingMacros.dylib`) are **deleted**: the Xcode test
runner supplies swift-testing itself. Those flags existed only because the CLT
toolchain scattered them in directories `swift test` did not scan.

The library-presence guards in both scripts are kept — a missing
`libps1core.a`/`libps1shaders.a` should still fail with the message naming the
`zig build` step to run, not with a linker error.

## Deliberate deviations from Ghostty

- **No universal binary.** Ghostty lipos arm64 and x86_64. Our Zig archives are
  host-architecture only, so a universal app needs two `zig build` runs plus a
  lipo step. Deferred until there is a reason to distribute.
- **No `Assets.xcassets`, no entitlements file.** There is no app icon and the
  app is deliberately unsandboxed (`ScopedBookmark` uses security-scoped
  bookmarks anyway, for reasons recorded in its own header comment). Both become
  one-line additions in a project, which is part of the value of this change;
  neither is added speculatively.
- **Ad-hoc signing retained.** `CODE_SIGN_IDENTITY = "-"`, matching what
  `build.sh` does today. A real identity needs a team ID and is out of scope.

## Consequence accepted

Retiring `Package.swift` means `swift build` and `swift test` no longer work in
this package; `xcodebuild test` is the only way to run the suite. It is slower,
because the runner launches a test host. Accepted for the same reason Ghostty
accepts it: one build system for the app instead of two, and the brittle CLT
paths go away with it.

## Verification gate

1. All 68 tests pass under `xcodebuild test`.
2. `zig build macos` produces `zig-out/PS1.app`.
3. That bundle still carries the embedded shader: `nm` shows
   `_ps1_display_metallib_ptr` / `_len` as defined symbols, and the embedded
   blob's SHA-256 equals the compiled `DisplayShader.metallib`. This is the
   check that caught nothing the first time only because the build was already
   correct; it stays the gate because a bundle that silently lost the shader
   would otherwise fail at the first frame of the first game.
4. `strings` finds no `metal_stdlib` in the binary — no runtime-compile path has
   crept back in.

## Out of scope

Notarization, Sparkle or any updater, a Debug/Release scheme split beyond what
`xcodebuild -configuration` gives, UI tests, and the CLAUDE.md rewrite of the
Command Line Tools constraints (done alongside, but a separate concern).
