# Native macOS App — Design

**Date:** 2026-08-11
**Status:** Approved, ready for implementation planning
**Prereq:** Core structural refactor (`2026-08-08-core-structural-refactor-design.md`), completed 2026-08-10.
**Follows with:** Metal rasterizer (separate spec, deliberately last).

## Goal

A native macOS PlayStation 1 emulator you can sit down and play: open a `.cue`,
pick a BIOS, and run a real game at full speed with sound and a gamepad.

`ps1-core` becomes a static library behind a C ABI. The four existing frontends
(`ps1-debug`, `ps1-trace`, `ps1-wasm`, `ps1-golden`) are development harnesses;
none of them is the product. This spec builds the fifth frontend, which is.

This is the **display path only**. The software rasterizer in `ps1-core/src/gpu/`
stays exactly as it is. Rewriting it in Metal is roughly 60-70% of the total
remaining effort and gets its own spec.

## Toolchain constraint

**Xcode is not installed** — only Command Line Tools (`xcodebuild` errors out).
Verified present in the CLT SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`:
SwiftUI, Metal, MetalKit, GameController, AudioToolbox, CoreAudio, AppKit.
Swift is 6.4, Zig is 0.16.0.

The build is therefore SwiftPM + a script-assembled `.app` bundle, driven from
`zig build`. No `.xcodeproj`. The file layout stays Xcode-compatible so a project
file can be added later purely for Instruments and the Metal frame debugger,
without moving anything.

---

## 1. Layer boundary: a fifth frontend, `ps1-capi`

The C entry points live in a **new frontend directory**, not in `ps1-core`.

```
ps1-capi/
  src/root.zig        export fn ps1_* — the C ABI implementation
  src/capi_test.zig   wired into `zig build test`
  include/ps1.h       hand-written contract
  include/module.modulemap
```

`ps1-capi/src/root.zig` compiles to `zig-out/lib/libps1core.a`.

**Why not put `export fn` in `ps1-core`:** the core stays free of host
assumptions, the existing frontend pattern holds, and `ps1.h` becomes a
reviewable artifact that a rename cannot silently break. It is a hard contract in
exactly the way `ps1-wasm`'s exports are a hard contract with `index.html`.

`ps1-capi` gets **its own core module pinned to `ReleaseFast`** regardless of the
top-level `-Doptimize`, for the same reason the wasm build does: a Debug core
runs about 0.45x real time, which turns a 23-second boot into two minutes and
reads as a hang.

## 2. The C ABI

```c
#include <stdint.h>
#include <stddef.h>

typedef struct Ps1 Ps1;

typedef struct {
    uint32_t vram_x;     /* disp_env.vram_x_start */
    uint32_t vram_y;     /* disp_env.vram_y_start */
    uint32_t width;      /* getVisibleWidth()  — programmed display area */
    uint32_t height;     /* getVisibleHeight() */
    uint8_t  depth24;    /* GP1(08h) bit 4 */
    uint8_t  enabled;    /* !disp_env.display_disabled */
    uint8_t  pal;        /* for aspect correction */
    uint8_t  _pad;
} Ps1Display;

/* Error codes. 0 is success; all failures are negative. */
#define PS1_OK                 0
#define PS1_ERR_BAD_BIOS_SIZE (-1)
#define PS1_ERR_BAD_CUE       (-2)
#define PS1_ERR_MULTI_FILE_CUE (-3)
#define PS1_ERR_OOM           (-4)

Ps1*    ps1_create(void);
void    ps1_destroy(Ps1*);
void    ps1_reset(Ps1*);

int32_t ps1_load_bios(Ps1*, const uint8_t* bytes, size_t len);
int32_t ps1_load_disc(Ps1*, const uint8_t* bin, size_t bin_len,
                            const uint8_t* cue, size_t cue_len);

void    ps1_set_buttons(Ps1*, uint16_t mask);
void    ps1_run_frame(Ps1*);

void    ps1_copy_vram(const Ps1*, uint16_t* dst);   /* dst holds 1024*512 u16 */
void    ps1_get_display(const Ps1*, Ps1Display* out);
size_t  ps1_read_audio(Ps1*, float* dst, size_t max_floats);
```

### Contract rules

These three are stated in the header itself, because getting them wrong is
silent rather than loud.

**Swift owns every buffer that crosses the boundary — with one exception.**
`Disc` *borrows* its data slice; it does not copy. That is why `ps1-debug`
deliberately never frees its disc bytes. The `.bin` data passed to
`ps1_load_disc` must therefore outlive the handle (or the next
`ps1_load_disc` call). The Swift wrapper enforces this by retaining the `Data`
alongside the handle. The cue bytes are parsed immediately and are *not*
borrowed.

**`ps1_read_audio` drains the ring itself.** The SPU's ring is
`output_buffer: [65536]f32` with `write_idx`/`read_idx`, interleaved stereo at
44100 Hz. The wasm frontend exposes those indices raw and makes JavaScript do the
modular arithmetic. That is a wasm-shaped ABI and must not be repeated: the core
owns its indices, and the caller gets back a count of floats actually written.
`max_floats` should be even; an odd value is truncated down so a stereo pair is
never split.

**Nothing traps across the boundary.** All failures are negative return codes. A
Zig panic handler in `ps1-capi` logs to stderr and aborts rather than unwinding
into Swift, where there is no unwinder to catch it.

**`ps1_reset` keeps the loaded BIOS and disc.** It rebuilds the `Bus` and `Cpu`
and re-copies the BIOS, then re-attaches the current disc if there is one — it is
the front-panel reset button, not a teardown. Running with no disc loaded is
valid and boots to the BIOS shell, so it is not an error condition.

`ps1_set_buttons` takes the mask in `sio.zig`'s own convention — **0 means
pressed**, 1 means released, `0xFFFF` is the idle state. The ABI does not
re-invent a button enum; the header documents the bit layout by reference.

## 3. Swift app structure

```
ps1-macos/
  Package.swift
  build.sh                      assembles zig-out/PS1.app
  Sources/CPs1/                 C target: shim exposing ps1.h
  Sources/PS1/
    PS1App.swift                @main, menu commands, hiddenTitleBar window
    ContentView.swift           shell + alerts
    GameHUD.swift               GlassEffectContainer cluster, auto-hide
    EmptyStateView.swift        glass card: pick BIOS folder / open disc
    Ps1Core.swift               the only file that touches C
    EmulatorRunner.swift        emu thread, pacing, triple buffer
    AudioRing.swift             lock-free float ring (unit-tested)
    AudioOutput.swift           AudioUnit render callback
    MetalDisplayView.swift      NSViewRepresentable over MTKView
    Display.metal               VRAM decode + crop + blit
    InputMap.swift              keyboard + GameController -> u16 (unit-tested)
    BiosLibrary.swift           folder bookmark + region selection
  Tests/PS1Tests/
    AudioRingTests.swift
    InputMapTests.swift
```

Each file has one job. `Ps1Core.swift` is the sole point of contact with the C
ABI — nothing else in the app imports `CPs1`, so the surface can be changed in
one place.

## 4. Threading and pacing

**Audio is the master clock.** Dropped audio is far more audible than a dropped
video frame, and the audio device's clock is the only clock in the system that
cannot be made to wait.

The ring holds about four emulated frames (~3,000 stereo samples). The emulator
thread runs:

```
while running && !paused {
    if ring.filled > highWater { wait(condvar); continue }
    core.runFrame()
    core.readAudio(into: ring)
    core.copyVram(into: slots[(newest + 1) % 3])
    atomicStore(newest, (newest + 1) % 3)
}
```

`ps1_run_frame` runs vblank-to-vblank, the same shape as `ps1-wasm`'s
`stepFrame`: spin while `gpu.is_vblank`, then spin while `!gpu.is_vblank`.

**The CoreAudio render callback never blocks and never allocates.** It drains
what the ring has; on underrun it writes silence for that callback and returns.
It signals the condvar when the fill level drops below `lowWater`.

**Frame handoff is three 1MB slots and one atomic index** — single producer,
single consumer, no lock. The renderer draws whatever `newest` currently points
at. If the emulator runs slightly ahead of or behind the display, a frame repeats
or is skipped, which is invisible at 59.94 against 60 Hz and is the correct
behaviour on a 120 Hz ProMotion panel too.

## 5. Pixel path

The emulator thread memcpy's the whole 1MB of VRAM into its slot. Metal uploads
that slot as a `r16Uint` texture of 1024x512, and a fragment shader does the
work:

- unpack ABGR1555, or repack 24bpp when `depth24` is set
- crop to the programmed display window (`vram_x/vram_y/width/height`)
- aspect-correct blit into the drawable

1MB per frame is 60MB/s of upload, which is not measurable.

**This is chosen specifically because it is the seam the Metal rasterizer plugs
into.** When VRAM later lives on the GPU, only the upload step disappears; the
shader is unchanged. Converting to RGBA on the Zig side would bake in a CPU pass
that the rasterizer spec would then have to tear out.

## 6. Interface: Liquid Glass

The app adopts Liquid Glass. This is not decoration bolted onto a game window —
glass refracts whatever is behind it, and behind this app's chrome is a running
PlayStation game, which is close to the ideal content for the material.

Verified present in the CLT SDK (macOS 27.0): `glassEffect(_:in:)`,
`GlassEffectContainer`, `glassEffectID`, `glassEffectUnion`,
`GlassEffectTransition` and `DefaultGlassEffectShape` live in **SwiftUICore**;
the `.glass` and `.glassProminent` button styles live in **SwiftUI**. Everything
is `@available(iOS 26.0, macOS 26.0, ...)`.

**Deployment target is therefore macOS 26.0**, and the app will not launch on
anything older. That is a deliberate trade, recorded here so it is not
rediscovered later.

Three places it is used, and one where it deliberately is not:

**The window is full-size content.** The Metal view extends under the title bar
(`.windowStyle(.hiddenTitleBar)` plus `fullSizeContentView`), so chrome floats
*over* the game rather than sitting in an opaque strip above it. Without this the
material has nothing to refract and the whole adoption is pointless.

**A floating HUD cluster** — pause/resume, reset, eject, fullscreen — inside a
single `GlassEffectContainer`. It auto-hides a couple of seconds into play and
returns on mouse movement. Collapsing and expanding is a `glassEffectID` +
`Namespace` morph, which is what the container exists for; `glassEffectUnion`
merges the adjacent controls into one continuous shape rather than a row of
separate lozenges.

**The empty states** — no BIOS folder chosen, no disc loaded — are a centred
glass card over a dark backdrop, with `.buttonStyle(.glassProminent)` on the
primary action and `.glass` on the secondary. This is what the app shows on first
launch, so it is the one screen every user sees.

**The game view itself gets no glass effect.** Nearest-neighbour PS1 pixels
behind a refractive layer look wrong, and it would cost GPU time for nothing.

**Cost, and the mitigation.** A glass effect samples the drawable behind it every
frame, over a 60fps Metal view. Two things keep that bounded: all HUD effects go
in **one** `GlassEffectContainer` so they batch into a single pass instead of N
independent ones, and the HUD is hidden during actual play. If the HUD measurably
costs frames on the acceptance titles, hiding it is already the default state and
the game view is unaffected either way.

## 7. BIOS, discs, error handling

**BIOS: the user points at a folder once.** The path is persisted as a
security-scoped bookmark in `UserDefaults` — the app is not sandboxed in v1, but
bookmarks make sandboxing later a settings change rather than a rewrite. Region
selection reuses `ps1-golden`'s rule verbatim, keyed off the disc's filename:

| Filename contains | BIOS |
|---|---|
| `(Europe)` | `SCPH-7502` |
| `(Japan)` | `SCPH-1000` |
| otherwise | `SCPH-1001` |

A US BIOS in front of a PAL disc stops at the region-lock screen, so this rule is
load-bearing, not a nicety. If the folder yields no match, fall back to an
explicit single-file picker and remember that choice.

**Discs:** `.cue` is preferred. A raw `.bin` is accepted through `Disc.init`'s
single-data-track-at-LBA-0 fallback, which cannot represent audio tracks — the UI
says so, because a CD-DA title opened as a `.bin` will be silent and that looks
like a bug. A cue declaring more than one `FILE` is **rejected up front** with
`PS1_ERR_MULTI_FILE_CUE` rather than mis-laid-out, matching the rule
`ps1-golden` already applies (Castlevania: Symphony of the Night has 2, Tekken
has 28).

Every failure path — wrong BIOS size, unparseable cue, multi-`FILE` cue, oversized
image, allocation failure — returns a negative code that `Ps1Core.swift` turns
into a Swift `Error` and `ContentView` presents as an alert. No path crashes.

## 8. Build integration

```
zig build macos
  ├─ libps1core.a          ps1-capi, own core module, always ReleaseFast
  ├─ ps1-capi/include/     ps1.h + module.modulemap
  └─ ps1-macos/build.sh → swift build -c release → zig-out/PS1.app
```

`build.zig` gains a static library artifact and a `macos` step that depends on
it, then runs `build.sh`. The script runs `swift build -c release`, compiles
`Display.metal` with `xcrun metal`, and assembles the bundle:

```
zig-out/PS1.app/Contents/
  MacOS/PS1
  Resources/default.metallib
  Info.plist
```

`ps1-macos/Package.swift` declares a C target `CPs1` that exposes the header via
`module.modulemap`. The static library is linked by **`build.sh` passing an
absolute path** — `swift build -Xlinker -L<abs>/zig-out/lib -Xlinker -lps1core` —
rather than a relative `unsafeFlags` entry baked into `Package.swift`, because a
relative path there resolves against the linker's working directory and breaks
the moment the package is built from anywhere but its own root.

`zig build macos` is macOS-only and must fail with a clear message on any other
target rather than producing a broken bundle.

## 9. Testing

**Zig — `ps1-capi/src/capi_test.zig`, wired into `zig build test`:**
- handle lifecycle: `create`/`destroy`, and `destroy` of a handle that never got
  a BIOS
- `ps1_load_bios` rejects any length that is not 524288
- `ps1_load_disc` rejects a multi-`FILE` cue
- `ps1_read_audio` drains exactly what the SPU wrote: no double-drain, no loss
  across the ring's wraparound, odd `max_floats` truncated to an even count
- `ps1_get_display` reports the programmed display area, not the nominal mode size

**Swift — `Tests/PS1Tests/`:** the two pieces with real bug surface, both pure
logic with no hardware dependency:
- `AudioRingTests` — fill/drain/wrap arithmetic, underrun behaviour, the
  high/low water transitions
- `InputMapTests` — key and gamepad events produce the right `u16`, including
  the 0-means-pressed inversion and simultaneous presses

No UI tests.

**Hard gate: `zig build trace-golden -- verify` must stay green.** This spec adds
a frontend and changes no core behaviour. Any divergence means something leaked
into the core and must be fixed before the work lands, not re-captured.

**Acceptance:** Croc, Spyro and Silent Hill each boot from a `.cue` to gameplay,
at full speed, with audio, driven by a gamepad.

## 10. Non-goals

Explicitly out of scope for this spec, each deferred on purpose:

- **Memory-card persistence.** The 128KB image and its dirty flag already exist in
  `sio.zig`; nothing persists them. Needs its own file-lifecycle decision
  (per-game cards or one shared card).
- **Save states.** Needs a serialization pass over every device struct — a
  substantial spec that would dominate this one.
- **Settings/preferences UI.**
- **The Metal rasterizer.** Display path only.
- **Upscaling and filtering.** Nearest-neighbour in v1.
- **Analog controller.** The pad reports as digital (ID `0x41`); the `0x43`/`0x44`
  escape commands are unimplemented in `sio.zig`, so analog is a core change, not
  a frontend one.
- **Code signing, notarization, sandboxing.**
