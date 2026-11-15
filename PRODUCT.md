# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS only: SwiftUI over the Zig session's C ABI, Apple silicon, macOS 26
or later. Impeccable's platform list has no macOS value, so no native guide loads
automatically; the `apple-design-guidelines` skill is the HIG authority for every
UI change. The `ps1-web` npm package and the wasm demo are secondary targets with
no product UI of their own.

## Users

Mac owners who want to play their own PlayStation discs on an Apple-silicon Mac,
supplying their own BIOS. They expect a disc to boot and play like any Mac app
opens a document: no configuration first. Enthusiast settings (PGXP, internal
resolution, texture filtering, dithering, runahead, rewind, CPU overclock, CPU
engine) exist and are real, but they sit behind Settings and per-game defaults
and never lead a surface.

## Product Purpose

Substation is "a native PlayStation emulator for the Mac." It turns a folder of
disc images into a library and plays them with a Metal renderer, CoreAudio and
game controllers. Success is a game that boots, plays, saves and resumes without
the player touching a setting, inside an app that feels like it shipped with the
Mac.

## Positioning

- **Mac-native, HIG-strict.** It behaves like Apple's own apps (Music, Finder):
  system controls, system window colours, native table and toolbar chrome. An
  invented interaction reads as non-native however polished it is.
- **Its own core.** A from-scratch Zig emulator core and Metal renderer for one
  system, not a multi-system frontend and not a port of another emulator.
- **Library-centred.** The game library, with cover art, is home. A game is
  opened from it, and the play window, pause menu, save states and resume flow
  hang off that.

## Operating Context

- A player adds a folder of images; the app scans, groups multi-disc sets and
  fetches covers. Formats: `.cue`/`.bin`, CHD, ECM, ISO, CloneCD, Alcohol `.mds`,
  PS1 eboots `.pbp`, plus `.sbi`/`.sub` LibCrypt sidecars and PPF patches.
- Play happens in a game window with a HUD, a pause menu (sidebar), save states,
  rewind and an auto-resume offer on next launch. Memory cards persist across
  games.
- Distributed as alpha: signed DMG on GitHub Releases and a Homebrew cask, not
  notarized, self-updating via Sparkle.

## Capabilities and Constraints

- Requires the player's own BIOS; none ships with the app.
- Library themes are System (default), Dark and Light only, classic Mac.
  Gradient or animated backdrops and a pure-black theme were built and removed at
  the owner's request; do not propose them again.
- Settings copy is one short sentence per setting (120-character hard cap,
  enforced by a test); option names speak for themselves.
- Shaders are compiled offline; the app runs no part of the engine itself.
- The owner overrules a strict HIG reading where he chooses to (for example glass
  push buttons and a dashed Start Fresh tile in the resume sheet). Apply the HIG,
  show it, and let him decide.

## Brand Commitments

- Name: **Substation**. Tagline: "A native PlayStation emulator for the Mac."
- App icon built in Icon Composer (`ps1-macos/Icon/`).
- About window modelled on Ghostty's: icon, name, tagline, version/build/commit
  grid, a GitHub button only.
- Never name another emulator in the product, code or commits, and never describe
  Substation as a port of one.

## Evidence on Hand

- Real games verified to boot and play: Croc, Silent Hill, Spyro, Crash
  Bandicoot, Tekken 3, Final Fantasy VII/VIII/IX, Tomb Raider and others.
- Cover art is downloaded at runtime per disc; there are no bundled marketing
  images, screenshots set, testimonials, press or user counts. Do not fabricate
  any.
- SwiftUI prototypes of past explorations live untracked in
  `ps1-macos/*Prototype/`.

## Product Principles

1. **It should feel like Apple made it.** Native components and behaviour over
   custom ones; departures need the owner's explicit choice.
2. **Play first, tune later.** Defaults and per-game tables do the work; depth is
   available, never in the way.
3. **The library is the home.** Every flow starts from and returns to it.
4. **Short and plain.** Copy, settings and chrome stay terse; nothing explains
   itself at length on screen.
5. **Truthful about alpha.** Say what it needs and what it is; claim nothing
   unverified.
