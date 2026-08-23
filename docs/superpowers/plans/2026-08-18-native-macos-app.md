# Native macOS App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native macOS PlayStation 1 emulator — open a `.cue`, pick a BIOS, and play a real game at full speed with sound and a gamepad.

**Architecture:** `ps1-core` gains a fifth frontend, `ps1-capi`, which exposes a flat C ABI and compiles to `libps1core.a`. A SwiftUI app (`ps1-macos`) links that archive, runs the emulator on its own thread paced by the audio device's clock, hands frames to a Metal view through a triple buffer, and wraps the whole thing in Liquid Glass chrome. The software rasterizer in `ps1-core/src/gpu/` is untouched — this is the display path only.

**Tech Stack:** Zig 0.16.0, Swift 6.4 (SwiftPM, tools-version 6.2), SwiftUI, Metal/MetalKit, AudioToolbox, GameController. No Xcode — Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-08-11-native-macos-app-design.md`

---

## Global Constraints

- **Zig is 0.16.0.** `std.heap.GeneralPurposeAllocator` does **not** exist; use `std.heap.smp_allocator`. `std.ArrayList(...).empty`, `b.addObject`, `b.addFail`, `b.addSystemCommand` are the 0.16 spellings.
- **`swift-tools-version: 6.2` minimum.** `.macOS(.v26)` is unavailable in 6.0/6.1 and the manifest fails to compile. Verified.
- **Deployment target is macOS 26.0.** Liquid Glass (`glassEffect`, `GlassEffectContainer`, `glassEffectID`) is `@available(macOS 26.0, *)`. The app will not launch on anything older; this is a deliberate trade recorded in the spec.
- **Xcode is not installed.** `xcodebuild` and `xcrun metal` both fail. Two consequences, both verified during planning and both **deviations from spec §8** recorded here:
  1. **Shaders compile at runtime** via `device.makeLibrary(source:options:)`. There is no `default.metallib` in the bundle. Shader source lives in a Swift string constant (`DisplayShader.swift`).
  2. **Zig's own `.a` is rejected by Apple's linker** — `ld: ignoring archive member ... 64-bit mach-o not 8-byte aligned`. The library is therefore emitted with `b.addObject` and repacked with `xcrun libtool -static`. Verified working end-to-end with the real core.
- **`ps1-capi` gets its own core module pinned to `.ReleaseFast`** regardless of top-level `-Doptimize`, exactly as the wasm build does. A Debug core runs ~0.45x real time and reads as a hang.
- **Button mask convention is `sio.zig`'s: 0 means pressed**, 1 means released, `0xFFFF` idle. The ABI does not re-invent it.
- **`Disc` borrows its data slice and does not copy it.** The `.bin` bytes passed to `ps1_load_disc` must outlive the handle. Swift retains the `Data` alongside the handle.
- **Nothing traps across the C boundary.** All failures are negative return codes; a Zig panic handler logs to stderr and aborts rather than unwinding into Swift.
- **Hard gate: `zig build trace-golden -- verify` must stay green** (run with `-Doptimize=ReleaseFast`). This plan adds a frontend and moves one pure helper into the core. Any golden divergence means behaviour leaked into the core and must be fixed, never re-captured.
- **BIOS size is exactly 524288 bytes** (`bus.bios` is `[512 * KB]u8`).
- **VRAM is 1024x512 `u16`**, ABGR1555: bits 0-4 red, 5-9 green, 10-14 blue, bit 15 mask/STP.

### Core API surface this plan consumes (verified, do not guess)

```zig
ps1_core.memory.Bus.init(allocator: std.mem.Allocator) !*Bus
ps1_core.memory.Bus.deinit(self: *Bus, allocator: std.mem.Allocator) void
ps1_core.cpu.Cpu.init(bus: *Bus) Cpu          // value type holding *Bus
cpu.step() void
cpu.bus.gpu.is_vblank: bool
cpu.bus.gpu.is_ntsc: bool                      // pal = !is_ntsc
cpu.bus.gpu.getDisplayWidth() u32              // wraps disp_env.getVisibleWidth()
cpu.bus.gpu.getDisplayHeight() u32
cpu.bus.gpu.getVramPtr() [*]const u16
cpu.bus.gpu.disp_env.vram_x_start: u16
cpu.bus.gpu.disp_env.vram_y_start: u16
cpu.bus.gpu.disp_env.display_disabled: bool
cpu.bus.gpu.disp_env.display_mode: u32         // bit 4 = 24bpp
cpu.bus.sio.setButtons(buttons: u16) void
cpu.bus.cdrom.setDisc(d: ps1_core.disc.Disc) void
ps1_core.disc.Disc.init(data: []const u8) Disc            // raw .bin fallback
ps1_core.disc.Disc.initFromCue(cue_text, data) Disc       // NEVER fails — see Task 2
cpu.bus.spu.output_buffer: [65536]f32          // interleaved stereo, 44100 Hz
cpu.bus.spu.write_idx: usize
cpu.bus.spu.read_idx: usize
bus.bios: [524288]u8
```

**`ps1_core.root.zig` does not re-export `sio`.** Reach it through `bus.sio`.

---

## File Structure

**Zig — new frontend `ps1-capi/`:**

| File | Responsibility |
|---|---|
| `ps1-capi/src/root.zig` | Every `export fn ps1_*`; the `Handle` struct; panic handler. Kept under ~350 lines. |
| `ps1-capi/src/capi_test.zig` | Zig-side ABI tests, wired into `zig build test`. |
| `ps1-capi/include/ps1.h` | Hand-written C contract. The reviewable artifact a rename cannot silently break. |
| `ps1-capi/include/module.modulemap` | Exposes `ps1.h` to Swift as module `CPs1`. |

**Zig — modified:**

| File | Change |
|---|---|
| `build.zig` | `ps1-capi` test target; `libps1core.a` object+repack; `macos` step. |
| `ps1-core/src/disc.zig` | Gains `pub fn countCueFiles` (moved from `ps1-golden`). |
| `ps1-golden/src/golden.zig` | Re-exports `countCueFiles` from the core instead of defining it. |

**Swift — new `ps1-macos/`:**

| File | Responsibility |
|---|---|
| `Package.swift` | SwiftPM manifest, tools-version 6.2, platform macOS 26. |
| `build.sh` | `swift build -c release` + bundle assembly into `zig-out/PS1.app`. |
| `Info.plist` | Bundle metadata, `LSMinimumSystemVersion` 26.0. |
| `Sources/CPs1/` | C target: `empty.c` + a header search path onto `ps1-capi/include`. |
| `Sources/PS1/Ps1Core.swift` | **The only file that imports `CPs1`.** Wraps the handle, turns codes into `Error`. |
| `Sources/PS1/AudioRing.swift` | Lock-free SPSC float ring. Unit-tested. |
| `Sources/PS1/InputMap.swift` | Keyboard + GameController → `UInt16`. Unit-tested. |
| `Sources/PS1/EmulatorRunner.swift` | Emulator thread, pacing, triple buffer. |
| `Sources/PS1/AudioOutput.swift` | AudioUnit render callback. |
| `Sources/PS1/MetalDisplayView.swift` | `NSViewRepresentable` over `MTKView`. |
| `Sources/PS1/DisplayShader.swift` | Metal source string (runtime-compiled). |
| `Sources/PS1/BiosLibrary.swift` | Folder bookmark + region selection. |
| `Sources/PS1/PS1App.swift` | `@main`, menu commands, hidden title bar. |
| `Sources/PS1/ContentView.swift` | Shell + alerts. |
| `Sources/PS1/GameHUD.swift` | `GlassEffectContainer` cluster, auto-hide. |
| `Sources/PS1/EmptyStateView.swift` | Glass card: pick BIOS folder / open disc. |
| `Tests/PS1Tests/AudioRingTests.swift` | Fill/drain/wrap/underrun. |
| `Tests/PS1Tests/InputMapTests.swift` | Mask inversion, simultaneous presses. |

---

## Task 1: `ps1-capi` skeleton — handle lifecycle and BIOS

**Files:**
- Create: `ps1-capi/src/root.zig`
- Create: `ps1-capi/src/capi_test.zig`
- Create: `ps1-capi/include/ps1.h`
- Modify: `build.zig` (add the capi test target to the `test` step)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `Handle` (opaque), `ps1_create() ?*Handle`, `ps1_destroy(?*Handle) void`, `ps1_reset(*Handle) void`, `ps1_load_bios(*Handle, [*]const u8, usize) i32`, and the error constants `PS1_OK=0`, `PS1_ERR_BAD_BIOS_SIZE=-1`, `PS1_ERR_BAD_CUE=-2`, `PS1_ERR_MULTI_FILE_CUE=-3`, `PS1_ERR_OOM=-4`.

- [ ] **Step 1: Write the failing test**

Create `ps1-capi/src/capi_test.zig`:

```zig
const std = @import("std");
const capi = @import("root.zig");

test "create returns a handle and destroy frees it" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    capi.ps1_destroy(h);
}

test "destroy of a handle that never got a BIOS is safe" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    capi.ps1_destroy(h);
}

test "destroy tolerates null" {
    capi.ps1_destroy(null);
}

test "load_bios rejects any length that is not 524288" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const short = [_]u8{0} ** 16;
    try std.testing.expectEqual(@as(i32, -1), capi.ps1_load_bios(h, &short, short.len));

    const good = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(good);
    @memset(good, 0xAB);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, good.ptr, good.len));
    try std.testing.expectEqual(@as(u8, 0xAB), h.cpu.bus.bios[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), h.cpu.bus.bios[524287]);
}

test "reset keeps the loaded BIOS" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const good = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(good);
    @memset(good, 0x5A);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, good.ptr, good.len));

    // Dirty some RAM, then reset.
    h.cpu.bus.ram[0x1000] = 0xFF;
    capi.ps1_reset(h);

    try std.testing.expectEqual(@as(u8, 0x5A), h.cpu.bus.bios[0]);
    try std.testing.expectEqual(@as(u8, 0), h.cpu.bus.ram[0x1000]);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Add to `build.zig`, immediately after the `golden_test` block:

```zig
    // The C ABI frontend. Its tests run against the same core module the other
    // frontends get; the shipped library is built separately (ReleaseFast, own
    // module) by the `macos` step below.
    const capi_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-capi/src/capi_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    capi_test.root_module.addImport("ps1_core", core_mod);
    test_step.dependOn(&b.addRunArtifact(capi_test).step);
```

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `ps1-capi/src/root.zig` does not exist.

- [ ] **Step 3: Write the minimal implementation**

Create `ps1-capi/src/root.zig`:

```zig
//! The C ABI for ps1-core.
//!
//! This is a frontend, not part of the core: the core stays free of host
//! assumptions and `include/ps1.h` stays a reviewable artifact that a rename
//! cannot silently break. Nothing here may trap across the boundary — every
//! failure is a negative return code, and `panic` aborts rather than unwinding
//! into Swift, where there is no unwinder to catch it.

const std = @import("std");
const ps1 = @import("ps1_core");

const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;
const Disc = ps1.disc.Disc;

const allocator = std.heap.smp_allocator;

pub const PS1_OK: i32 = 0;
pub const PS1_ERR_BAD_BIOS_SIZE: i32 = -1;
pub const PS1_ERR_BAD_CUE: i32 = -2;
pub const PS1_ERR_MULTI_FILE_CUE: i32 = -3;
pub const PS1_ERR_OOM: i32 = -4;

const bios_bytes = 512 * 1024;

pub const Handle = struct {
    bus: *Bus,
    cpu: Cpu,
    /// Retained so `ps1_reset` can re-copy it: `Bus.init` memsets the struct,
    /// which clears `bus.bios` along with everything else.
    bios: [bios_bytes]u8 = [_]u8{0} ** bios_bytes,
    bios_loaded: bool = false,
    /// Borrowed, never owned — `Disc` holds a slice into the caller's bytes.
    disc: ?Disc = null,
};

fn buildMachine(h: *Handle) void {
    h.cpu = Cpu.init(h.bus);
    if (h.bios_loaded) @memcpy(h.bus.bios[0..], h.bios[0..]);
    if (h.disc) |d| h.bus.cdrom.setDisc(d);
}

pub export fn ps1_create() ?*Handle {
    const h = allocator.create(Handle) catch return null;
    h.* = .{
        .bus = Bus.init(allocator) catch {
            allocator.destroy(h);
            return null;
        },
        .cpu = undefined,
    };
    buildMachine(h);
    return h;
}

pub export fn ps1_destroy(handle: ?*Handle) void {
    const h = handle orelse return;
    h.bus.deinit(allocator);
    allocator.destroy(h);
}

/// The front-panel reset button: rebuilds the machine but keeps the BIOS and
/// the disc. Running with no disc is valid — it boots to the BIOS shell.
pub export fn ps1_reset(h: *Handle) void {
    h.bus.deinit(allocator);
    h.bus = Bus.init(allocator) catch {
        // Re-allocating 2MB+ immediately after freeing it should not fail; if
        // it does there is no valid state to return to and no way to report it.
        @panic("ps1_reset: out of memory rebuilding Bus");
    };
    buildMachine(h);
}

pub export fn ps1_load_bios(h: *Handle, bytes: [*]const u8, len: usize) i32 {
    if (len != bios_bytes) return PS1_ERR_BAD_BIOS_SIZE;
    @memcpy(h.bios[0..], bytes[0..bios_bytes]);
    h.bios_loaded = true;
    @memcpy(h.bus.bios[0..], h.bios[0..]);
    return PS1_OK;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS, no output from the capi test.

- [ ] **Step 5: Write the header**

Create `ps1-capi/include/ps1.h`. Only the entry points that exist so far; later tasks extend it.

```c
/* ps1.h — the C ABI for ps1-core.
 *
 * CONTRACT RULES. These three are stated here because getting them wrong is
 * silent rather than loud.
 *
 * 1. The caller owns every buffer that crosses this boundary, with one
 *    exception: ps1_load_disc BORROWS the .bin data and does not copy it. Those
 *    bytes must outlive the handle, or the next ps1_load_disc call. The cue
 *    bytes are parsed immediately and are NOT borrowed.
 *
 * 2. Nothing traps across this boundary. Every failure is a negative code.
 *
 * 3. ps1_reset keeps the loaded BIOS and disc. It is the front-panel reset
 *    button, not a teardown. Running with no disc is valid and boots to the
 *    BIOS shell, so it is not an error condition.
 */
#ifndef PS1_H
#define PS1_H

#include <stdint.h>
#include <stddef.h>

typedef struct Ps1 Ps1;

/* Error codes. 0 is success; all failures are negative. */
#define PS1_OK                  0
#define PS1_ERR_BAD_BIOS_SIZE  (-1)
#define PS1_ERR_BAD_CUE        (-2)
#define PS1_ERR_MULTI_FILE_CUE (-3)
#define PS1_ERR_OOM            (-4)

/* Returns NULL on allocation failure. */
Ps1*    ps1_create(void);
/* Tolerates NULL. */
void    ps1_destroy(Ps1*);
void    ps1_reset(Ps1*);

/* len must be exactly 524288, or PS1_ERR_BAD_BIOS_SIZE. */
int32_t ps1_load_bios(Ps1*, const uint8_t* bytes, size_t len);

#endif /* PS1_H */
```

- [ ] **Step 6: Commit**

```bash
git add ps1-capi/src/root.zig ps1-capi/src/capi_test.zig ps1-capi/include/ps1.h build.zig
git commit -m "feat(capi): add ps1-capi frontend with handle lifecycle and BIOS load"
```

---

## Task 2: Disc loading, and `countCueFiles` moves into the core

`Disc.initFromCue` **never fails** — on a malformed cue it silently falls back to a single data track (`disc.zig:150-156`). So `PS1_ERR_BAD_CUE` must be decided in `ps1-capi` *before* calling it. `countCueFiles` currently lives in `ps1-golden/src/golden.zig:157`; rather than duplicate it, move it into `disc.zig` where it belongs and have `ps1-golden` re-export it. That is a pure additive move with no behaviour change, so the trace goldens stay valid.

**Files:**
- Modify: `ps1-core/src/disc.zig` (add `countCueFiles`)
- Modify: `ps1-golden/src/golden.zig:157-165` (replace the definition with a re-export)
- Modify: `ps1-capi/src/root.zig`
- Modify: `ps1-capi/src/capi_test.zig`
- Modify: `ps1-capi/include/ps1.h`

**Interfaces:**
- Consumes: `Handle` from Task 1.
- Produces: `ps1.disc.countCueFiles(cue_text: []const u8) usize`; `ps1_load_disc(*Handle, bin: [*]const u8, bin_len: usize, cue: ?[*]const u8, cue_len: usize) i32`. Passing `cue_len == 0` selects the raw-`.bin` path.

- [ ] **Step 1: Write the failing test**

Append to `ps1-capi/src/capi_test.zig`:

```zig
const single_file_cue =
    \\FILE "game.bin" BINARY
    \\  TRACK 01 MODE2/2352
    \\    INDEX 01 00:00:00
    \\
;

const multi_file_cue =
    \\FILE "a.bin" BINARY
    \\  TRACK 01 MODE2/2352
    \\    INDEX 01 00:00:00
    \\FILE "b.bin" BINARY
    \\  TRACK 02 AUDIO
    \\    INDEX 01 00:00:00
    \\
;

test "load_disc rejects a multi-FILE cue" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(
        @as(i32, -3),
        capi.ps1_load_disc(h, &bin, bin.len, multi_file_cue.ptr, multi_file_cue.len),
    );
    try std.testing.expect(h.disc == null);
}

test "load_disc rejects a cue with no FILE directive" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    const junk = "this is not a cue sheet\n";
    try std.testing.expectEqual(
        @as(i32, -2),
        capi.ps1_load_disc(h, &bin, bin.len, junk.ptr, junk.len),
    );
}

test "load_disc accepts a single-FILE cue and attaches the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(
        @as(i32, 0),
        capi.ps1_load_disc(h, &bin, bin.len, single_file_cue.ptr, single_file_cue.len),
    );
    try std.testing.expect(h.disc != null);
    try std.testing.expectEqual(@as(u8, 1), h.disc.?.track_count);
}

test "load_disc with no cue takes the raw .bin fallback" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0));
    try std.testing.expect(h.disc != null);
    try std.testing.expectEqual(@as(u8, 1), h.disc.?.track_count);
}

test "load_disc rejects an empty image" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const empty = [_]u8{};
    try std.testing.expectEqual(@as(i32, -2), capi.ps1_load_disc(h, &empty, 0, null, 0));
}

test "reset re-attaches the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0));
    capi.ps1_reset(h);
    try std.testing.expect(h.disc != null);
    try std.testing.expect(h.cpu.bus.cdrom.disc != null);
}
```

Also add to `ps1-core/tests/disc_test.zig`:

```zig
test "countCueFiles counts FILE directives" {
    const single = "FILE \"a.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n";
    const multi = "FILE \"a.bin\" BINARY\n  TRACK 01 MODE2/2352\nFILE \"b.bin\" BINARY\n  TRACK 02 AUDIO\n";
    try std.testing.expectEqual(@as(usize, 1), ps1.disc.countCueFiles(single));
    try std.testing.expectEqual(@as(usize, 2), ps1.disc.countCueFiles(multi));
    try std.testing.expectEqual(@as(usize, 0), ps1.disc.countCueFiles("no directives here\n"));
}
```

Check the import alias at the top of `disc_test.zig` before writing this — if it imports `ps1_core` under a different name, match it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `countCueFiles` is not a member of `disc`, and `ps1_load_disc` does not exist.

- [ ] **Step 3: Move `countCueFiles` into the core**

Add to `ps1-core/src/disc.zig`, just above `pub const Disc`:

```zig
/// Counts `FILE` directives in a cue sheet.
///
/// `initFromCue` lays multiple FILEs out using `REM FILESIZE` lines, but a
/// `Disc` holds a single data slice, so a caller that cannot concatenate the
/// images must reject a multi-FILE cue up front rather than mis-lay it out.
pub fn countCueFiles(cue_text: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, cue_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "FILE ")) n += 1;
    }
    return n;
}
```

Then in `ps1-golden/src/golden.zig`, delete the definition at lines 157-165 and put in its place:

```zig
/// Re-exported so the golden harness and `ps1-capi` apply one rule, not two.
pub const countCueFiles = ps1.disc.countCueFiles;
```

`golden.zig` must import the core for this. Check whether it already has `const ps1 = @import("ps1_core");` at the top; if not, add it.

- [ ] **Step 4: Implement `ps1_load_disc`**

Add to `ps1-capi/src/root.zig`:

```zig
/// Attaches a disc. The `.bin` bytes are BORROWED, not copied — `Disc` holds a
/// slice into them, so they must outlive the handle or the next call here.
/// Pass `cue_len == 0` for the raw-`.bin` fallback, which is a single data
/// track at LBA 0 and cannot represent audio tracks.
pub export fn ps1_load_disc(
    h: *Handle,
    bin: [*]const u8,
    bin_len: usize,
    cue: ?[*]const u8,
    cue_len: usize,
) i32 {
    if (bin_len < ps1.constants.sector_bytes) return PS1_ERR_BAD_CUE;

    const data = bin[0..bin_len];
    var d: Disc = undefined;

    if (cue_len > 0) {
        const cue_ptr = cue orelse return PS1_ERR_BAD_CUE;
        const cue_text = cue_ptr[0..cue_len];

        const files = ps1.disc.countCueFiles(cue_text);
        if (files == 0) return PS1_ERR_BAD_CUE;
        if (files > 1) return PS1_ERR_MULTI_FILE_CUE;

        // `initFromCue` silently falls back to a single data track on a cue it
        // cannot parse, so a cue with no TRACK line has to be caught here.
        if (std.mem.indexOf(u8, cue_text, "TRACK ") == null) return PS1_ERR_BAD_CUE;

        d = Disc.initFromCue(cue_text, data);
    } else {
        d = Disc.init(data);
    }

    h.disc = d;
    h.cpu.bus.cdrom.setDisc(d);
    return PS1_OK;
}
```

`ps1.constants` must be reachable. `root.zig` does not re-export it — check, and if it is missing add `pub const constants = @import("constants.zig");` to `ps1-core/src/root.zig` (additive, no behaviour change). If adding it is undesirable, use the literal `2352` with a comment naming `constants.sector_bytes`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Confirm the core move changed no behaviour**

Run: `zig build trace-golden -- verify -Doptimize=ReleaseFast 2>&1 | tail -20`

Note the flag order: `-Doptimize` is a build option and `--` separates the runtime args, so the correct invocation is:

```bash
zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -20
```

Expected: every workload OK. A divergence here means the move was not as pure as it looks — fix it, do not re-capture.

- [ ] **Step 7: Extend the header**

Add to `ps1-capi/include/ps1.h`, before `#endif`:

```c
/* Attaches a disc.
 *
 * BORROWS `bin` — the bytes must outlive the handle, or the next call here.
 * `cue` is parsed immediately and is not borrowed; pass NULL/0 for the raw
 * .bin fallback, which is a single data track at LBA 0 and CANNOT represent
 * audio tracks (a CD-DA title opened this way is silent — say so in the UI).
 *
 * A cue declaring more than one FILE is rejected with PS1_ERR_MULTI_FILE_CUE
 * rather than mis-laid-out.
 */
int32_t ps1_load_disc(Ps1*, const uint8_t* bin, size_t bin_len,
                            const uint8_t* cue, size_t cue_len);
```

- [ ] **Step 8: Commit**

```bash
git add ps1-core/src/disc.zig ps1-core/src/root.zig ps1-core/tests/disc_test.zig \
        ps1-golden/src/golden.zig ps1-capi/src/root.zig ps1-capi/src/capi_test.zig \
        ps1-capi/include/ps1.h
git commit -m "feat(capi): add ps1_load_disc; move countCueFiles into the core disc model"
```

---

## Task 3: Frame execution, buttons, display info, VRAM copy

**Files:**
- Modify: `ps1-capi/src/root.zig`
- Modify: `ps1-capi/src/capi_test.zig`
- Modify: `ps1-capi/include/ps1.h`

**Interfaces:**
- Consumes: `Handle` from Task 1.
- Produces: `Ps1Display` (extern struct, 20 bytes: four `u32` then four `u8`), `ps1_run_frame(*Handle) void`, `ps1_set_buttons(*Handle, u16) void`, `ps1_copy_vram(*const Handle, [*]u16) void`, `ps1_get_display(*const Handle, *Ps1Display) void`.

- [ ] **Step 1: Write the failing test**

Append to `ps1-capi/src/capi_test.zig`:

```zig
test "get_display reports the programmed display area, not the nominal mode size" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // GP1(05h): display start in VRAM — x=320, y=8.
    h.cpu.bus.gpu.writeGp1(0x05000000 | (8 << 10) | 320);

    var out: capi.Ps1Display = undefined;
    capi.ps1_get_display(h, &out);

    try std.testing.expectEqual(@as(u32, 320), out.vram_x);
    try std.testing.expectEqual(@as(u32, 8), out.vram_y);
    try std.testing.expectEqual(h.cpu.bus.gpu.getDisplayWidth(), out.width);
    try std.testing.expectEqual(h.cpu.bus.gpu.getDisplayHeight(), out.height);
}

test "get_display reports display-enabled and pal flags" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    var out: capi.Ps1Display = undefined;

    h.cpu.bus.gpu.disp_env.display_disabled = true;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 0), out.enabled);

    h.cpu.bus.gpu.disp_env.display_disabled = false;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 1), out.enabled);

    h.cpu.bus.gpu.is_ntsc = false;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 1), out.pal);
}

test "get_display reports 24bpp from GP1(08h) bit 4" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    var out: capi.Ps1Display = undefined;

    h.cpu.bus.gpu.disp_env.display_mode = 0;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 0), out.depth24);

    h.cpu.bus.gpu.disp_env.display_mode = 1 << 4;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 1), out.depth24);
}

test "set_buttons passes the mask through unchanged (0 means pressed)" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_buttons(h, 0xFFFF);
    try std.testing.expectEqual(@as(u16, 0xFFFF), h.cpu.bus.sio.buttons);

    capi.ps1_set_buttons(h, 0xFFF7);
    try std.testing.expectEqual(@as(u16, 0xFFF7), h.cpu.bus.sio.buttons);
}

test "copy_vram copies the whole 1024x512 framebuffer" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    h.cpu.bus.gpu.vram.data[0] = 0x7C1F;
    h.cpu.bus.gpu.vram.data[1024 * 512 - 1] = 0x03E0;

    const dst = try std.testing.allocator.alloc(u16, 1024 * 512);
    defer std.testing.allocator.free(dst);
    @memset(dst, 0);

    capi.ps1_copy_vram(h, dst.ptr);

    try std.testing.expectEqual(@as(u16, 0x7C1F), dst[0]);
    try std.testing.expectEqual(@as(u16, 0x03E0), dst[1024 * 512 - 1]);
}

test "run_frame advances the machine and lands out of vblank" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bios = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(bios);
    @memset(bios, 0);
    _ = capi.ps1_load_bios(h, bios.ptr, bios.len);

    capi.ps1_run_frame(h);
    try std.testing.expect(!h.cpu.bus.gpu.is_vblank);
}
```

`writeGp1` and `vram.data` must exist under those names — check `gpu/gpu.zig` and `gpu/vram.zig` and match the real spelling before writing the test. If `writeGp1` is named differently, set `disp_env.vram_x_start`/`vram_y_start` directly instead; the point of the test is that the ABI reports the programmed area.

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `Ps1Display` and the four functions do not exist.

- [ ] **Step 3: Write the implementation**

Add to `ps1-capi/src/root.zig`:

```zig
/// Mirrors `Ps1Display` in ps1.h. `extern struct` pins the C layout.
pub const Ps1Display = extern struct {
    vram_x: u32,
    vram_y: u32,
    width: u32,
    height: u32,
    depth24: u8,
    enabled: u8,
    pal: u8,
    _pad: u8,
};

/// Runs vblank-to-vblank, the same shape as the wasm frontend's `stepFrame`:
/// spin out of any vblank we are already in, then run until the next one.
pub export fn ps1_run_frame(h: *Handle) void {
    if (!h.bios_loaded) return;
    while (h.cpu.bus.gpu.is_vblank) h.cpu.step();
    while (!h.cpu.bus.gpu.is_vblank) h.cpu.step();
}

/// Takes `sio.zig`'s own convention: 0 means PRESSED, 1 means released,
/// 0xFFFF is idle. The ABI deliberately does not re-invent a button enum.
pub export fn ps1_set_buttons(h: *Handle, mask: u16) void {
    h.cpu.bus.sio.setButtons(mask);
}

pub export fn ps1_copy_vram(h: *const Handle, dst: [*]u16) void {
    const src = h.cpu.bus.gpu.vram.data;
    @memcpy(dst[0..src.len], src[0..]);
}

pub export fn ps1_get_display(h: *const Handle, out: *Ps1Display) void {
    const g = &h.cpu.bus.gpu;
    out.* = .{
        .vram_x = g.disp_env.vram_x_start,
        .vram_y = g.disp_env.vram_y_start,
        .width = g.getDisplayWidth(),
        .height = g.getDisplayHeight(),
        .depth24 = @intFromBool((g.disp_env.display_mode & (1 << 4)) != 0),
        .enabled = @intFromBool(!g.disp_env.display_disabled),
        .pal = @intFromBool(!g.is_ntsc),
        ._pad = 0,
    };
}
```

`getDisplayWidth`/`getDisplayHeight`/`getVramPtr` take `*const Self` or `*Self` — check the receivers in `gpu/gpu.zig`. `getVramPtr` takes `*Self` (mutable), which is why `ps1_copy_vram` reaches `vram.data` directly instead; if `vram.data` is not the field name, use `getVramPtr` and drop the `const` from the parameter.

`run_frame` spins forever if the machine never reaches vblank. With a BIOS loaded it always does; the `bios_loaded` guard is what keeps a BIOS-less handle from hanging the caller.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Extend the header**

Add to `ps1-capi/include/ps1.h`, before `#endif`:

```c
typedef struct {
    uint32_t vram_x;     /* disp_env.vram_x_start */
    uint32_t vram_y;     /* disp_env.vram_y_start */
    uint32_t width;      /* getVisibleWidth()  — the PROGRAMMED display area,
                            not the nominal mode size */
    uint32_t height;     /* getVisibleHeight() */
    uint8_t  depth24;    /* GP1(08h) bit 4 */
    uint8_t  enabled;    /* !disp_env.display_disabled */
    uint8_t  pal;        /* for aspect correction */
    uint8_t  _pad;
} Ps1Display;

/* Runs one frame, vblank to vblank. No-op until a BIOS is loaded. */
void    ps1_run_frame(Ps1*);

/* Mask is sio.zig's convention: 0 = PRESSED, 1 = released, 0xFFFF = idle. */
void    ps1_set_buttons(Ps1*, uint16_t mask);

/* dst must hold 1024*512 uint16_t (1 MB), ABGR1555:
   bits 0-4 red, 5-9 green, 10-14 blue, bit 15 mask/STP. */
void    ps1_copy_vram(const Ps1*, uint16_t* dst);
void    ps1_get_display(const Ps1*, Ps1Display* out);
```

- [ ] **Step 6: Commit**

```bash
git add ps1-capi/src/root.zig ps1-capi/src/capi_test.zig ps1-capi/include/ps1.h
git commit -m "feat(capi): add frame execution, input, display info and VRAM copy"
```

---

## Task 4: Audio drain

The SPU ring is `output_buffer: [65536]f32` with `write_idx`/`read_idx`, interleaved stereo at 44100 Hz. The wasm frontend exposes those indices raw and makes JavaScript do the modular arithmetic — that is a wasm-shaped ABI and must not be repeated. The core owns its indices; the caller gets a count.

**Files:**
- Modify: `ps1-capi/src/root.zig`
- Modify: `ps1-capi/src/capi_test.zig`
- Modify: `ps1-capi/include/ps1.h`

**Interfaces:**
- Consumes: `Handle` from Task 1.
- Produces: `ps1_read_audio(*Handle, [*]f32, usize) usize` — returns floats written, always even.

- [ ] **Step 1: Write the failing test**

Append to `ps1-capi/src/capi_test.zig`:

```zig
/// Writes `pairs` stereo pairs into the SPU ring the way the SPU itself does,
/// so the drain tests exercise the real indices rather than a mock.
fn pushAudio(h: *capi.Handle, pairs: usize, first: f32) void {
    const spu = &h.cpu.bus.spu;
    var i: usize = 0;
    while (i < pairs) : (i += 1) {
        const v = first + @as(f32, @floatFromInt(i));
        spu.output_buffer[spu.write_idx] = v;
        spu.output_buffer[(spu.write_idx + 1) % spu.output_buffer.len] = -v;
        spu.write_idx = (spu.write_idx + 2) % spu.output_buffer.len;
    }
}

test "read_audio drains exactly what the SPU wrote, and no more" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    pushAudio(h, 3, 1.0);

    var dst: [16]f32 = undefined;
    const n = capi.ps1_read_audio(h, &dst, dst.len);

    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(f32, 1.0), dst[0]);
    try std.testing.expectEqual(@as(f32, -1.0), dst[1]);
    try std.testing.expectEqual(@as(f32, 3.0), dst[4]);
    try std.testing.expectEqual(@as(f32, -3.0), dst[5]);

    // Nothing left: a second drain must not re-deliver the same samples.
    try std.testing.expectEqual(@as(usize, 0), capi.ps1_read_audio(h, &dst, dst.len));
}

test "read_audio survives the ring wraparound without losing samples" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const spu = &h.cpu.bus.spu;
    const len = spu.output_buffer.len;

    // Park both indices two pairs short of the end so the next write wraps.
    spu.write_idx = len - 4;
    spu.read_idx = len - 4;

    pushAudio(h, 4, 10.0); // 8 floats: 4 before the wrap, 4 after

    var dst: [16]f32 = undefined;
    const n = capi.ps1_read_audio(h, &dst, dst.len);

    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqual(@as(f32, 10.0), dst[0]);
    try std.testing.expectEqual(@as(f32, 11.0), dst[2]);
    try std.testing.expectEqual(@as(f32, 12.0), dst[4]);
    try std.testing.expectEqual(@as(f32, 13.0), dst[6]);
    try std.testing.expectEqual(@as(f32, -13.0), dst[7]);
    try std.testing.expectEqual(@as(usize, 4), spu.read_idx);
}

test "read_audio truncates an odd max_floats down so a stereo pair is never split" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    pushAudio(h, 4, 1.0); // 8 floats available

    var dst: [16]f32 = undefined;
    const n = capi.ps1_read_audio(h, &dst, 5);

    try std.testing.expectEqual(@as(usize, 4), n);
}

test "read_audio returns 0 when the ring is empty" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    var dst: [16]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), capi.ps1_read_audio(h, &dst, dst.len));
}

test "read_audio caps at max_floats and leaves the rest queued" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    pushAudio(h, 5, 1.0); // 10 floats

    var dst: [16]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), capi.ps1_read_audio(h, &dst, 4));
    try std.testing.expectEqual(@as(usize, 6), capi.ps1_read_audio(h, &dst, dst.len));
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `ps1_read_audio` does not exist.

- [ ] **Step 3: Write the implementation**

Add to `ps1-capi/src/root.zig`:

```zig
/// Drains the SPU's output ring into `dst`, returning the number of floats
/// written (interleaved stereo, 44100 Hz).
///
/// The ring's indices belong to the core, not the caller: the wasm frontend
/// exposes them raw and makes JavaScript do the modular arithmetic, which is a
/// wasm-shaped ABI and is not repeated here.
///
/// `max_floats` should be even; an odd value is truncated down so a stereo
/// pair is never split across two calls.
pub export fn ps1_read_audio(h: *Handle, dst: [*]f32, max_floats: usize) usize {
    const spu = &h.cpu.bus.spu;
    const len = spu.output_buffer.len;

    const available = (spu.write_idx + len - spu.read_idx) % len;
    var n = @min(available, max_floats);
    n -= n % 2;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        dst[i] = spu.output_buffer[(spu.read_idx + i) % len];
    }
    spu.read_idx = (spu.read_idx + n) % len;
    return n;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Extend the header**

Add to `ps1-capi/include/ps1.h`, before `#endif`:

```c
/* Drains the SPU ring into dst. Returns the number of floats written —
 * interleaved stereo, 44100 Hz. The core owns the ring indices; this call
 * advances them. max_floats should be even; an odd value is truncated down so
 * a stereo pair is never split across two calls. */
size_t  ps1_read_audio(Ps1*, float* dst, size_t max_floats);
```

- [ ] **Step 6: Commit**

```bash
git add ps1-capi/src/root.zig ps1-capi/src/capi_test.zig ps1-capi/include/ps1.h
git commit -m "feat(capi): add ps1_read_audio, draining the SPU ring across the boundary"
```

---

## Task 5: Ship `libps1core.a` — panic handler, modulemap, build wiring

Two toolchain facts drive this task, both verified during planning:

- Zig's own archiver emits members Apple's `ld` rejects (`64-bit mach-o not 8-byte aligned`). So the library is emitted as a **single object** with `b.addObject` and repacked with `xcrun libtool -static`.
- The repacked archive links cleanly as `-lps1core` against the real core.

**Files:**
- Modify: `ps1-capi/src/root.zig` (panic handler)
- Create: `ps1-capi/include/module.modulemap`
- Modify: `build.zig`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: `zig-out/lib/libps1core.a` via the `zig build capi-lib` step; module `CPs1` for Swift.

- [ ] **Step 1: Add the panic handler**

Append to `ps1-capi/src/root.zig`:

```zig
/// Nothing may unwind into Swift — there is no unwinder there to catch it.
/// Log to stderr and abort, so a crash is a readable message rather than a
/// corrupted stack.
pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = first_trace_addr;
        std.debug.print("ps1-capi PANIC: {s}\n", .{msg});
        std.process.abort();
    }
}.panicFn);
```

Zig 0.16's panic interface is `std.debug.FullPanic(panicFn)` assigned to `pub const panic`. Confirm against `std/debug.zig` in the local toolchain before writing it — if the signature differs, match what the compiler actually wants; the requirement is only that it prints and aborts.

- [ ] **Step 2: Write the modulemap**

Create `ps1-capi/include/module.modulemap`:

```
module CPs1 {
    header "ps1.h"
    export *
}
```

- [ ] **Step 3: Wire the library into build.zig**

Add to `build.zig`, after the capi test block:

```zig
    // The shipped C ABI library.
    //
    // Emitted as one OBJECT and repacked with Apple's libtool, not as a Zig
    // static library: Zig's archiver writes members that Apple's ld rejects
    // outright ("64-bit mach-o not 8-byte aligned"), so `-lps1core` against a
    // Zig-produced .a fails to link.
    //
    // Its core module is pinned to ReleaseFast regardless of -Doptimize, for
    // the same reason the wasm build is: a Debug core runs ~0.45x real time,
    // which turns a 23-second boot into two minutes and reads as a hang.
    const capi_core_mod = b.createModule(.{
        .root_source_file = b.path("ps1-core/src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const capi_obj = b.addObject(.{
        .name = "ps1capi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-capi/src/root.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    capi_obj.root_module.addImport("ps1_core", capi_core_mod);

    const repack = b.addSystemCommand(&.{ "xcrun", "libtool", "-static", "-o" });
    const lib_path = repack.addOutputFileArg("libps1core.a");
    repack.addFileArg(capi_obj.getEmittedBin());

    const install_lib = b.addInstallFile(lib_path, "lib/libps1core.a");

    const capi_lib_step = b.step("capi-lib", "Build libps1core.a for the macOS app");
    capi_lib_step.dependOn(&install_lib.step);
```

- [ ] **Step 4: Verify the library builds and links**

Run:
```bash
zig build capi-lib 2>&1 | tail -20
ls -la zig-out/lib/libps1core.a
nm -gU zig-out/lib/libps1core.a | grep -E "_ps1_(create|destroy|reset|load_bios|load_disc|run_frame|set_buttons|copy_vram|get_display|read_audio)$" | sort
```

Expected: the archive exists, and all **ten** `_ps1_*` symbols are listed as external.

If any symbol is missing, the `export fn` was stripped — confirm it is `pub export fn` and that nothing is gated behind a comptime branch.

- [ ] **Step 5: Commit**

```bash
git add ps1-capi/src/root.zig ps1-capi/include/module.modulemap build.zig
git commit -m "build(capi): emit libps1core.a via libtool repack; add panic handler and modulemap"
```

---

## Task 6: SwiftPM package and the `Ps1Core` wrapper

**Files:**
- Create: `ps1-macos/Package.swift`
- Create: `ps1-macos/Sources/CPs1/empty.c`
- Create: `ps1-macos/Sources/CPs1/include/module.modulemap`
- Create: `ps1-macos/Sources/PS1/Ps1Core.swift`
- Create: `ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift`

**Interfaces:**
- Consumes: `libps1core.a` and `ps1.h` from Task 5.
- Produces: `final class Ps1Core` with `init() throws`, `loadBIOS(_ data: Data) throws`, `loadDisc(bin: Data, cue: Data?) throws`, `reset()`, `runFrame()`, `setButtons(_ mask: UInt16)`, `copyVRAM(into: UnsafeMutablePointer<UInt16>)`, `display() -> Ps1Display`, `readAudio(into:maxFloats:) -> Int`; and `enum Ps1Error: Error { case badBIOSSize, badCue, multiFileCue, outOfMemory, createFailed }`.

- [ ] **Step 1: Create the package manifest**

Create `ps1-macos/Package.swift`:

```swift
// swift-tools-version: 6.2
// tools-version 6.2 is the floor: `.macOS(.v26)` is unavailable in 6.0/6.1 and
// the manifest itself fails to compile.
import PackageDescription

let package = Package(
    name: "PS1",
    platforms: [.macOS(.v26)],
    targets: [
        // Exposes ps1-capi/include/ps1.h to Swift as module CPs1. The static
        // library itself is linked by build.sh with an ABSOLUTE path, not by an
        // unsafeFlags entry here: a relative path in a manifest resolves against
        // the linker's working directory and breaks the moment the package is
        // built from anywhere but its own root.
        .target(name: "CPs1"),
        .executableTarget(name: "PS1", dependencies: ["CPs1"]),
        .testTarget(name: "PS1Tests", dependencies: ["PS1"]),
    ]
)
```

- [ ] **Step 2: Create the C shim target**

Create `ps1-macos/Sources/CPs1/empty.c`:

```c
/* SwiftPM requires at least one source file in a C target. The actual
   declarations live in include/, which re-exports ps1-capi/include/ps1.h. */
```

Create `ps1-macos/Sources/CPs1/include/module.modulemap`:

```
module CPs1 {
    header "ps1_shim.h"
    export *
}
```

Create `ps1-macos/Sources/CPs1/include/ps1_shim.h`:

```c
/* The real contract lives in ps1-capi/include/ps1.h. This shim exists so
   SwiftPM's own include directory stays the module's header root while the
   header of record stays next to the Zig that implements it. */
#include "../../../../ps1-capi/include/ps1.h"
```

The relative depth here must resolve from `ps1-macos/Sources/CPs1/include/` to `ps1-capi/include/`. Count it against the real tree and correct it if it is off — `#include` with a wrong depth fails loudly at compile time, so this is verified by Step 5 rather than by inspection.

- [ ] **Step 3: Write the failing test**

Create `ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

@Test func createAndDestroy() throws {
    let core = try Ps1Core()
    _ = core
}

@Test func rejectsWrongBIOSSize() throws {
    let core = try Ps1Core()
    #expect(throws: Ps1Error.badBIOSSize) {
        try core.loadBIOS(Data(repeating: 0, count: 16))
    }
}

@Test func acceptsCorrectBIOSSize() throws {
    let core = try Ps1Core()
    try core.loadBIOS(Data(repeating: 0, count: 524288))
}

@Test func rejectsMultiFileCue() throws {
    let core = try Ps1Core()
    let cue = """
    FILE "a.bin" BINARY
      TRACK 01 MODE2/2352
        INDEX 01 00:00:00
    FILE "b.bin" BINARY
      TRACK 02 AUDIO
        INDEX 01 00:00:00
    """
    #expect(throws: Ps1Error.multiFileCue) {
        try core.loadDisc(bin: Data(repeating: 0, count: 2352),
                          cue: Data(cue.utf8))
    }
}

@Test func displayReportsProgrammedArea() throws {
    let core = try Ps1Core()
    let d = core.display()
    // A freshly constructed core reports a 256x240 NTSC area — measured
    // against the real core while planning, not assumed.
    #expect(d.width == 256)
    #expect(d.height == 240)
    #expect(d.pal == 0)
}

@Test func readAudioIsEmptyOnAFreshCore() throws {
    let core = try Ps1Core()
    var buf = [Float](repeating: 0, count: 64)
    let n = buf.withUnsafeMutableBufferPointer { core.readAudio(into: $0.baseAddress!, maxFloats: $0.count) }
    #expect(n == 0)
}
```

- [ ] **Step 4: Write `Ps1Core.swift`**

Create `ps1-macos/Sources/PS1/Ps1Core.swift`:

```swift
import Foundation
import CPs1

/// Every failure the C ABI can report, as a Swift error.
enum Ps1Error: Error, Equatable {
    case createFailed
    case badBIOSSize
    case badCue
    case multiFileCue
    case outOfMemory
    case unknown(Int32)

    static func from(_ code: Int32) -> Ps1Error? {
        switch code {
        case 0: return nil
        case -1: return .badBIOSSize
        case -2: return .badCue
        case -3: return .multiFileCue
        case -4: return .outOfMemory
        default: return .unknown(code)
        }
    }
}

/// The ONLY file in this app that touches the C ABI. Nothing else imports
/// CPs1, so the surface can be changed in one place.
///
/// Not thread-safe by itself: the emulator thread owns the instance and is the
/// only caller of `runFrame`/`readAudio`/`copyVRAM`.
final class Ps1Core {
    private let handle: OpaquePointer

    /// `Disc` BORROWS its bytes — it holds a slice, it does not copy. Retaining
    /// the Data here is what keeps that slice valid for the handle's lifetime.
    private var discData: Data?

    init() throws {
        guard let h = ps1_create() else { throw Ps1Error.createFailed }
        self.handle = h
    }

    deinit {
        ps1_destroy(handle)
    }

    func loadBIOS(_ data: Data) throws {
        let code = data.withUnsafeBytes { raw in
            ps1_load_bios(handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if let e = Ps1Error.from(code) { throw e }
    }

    /// `bin` is retained for the handle's lifetime because the core borrows it.
    /// `cue` is parsed immediately and is not retained.
    func loadDisc(bin: Data, cue: Data?) throws {
        // Retain BEFORE the call: the core starts reading these bytes the
        // moment the disc is attached.
        self.discData = bin

        let code: Int32 = bin.withUnsafeBytes { binRaw -> Int32 in
            let binPtr = binRaw.bindMemory(to: UInt8.self).baseAddress
            if let cue {
                return cue.withUnsafeBytes { cueRaw -> Int32 in
                    ps1_load_disc(handle, binPtr, bin.count,
                                  cueRaw.bindMemory(to: UInt8.self).baseAddress, cue.count)
                }
            }
            return ps1_load_disc(handle, binPtr, bin.count, nil, 0)
        }

        if let e = Ps1Error.from(code) {
            self.discData = nil
            throw e
        }
    }

    func reset() { ps1_reset(handle) }
    func runFrame() { ps1_run_frame(handle) }
    func setButtons(_ mask: UInt16) { ps1_set_buttons(handle, mask) }

    /// `dst` must hold 1024*512 UInt16.
    func copyVRAM(into dst: UnsafeMutablePointer<UInt16>) { ps1_copy_vram(handle, dst) }

    func display() -> Ps1Display {
        var d = Ps1Display()
        ps1_get_display(handle, &d)
        return d
    }

    func readAudio(into dst: UnsafeMutablePointer<Float>, maxFloats: Int) -> Int {
        ps1_read_audio(handle, dst, maxFloats)
    }
}
```

- [ ] **Step 5: Build and run the tests**

The static library must exist first, and the linker flags must be absolute.

```bash
zig build capi-lib
REPO=$(git rev-parse --show-toplevel)
swift test --package-path ps1-macos \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | tail -20
```

Expected: all tests pass.

If the `#include` depth in `ps1_shim.h` is wrong, this is where it fails — fix the depth and re-run.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Package.swift ps1-macos/Sources/CPs1 ps1-macos/Sources/PS1/Ps1Core.swift \
        ps1-macos/Tests/PS1Tests/Ps1CoreTests.swift
git commit -m "feat(macos): add SwiftPM package and the Ps1Core C ABI wrapper"
```

---

## Task 7: `AudioRing` — lock-free SPSC float ring

The CoreAudio render callback must never block and never allocate. This is the structure that lets it drain without a lock.

**Files:**
- Create: `ps1-macos/Sources/PS1/AudioRing.swift`
- Create: `ps1-macos/Tests/PS1Tests/AudioRingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `final class AudioRing` with `init(capacity: Int)`, `var filled: Int`, `var freeSpace: Int`, `let capacity: Int`, `func write(_ src: UnsafePointer<Float>, count: Int) -> Int`, `func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int`.

- [ ] **Step 1: Write the failing test**

Create `ps1-macos/Tests/PS1Tests/AudioRingTests.swift`:

```swift
import Testing
@testable import PS1

private func write(_ ring: AudioRing, _ values: [Float]) -> Int {
    var v = values
    return v.withUnsafeMutableBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
}

private func read(_ ring: AudioRing, _ count: Int) -> [Float] {
    var out = [Float](repeating: .nan, count: count)
    let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
    return Array(out.prefix(n))
}

@Test func startsEmpty() {
    let ring = AudioRing(capacity: 8)
    #expect(ring.filled == 0)
    #expect(ring.freeSpace == 8)
}

@Test func writeThenReadRoundTrips() {
    let ring = AudioRing(capacity: 8)
    #expect(write(ring, [1, 2, 3, 4]) == 4)
    #expect(ring.filled == 4)
    #expect(read(ring, 4) == [1, 2, 3, 4])
    #expect(ring.filled == 0)
}

@Test func readOfAnEmptyRingReturnsNothing() {
    let ring = AudioRing(capacity: 8)
    #expect(read(ring, 4).isEmpty)
}

@Test func partialReadLeavesTheRemainder() {
    let ring = AudioRing(capacity: 8)
    _ = write(ring, [1, 2, 3, 4])
    #expect(read(ring, 2) == [1, 2])
    #expect(ring.filled == 2)
    #expect(read(ring, 2) == [3, 4])
}

@Test func writeIsCappedByFreeSpaceAndNeverOverwrites() {
    let ring = AudioRing(capacity: 8)
    // Capacity 8 holds at most 8 samples; a full ring accepts no more.
    #expect(write(ring, [1, 2, 3, 4, 5, 6, 7, 8]) == 8)
    #expect(ring.freeSpace == 0)
    #expect(write(ring, [9, 10]) == 0)
    #expect(read(ring, 8) == [1, 2, 3, 4, 5, 6, 7, 8])
}

@Test func wrapsAroundWithoutLosingSamples() {
    let ring = AudioRing(capacity: 8)
    _ = write(ring, [1, 2, 3, 4, 5, 6])
    #expect(read(ring, 4) == [1, 2, 3, 4])   // read index now at 4
    #expect(write(ring, [7, 8, 9, 10]) == 4) // writes wrap past the end
    #expect(read(ring, 6) == [5, 6, 7, 8, 9, 10])
    #expect(ring.filled == 0)
}

@Test func underrunReadReturnsOnlyWhatIsThere() {
    let ring = AudioRing(capacity: 8)
    _ = write(ring, [1, 2])
    let got = read(ring, 6)
    #expect(got == [1, 2])
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
REPO=$(git rev-parse --show-toplevel)
swift test --package-path ps1-macos --filter AudioRingTests \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | tail -20
```
Expected: FAIL — `AudioRing` is not defined.

- [ ] **Step 3: Write the implementation**

Create `ps1-macos/Sources/PS1/AudioRing.swift`:

```swift
import Foundation
import Synchronization

/// Single-producer / single-consumer float ring.
///
/// The producer is the emulator thread and the consumer is the CoreAudio render
/// callback, which may never block and may never allocate — so this holds one
/// preallocated buffer and two atomics, and no lock.
///
/// The two indices are monotonically increasing and masked on use, so `filled`
/// is a plain subtraction and a full ring is distinguishable from an empty one
/// without wasting a slot.
final class AudioRing: @unchecked Sendable {
    let capacity: Int

    private let buffer: UnsafeMutablePointer<Float>
    private let mask: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two so the index masking is a
    /// bitwise AND rather than a modulo in the audio callback.
    init(capacity: Int) {
        let rounded = max(2, capacity).nextPowerOfTwo
        self.capacity = rounded
        self.mask = rounded - 1
        self.buffer = .allocate(capacity: rounded)
        self.buffer.initialize(repeating: 0, count: rounded)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    var filled: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    var freeSpace: Int { capacity - filled }

    /// Producer side. Writes as much as fits and returns how much that was;
    /// it never overwrites unread samples.
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(count, capacity - (w - r))
        guard n > 0 else { return 0 }

        for i in 0..<n {
            buffer[(w + i) & mask] = src[i]
        }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Consumer side. Returns how many samples were actually available; on
    /// underrun that is fewer than asked for, and the caller writes silence.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(count, w - r)
        guard n > 0 else { return 0 }

        for i in 0..<n {
            dst[i] = buffer[(r + i) & mask]
        }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }
}

private extension Int {
    var nextPowerOfTwo: Int {
        guard self > 1 else { return 1 }
        return 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
REPO=$(git rev-parse --show-toplevel)
swift test --package-path ps1-macos --filter AudioRingTests \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | tail -20
```
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/AudioRing.swift ps1-macos/Tests/PS1Tests/AudioRingTests.swift
git commit -m "feat(macos): add lock-free SPSC AudioRing"
```

---

## Task 8: `InputMap` — keyboard and gamepad to a `UInt16`

**Files:**
- Create: `ps1-macos/Sources/PS1/InputMap.swift`
- Create: `ps1-macos/Tests/PS1Tests/InputMapTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum PadButton: UInt16, CaseIterable` (raw value = the bit's mask), `struct InputMap` with `mutating func press(_:)`, `mutating func release(_:)`, `var mask: UInt16`, `mutating func reset()`, and `static func button(forKey:) -> PadButton?`.

The digital pad's 16 bits, from `sio.zig`'s packet layout (byte 0 is the low half, byte 1 the high half):

| Bit | Button | Bit | Button |
|---|---|---|---|
| 0 | Select | 8 | L2 |
| 1 | L3 | 9 | R2 |
| 2 | R3 | 10 | L1 |
| 3 | Start | 11 | R1 |
| 4 | Up | 12 | Triangle |
| 5 | Right | 13 | Circle |
| 6 | Down | 14 | Cross |
| 7 | Left | 15 | Square |

- [ ] **Step 1: Confirm the bit layout against the core**

Run: `grep -n -B4 -A24 "rx_data = @truncate(self.buttons" ps1-core/src/sio.zig`

Read the packet assembly and confirm the table above matches. If `sio.zig` documents a different order, **the core wins** — correct the table and every test below to match it before writing any code. Record what you found in the commit message.

- [ ] **Step 2: Write the failing test**

Create `ps1-macos/Tests/PS1Tests/InputMapTests.swift`:

```swift
import Testing
@testable import PS1

@Test func idleMaskIsAllOnesBecauseZeroMeansPressed() {
    let map = InputMap()
    #expect(map.mask == 0xFFFF)
}

@Test func pressingClearsExactlyOneBit() {
    var map = InputMap()
    map.press(.cross)
    #expect(map.mask == 0xFFFF & ~PadButton.cross.rawValue)
    #expect(map.mask != 0xFFFF)
}

@Test func releasingRestoresTheBit() {
    var map = InputMap()
    map.press(.start)
    map.release(.start)
    #expect(map.mask == 0xFFFF)
}

@Test func simultaneousPressesClearAllTheirBits() {
    var map = InputMap()
    map.press(.up)
    map.press(.cross)
    map.press(.r1)
    let expected = 0xFFFF & ~(PadButton.up.rawValue | PadButton.cross.rawValue | PadButton.r1.rawValue)
    #expect(map.mask == expected)
}

@Test func releasingOneOfSeveralLeavesTheOthersPressed() {
    var map = InputMap()
    map.press(.up)
    map.press(.cross)
    map.release(.up)
    #expect(map.mask == 0xFFFF & ~PadButton.cross.rawValue)
}

@Test func repeatedPressIsIdempotent() {
    var map = InputMap()
    map.press(.square)
    let once = map.mask
    map.press(.square)
    #expect(map.mask == once)
}

@Test func resetReturnsToIdle() {
    var map = InputMap()
    map.press(.up)
    map.press(.circle)
    map.reset()
    #expect(map.mask == 0xFFFF)
}

@Test func everyButtonOwnsADistinctBit() {
    var seen: UInt16 = 0
    for b in PadButton.allCases {
        #expect(b.rawValue.nonzeroBitCount == 1)
        #expect(seen & b.rawValue == 0)
        seen |= b.rawValue
    }
    #expect(seen == 0xFFFF)
}

@Test func arrowKeysMapToTheDPad() {
    #expect(InputMap.button(forKey: 126) == .up)
    #expect(InputMap.button(forKey: 125) == .down)
    #expect(InputMap.button(forKey: 123) == .left)
    #expect(InputMap.button(forKey: 124) == .right)
}

@Test func unmappedKeyReturnsNil() {
    #expect(InputMap.button(forKey: 999) == nil)
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
REPO=$(git rev-parse --show-toplevel)
swift test --package-path ps1-macos --filter InputMapTests \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | tail -20
```
Expected: FAIL — `InputMap` is not defined.

- [ ] **Step 4: Write the implementation**

Create `ps1-macos/Sources/PS1/InputMap.swift`:

```swift
import Foundation

/// One bit each, in `sio.zig`'s packet order. The raw value IS the bit mask.
enum PadButton: UInt16, CaseIterable {
    case select   = 0x0001
    case l3       = 0x0002
    case r3       = 0x0004
    case start    = 0x0008
    case up       = 0x0010
    case right    = 0x0020
    case down     = 0x0040
    case left     = 0x0080
    case l2       = 0x0100
    case r2       = 0x0200
    case l1       = 0x0400
    case r1       = 0x0800
    case triangle = 0x1000
    case circle   = 0x2000
    case cross    = 0x4000
    case square   = 0x8000
}

/// Accumulates pressed buttons into the mask the core wants.
///
/// The inversion is the whole point: the pad reports **0 for pressed**, so idle
/// is 0xFFFF and pressing CLEARS a bit. Getting this backwards makes every
/// button appear held down at once, which reads as a stuck controller.
struct InputMap {
    private var pressed: UInt16 = 0

    var mask: UInt16 { ~pressed }

    mutating func press(_ b: PadButton) { pressed |= b.rawValue }
    mutating func release(_ b: PadButton) { pressed &= ~b.rawValue }
    mutating func reset() { pressed = 0 }

    /// macOS virtual key codes. WASD is deliberately absent: the D-pad is on
    /// the arrows and the face buttons are on the right hand.
    static func button(forKey keyCode: UInt16) -> PadButton? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 6:   return .cross     // Z
        case 7:   return .square    // X
        case 8:   return .circle    // C
        case 9:   return .triangle  // V
        case 36:  return .start     // Return
        case 49:  return .select    // Space
        case 12:  return .l1        // Q
        case 13:  return .r1        // W
        case 0:   return .l2        // A
        case 1:   return .r2        // S
        default:  return nil
        }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
REPO=$(git rev-parse --show-toplevel)
swift test --package-path ps1-macos --filter InputMapTests \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | tail -20
```
Expected: PASS, 10 tests.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/InputMap.swift ps1-macos/Tests/PS1Tests/InputMapTests.swift
git commit -m "feat(macos): add InputMap with sio.zig's 0-means-pressed convention"
```

---

## Task 9: `EmulatorRunner` — thread, pacing, triple buffer

**Files:**
- Create: `ps1-macos/Sources/PS1/EmulatorRunner.swift`

**Interfaces:**
- Consumes: `Ps1Core` (Task 6), `AudioRing` (Task 7).
- Produces: `final class EmulatorRunner` with `init(core: Ps1Core, ring: AudioRing)`, `func start()`, `func stop()`, `var isPaused: Bool { get set }`, `func setButtons(_ mask: UInt16)`, `func withNewestFrame(_ body: (UnsafePointer<UInt16>, Ps1Display) -> Void)`, `func signalAudioDrained()`, and `static let vramCount = 1024 * 512`.

- [ ] **Step 1: Write the implementation**

Create `ps1-macos/Sources/PS1/EmulatorRunner.swift`:

```swift
import Foundation
import Synchronization

/// Owns the emulator thread.
///
/// **Audio is the master clock.** A dropped audio buffer is far more audible
/// than a dropped video frame, and the audio device's clock is the only clock
/// here that cannot be made to wait — so the emulator runs flat out until the
/// ring is full, then blocks until the render callback has drained some.
///
/// Frame handoff is three slots and one atomic index: single producer, single
/// consumer, no lock. If the emulator runs slightly ahead of or behind the
/// display a frame repeats or is skipped, which is invisible at 59.94 against
/// 60 Hz and is correct on a 120 Hz ProMotion panel too.
final class EmulatorRunner: @unchecked Sendable {
    static let vramCount = 1024 * 512

    private let core: Ps1Core
    private let ring: AudioRing

    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let paused = Atomic<Bool>(false)

    /// Triple buffer. `newest` is the only shared mutable index.
    private let slots: [UnsafeMutablePointer<UInt16>]
    private let newest = Atomic<Int>(0)
    private var displays: [Ps1Display]
    private let displayLock = NSLock()

    /// The producer sleeps on this when the ring is full; the audio callback
    /// signals it once the fill drops below `lowWater`.
    private let pacing = NSCondition()

    /// Signalled by the emulator thread as it exits, so `stop()` can join.
    private let finished = NSCondition()
    private var hasFinished = false

    private let highWater: Int
    private let lowWater: Int

    private let buttons = Atomic<UInt32>(0xFFFF)

    init(core: Ps1Core, ring: AudioRing) {
        self.core = core
        self.ring = ring
        self.slots = (0..<3).map { _ in
            let p = UnsafeMutablePointer<UInt16>.allocate(capacity: Self.vramCount)
            p.initialize(repeating: 0, count: Self.vramCount)
            return p
        }
        self.displays = Array(repeating: Ps1Display(), count: 3)
        // About four emulated frames of stereo audio: 44100/60 * 2 ~= 1470
        // floats a frame.
        self.highWater = 1470 * 4
        self.lowWater = 1470 * 2
    }

    deinit {
        stop()
        for s in slots {
            s.deinitialize(count: Self.vramCount)
            s.deallocate()
        }
    }

    var isPaused: Bool {
        get { paused.load(ordering: .acquiring) }
        set {
            paused.store(newValue, ordering: .releasing)
            pacing.lock(); pacing.signal(); pacing.unlock()
        }
    }

    func setButtons(_ mask: UInt16) {
        buttons.store(UInt32(mask), ordering: .releasing)
    }

    func start() {
        guard !running.load(ordering: .acquiring) else { return }
        running.store(true, ordering: .releasing)

        finished.lock()
        hasFinished = false
        finished.unlock()

        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "ps1.emulator"
        t.qualityOfService = .userInteractive
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    /// Blocks until the emulator thread has actually left `runLoop`.
    ///
    /// This wait is load-bearing, not tidiness: the runner holds the only
    /// strong reference to `Ps1Core` that the thread uses, and the view model
    /// drops its own reference right after calling `stop()`. Returning while
    /// the thread is still mid-frame lets it call into a destroyed handle —
    /// a use-after-free that would surface as a random crash on eject.
    func stop() {
        guard running.load(ordering: .acquiring) else { return }
        running.store(false, ordering: .releasing)

        pacing.lock(); pacing.broadcast(); pacing.unlock()

        finished.lock()
        while !hasFinished {
            if !finished.wait(until: Date().addingTimeInterval(1.0)) { break }
        }
        finished.unlock()

        thread = nil
    }

    /// Called from the audio callback once it has taken samples out of the ring.
    func signalAudioDrained() {
        guard ring.filled < lowWater else { return }
        pacing.lock(); pacing.signal(); pacing.unlock()
    }

    /// Renderer side. Hands the newest complete frame to `body`.
    func withNewestFrame(_ body: (UnsafePointer<UInt16>, Ps1Display) -> Void) {
        let i = newest.load(ordering: .acquiring)
        displayLock.lock()
        let d = displays[i]
        displayLock.unlock()
        body(UnsafePointer(slots[i]), d)
    }

    private func runLoop() {
        defer {
            finished.lock()
            hasFinished = true
            finished.broadcast()
            finished.unlock()
        }

        var audioScratch = [Float](repeating: 0, count: 8192)

        while running.load(ordering: .acquiring) {
            if paused.load(ordering: .acquiring) {
                pacing.lock()
                if paused.load(ordering: .acquiring) && running.load(ordering: .acquiring) {
                    pacing.wait(until: Date().addingTimeInterval(0.05))
                }
                pacing.unlock()
                continue
            }

            // Audio is the clock: stop producing once the ring is full enough.
            if ring.filled > highWater {
                pacing.lock()
                if ring.filled > highWater && running.load(ordering: .acquiring) {
                    pacing.wait(until: Date().addingTimeInterval(0.05))
                }
                pacing.unlock()
                continue
            }

            core.setButtons(UInt16(truncatingIfNeeded: buttons.load(ordering: .acquiring)))
            core.runFrame()

            let produced = audioScratch.withUnsafeMutableBufferPointer { buf in
                core.readAudio(into: buf.baseAddress!, maxFloats: buf.count)
            }
            if produced > 0 {
                audioScratch.withUnsafeBufferPointer { buf in
                    _ = ring.write(buf.baseAddress!, count: produced)
                }
            }

            // Publish into the slot the renderer is NOT looking at, then flip.
            let next = (newest.load(ordering: .relaxed) + 1) % 3
            core.copyVRAM(into: slots[next])
            let d = core.display()
            displayLock.lock()
            displays[next] = d
            displayLock.unlock()
            newest.store(next, ordering: .releasing)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
REPO=$(git rev-parse --show-toplevel)
swift build --package-path ps1-macos \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | grep -viE "^\[|search path" | tail -20
```
Expected: `Build complete!`

There is no unit test here on purpose: the class is threads and timing, whose bug surface is not reachable from a deterministic test. Its two testable pieces — the ring arithmetic and the button mask — are already covered in Tasks 7 and 8. It is exercised for real in Task 14.

- [ ] **Step 3: Commit**

```bash
git add ps1-macos/Sources/PS1/EmulatorRunner.swift
git commit -m "feat(macos): add EmulatorRunner with audio-clocked pacing and a triple buffer"
```

---

## Task 10: `AudioOutput` — the CoreAudio render callback

**Files:**
- Create: `ps1-macos/Sources/PS1/AudioOutput.swift`

**Interfaces:**
- Consumes: `AudioRing` (Task 7), `EmulatorRunner` (Task 9).
- Produces: `final class AudioOutput` with `init(ring: AudioRing, runner: EmulatorRunner) throws`, `func start() throws`, `func stop()`.

- [ ] **Step 1: Write the implementation**

Create `ps1-macos/Sources/PS1/AudioOutput.swift`:

```swift
import Foundation
import AudioToolbox
import AVFoundation

/// The default output AudioUnit, pulling straight from the ring.
///
/// The render callback NEVER blocks and NEVER allocates. On underrun it writes
/// silence for that callback and returns — the alternative, waiting for the
/// emulator, would glitch the whole device.
final class AudioOutput {
    private var unit: AudioUnit?
    private let ring: AudioRing
    private unowned let runner: EmulatorRunner

    static let sampleRate: Double = 44100

    init(ring: AudioRing, runner: EmulatorRunner) throws {
        self.ring = ring
        self.runner = runner
        try setup()
    }

    deinit { stop() }

    private func setup() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioError.noComponent
        }

        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au))
        guard let au else { throw AudioError.noComponent }
        self.unit = au

        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,   // interleaved stereo float32
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0,
                                       &format, UInt32(MemoryLayout.size(ofValue: format))))

        var callback = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout.size(ofValue: callback))))

        try check(AudioUnitInitialize(au))
    }

    func start() throws {
        guard let unit else { throw AudioError.noComponent }
        try check(AudioOutputUnitStart(unit))
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    /// Real-time thread. No locks, no allocation, no Swift runtime calls that
    /// could take one.
    fileprivate func render(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        guard let out = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

        let wanted = Int(frames) * 2
        let got = ring.read(into: out, count: wanted)
        if got < wanted {
            // Underrun: silence for the remainder of this callback only.
            memset(out + got, 0, (wanted - got) * MemoryLayout<Float>.size)
        }
        runner.signalAudioDrained()
        return noErr
    }

    enum AudioError: Error { case noComponent, osStatus(OSStatus) }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw AudioError.osStatus(status) }
    }
}

private func renderCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let data else { return noErr }
    let output = Unmanaged<AudioOutput>.fromOpaque(refCon).takeUnretainedValue()
    return output.render(frames: frames, buffers: data)
}
```

- [ ] **Step 2: Verify it compiles**

```bash
REPO=$(git rev-parse --show-toplevel)
swift build --package-path ps1-macos \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | grep -viE "^\[|search path" | tail -20
```
Expected: `Build complete!`

`kAudioUnitSubType_DefaultOutput` is the macOS spelling; if the compiler rejects it, use `kAudioUnitSubType_HALOutput` and set `kAudioOutputUnitProperty_EnableIO` — do not switch to an iOS-only subtype.

- [ ] **Step 3: Commit**

```bash
git add ps1-macos/Sources/PS1/AudioOutput.swift
git commit -m "feat(macos): add AudioOutput with a non-blocking render callback"
```

---

## Task 11: Metal display — shader and view

VRAM uploads as a `r16Uint` 1024x512 texture and the fragment shader does the unpacking, cropping and aspect correction. **This is chosen because it is the seam the future Metal rasterizer plugs into**: when VRAM lives on the GPU, only the upload disappears and the shader is unchanged. Converting to RGBA on the Zig side would bake in a CPU pass the rasterizer spec would have to tear out.

**Files:**
- Create: `ps1-macos/Sources/PS1/DisplayShader.swift`
- Create: `ps1-macos/Sources/PS1/MetalDisplayView.swift`

**Interfaces:**
- Consumes: `EmulatorRunner` (Task 9).
- Produces: `struct MetalDisplayView: NSViewRepresentable` with `init(runner: EmulatorRunner)`; `enum DisplayShader { static let source: String }`.

- [ ] **Step 1: Write the shader source**

Create `ps1-macos/Sources/PS1/DisplayShader.swift`:

```swift
/// Metal source, compiled at RUNTIME via `device.makeLibrary(source:options:)`.
///
/// It is a string rather than a `.metal` file because the offline `metal`
/// compiler ships with Xcode, and this project builds against Command Line
/// Tools only — `xcrun metal` is not available, so there is no `.metallib` to
/// put in the bundle.
enum DisplayShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint  vram_x;
        uint  vram_y;
        uint  width;
        uint  height;
        uint  depth24;
        uint  enabled;
        float scale_x;   // letterboxing: 1.0 on the axis that fills
        float scale_y;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut display_vertex(uint vid [[vertex_id]],
                                    constant Params& p [[buffer(0)]]) {
        // One oversized triangle covering the viewport — no vertex buffer.
        float2 pos[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        float2 v = pos[vid];

        VertexOut out;
        out.position = float4(v.x * p.scale_x, v.y * p.scale_y, 0.0, 1.0);
        // uv (0,0) at top-left of the visible area.
        out.uv = float2(v.x * 0.5 + 0.5, v.y * -0.5 + 0.5);
        return out;
    }

    fragment float4 display_fragment(VertexOut in [[stage_in]],
                                     texture2d<uint, access::read> vram [[texture(0)]],
                                     constant Params& p [[buffer(0)]]) {
        if (p.enabled == 0 || p.width == 0 || p.height == 0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        uint px = uint(in.uv.x * float(p.width));
        uint py = uint(in.uv.y * float(p.height));
        if (px >= p.width)  px = p.width  - 1;
        if (py >= p.height) py = p.height - 1;

        uint row = (p.vram_y + py) & 511;

        if (p.depth24 != 0) {
            // 24bpp: three bytes per pixel packed across 16-bit VRAM words.
            uint byte_off = px * 3;
            uint w0 = vram.read(uint2((p.vram_x + (byte_off >> 1)) & 1023, row)).r;
            uint w1 = vram.read(uint2((p.vram_x + (byte_off >> 1) + 1) & 1023, row)).r;

            uint r, g, b;
            if ((byte_off & 1) == 0) {
                r =  w0        & 0xFF;
                g = (w0 >> 8)  & 0xFF;
                b =  w1        & 0xFF;
            } else {
                r = (w0 >> 8)  & 0xFF;
                g =  w1        & 0xFF;
                b = (w1 >> 8)  & 0xFF;
            }
            return float4(float(r) / 255.0, float(g) / 255.0, float(b) / 255.0, 1.0);
        }

        // ABGR1555: bits 0-4 red, 5-9 green, 10-14 blue, bit 15 mask/STP.
        uint texel = vram.read(uint2((p.vram_x + px) & 1023, row)).r;
        float r = float( texel        & 0x1F) / 31.0;
        float g = float((texel >>  5) & 0x1F) / 31.0;
        float b = float((texel >> 10) & 0x1F) / 31.0;
        return float4(r, g, b, 1.0);
    }
    """
}
```

- [ ] **Step 2: Write the view**

Create `ps1-macos/Sources/PS1/MetalDisplayView.swift`:

```swift
import SwiftUI
import MetalKit

struct MetalDisplayView: NSViewRepresentable {
    let runner: EmulatorRunner

    func makeCoordinator() -> Coordinator { Coordinator(runner: runner) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        // Black, not clear: the game view gets no glass effect, so there is
        // nothing to refract through it.
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        /// Mirrors `Params` in DisplayShader.source. Field order and types must
        /// match exactly.
        private struct Params {
            var vramX: UInt32 = 0
            var vramY: UInt32 = 0
            var width: UInt32 = 0
            var height: UInt32 = 0
            var depth24: UInt32 = 0
            var enabled: UInt32 = 0
            var scaleX: Float = 1
            var scaleY: Float = 1
        }

        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let texture: MTLTexture
        private let runner: EmulatorRunner

        init(runner: EmulatorRunner) {
            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError("No Metal device")
            }
            guard let queue = device.makeCommandQueue() else {
                fatalError("No Metal command queue")
            }

            // Compiled here, at runtime — see DisplayShader for why.
            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: DisplayShader.source, options: nil)
            } catch {
                fatalError("Display shader failed to compile: \(error)")
            }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "display_vertex")
            desc.fragmentFunction = library.makeFunction(name: "display_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
                fatalError("Display pipeline failed to build")
            }

            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Uint, width: 1024, height: 512, mipmapped: false)
            texDesc.usage = .shaderRead
            texDesc.storageMode = .managed
            guard let texture = device.makeTexture(descriptor: texDesc) else {
                fatalError("VRAM texture allocation failed")
            }

            self.device = device
            self.queue = queue
            self.pipeline = pipeline
            self.texture = texture
            self.runner = runner
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer() else { return }

            var params = Params()

            runner.withNewestFrame { vram, display in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, 1024, 512),
                    mipmapLevel: 0,
                    withBytes: vram,
                    bytesPerRow: 1024 * MemoryLayout<UInt16>.size
                )
                params.vramX = display.vram_x
                params.vramY = display.vram_y
                params.width = display.width
                params.height = display.height
                params.depth24 = UInt32(display.depth24)
                params.enabled = UInt32(display.enabled)
            }

            // The PS1 output is 4:3 whatever the pixel resolution is, so aspect
            // correction is a property of the display, not of `width/height`.
            let target: Float = 4.0 / 3.0
            let size = view.drawableSize
            if size.height > 0 {
                let viewAspect = Float(size.width / size.height)
                if viewAspect > target {
                    params.scaleX = target / viewAspect
                    params.scaleY = 1
                } else {
                    params.scaleX = 1
                    params.scaleY = viewAspect / target
                }
            }

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
            enc.setVertexBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()

            cmd.present(drawable)
            cmd.commit()
        }
    }
}
```

- [ ] **Step 3: Verify it compiles**

```bash
REPO=$(git rev-parse --show-toplevel)
swift build --package-path ps1-macos \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | grep -viE "^\[|search path" | tail -20
```
Expected: `Build complete!`

The shader itself is only compiled when the view is first constructed, so a syntax error in it surfaces at runtime in Task 14, not here.

- [ ] **Step 4: Commit**

```bash
git add ps1-macos/Sources/PS1/DisplayShader.swift ps1-macos/Sources/PS1/MetalDisplayView.swift
git commit -m "feat(macos): add the Metal display path with a runtime-compiled shader"
```

---

## Task 12: `BiosLibrary` — folder bookmark and region selection

Region selection reuses `ps1-golden`'s rule verbatim, keyed off the disc's filename. A US BIOS in front of a PAL disc stops at the region-lock screen, so this is load-bearing, not a nicety.

**Files:**
- Create: `ps1-macos/Sources/PS1/BiosLibrary.swift`
- Create: `ps1-macos/Tests/PS1Tests/BiosLibraryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum BiosRegion: String { case europe = "SCPH-7502", japan = "SCPH-1000", us = "SCPH-1001" }` with `static func forDisc(named: String) -> BiosRegion`; `final class BiosLibrary` with `var folderURL: URL?`, `func setFolder(_ url: URL)`, `func biosData(forDisc named: String) throws -> Data`, `func setExplicitBIOS(_ url: URL) throws`.

- [ ] **Step 1: Write the failing test**

Create `ps1-macos/Tests/PS1Tests/BiosLibraryTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

@Test func europeDiscSelectsThePALBios() {
    #expect(BiosRegion.forDisc(named: "Rayman (Europe) (En,Fr,De).cue") == .europe)
    #expect(BiosRegion.forDisc(named: "Doom (Europe) (EDC).cue") == .europe)
}

@Test func japanDiscSelectsTheJapaneseBios() {
    #expect(BiosRegion.forDisc(named: "Some Game (Japan).cue") == .japan)
}

@Test func everythingElseSelectsTheUSBios() {
    #expect(BiosRegion.forDisc(named: "Silent Hill (USA).cue") == .us)
    #expect(BiosRegion.forDisc(named: "Croc - Legend of the Gobbos.cue") == .us)
}

@Test func regionRawValueIsTheBiosFilenameStem() {
    #expect(BiosRegion.europe.rawValue == "SCPH-7502")
    #expect(BiosRegion.japan.rawValue == "SCPH-1000")
    #expect(BiosRegion.us.rawValue == "SCPH-1001")
}

@Test func matchIsCaseInsensitive() {
    #expect(BiosRegion.forDisc(named: "Game (EUROPE).cue") == .europe)
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
REPO=$(git rev-parse --show-toplevel)
swift test --package-path ps1-macos --filter BiosLibraryTests \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | tail -20
```
Expected: FAIL — `BiosRegion` is not defined.

- [ ] **Step 3: Write the implementation**

Create `ps1-macos/Sources/PS1/BiosLibrary.swift`:

```swift
import Foundation

/// The BIOS a disc needs, keyed off its filename — `ps1-golden`'s rule,
/// verbatim. A US BIOS in front of a PAL disc stops at the region-lock screen,
/// so this is load-bearing.
enum BiosRegion: String, CaseIterable {
    case europe = "SCPH-7502"
    case japan  = "SCPH-1000"
    case us     = "SCPH-1001"

    static func forDisc(named name: String) -> BiosRegion {
        let lower = name.lowercased()
        if lower.contains("(europe)") { return .europe }
        if lower.contains("(japan)")  { return .japan }
        return .us
    }
}

enum BiosError: Error {
    case noFolderSelected
    case noMatchingBIOS(BiosRegion)
    case wrongSize(Int)
    case unreadable
}

/// Holds the user's BIOS folder as a security-scoped bookmark.
///
/// The app is not sandboxed in v1, but storing a bookmark rather than a path
/// makes sandboxing later a settings change instead of a rewrite.
final class BiosLibrary {
    private static let bookmarkKey = "biosFolderBookmark"
    private static let explicitKey = "biosExplicitBookmark"

    private(set) var folderURL: URL?
    private var explicitURL: URL?

    init() {
        folderURL = Self.resolveBookmark(forKey: Self.bookmarkKey)
        explicitURL = Self.resolveBookmark(forKey: Self.explicitKey)
    }

    func setFolder(_ url: URL) {
        folderURL = url
        Self.storeBookmark(url, forKey: Self.bookmarkKey)
    }

    /// Fallback for a folder that yields no match: the user picks one file and
    /// that choice is remembered.
    func setExplicitBIOS(_ url: URL) throws {
        _ = try Self.read(url)
        explicitURL = url
        Self.storeBookmark(url, forKey: Self.explicitKey)
    }

    func biosData(forDisc name: String) throws -> Data {
        let region = BiosRegion.forDisc(named: name)

        if let folder = folderURL,
           let match = Self.findBIOS(in: folder, matching: region) {
            return try Self.read(match)
        }
        if let explicitURL {
            return try Self.read(explicitURL)
        }
        if folderURL == nil { throw BiosError.noFolderSelected }
        throw BiosError.noMatchingBIOS(region)
    }

    /// Matches on the stem so `SCPH-1001_BIOS_1995_US.bin` is found from
    /// `SCPH-1001` — which is how the files in this repo are actually named.
    private static func findBIOS(in folder: URL, matching region: BiosRegion) -> URL? {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return nil }

        return entries.first { $0.lastPathComponent.lowercased()
            .hasPrefix(region.rawValue.lowercased()) }
    }

    private static func read(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw BiosError.unreadable }
        guard data.count == 524288 else { throw BiosError.wrongSize(data.count) }
        return data
    }

    private static func storeBookmark(_ url: URL, forKey key: String) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func resolveBookmark(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale) else { return nil }
        return url
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
REPO=$(git rev-parse --show-toplevel)
swift test --package-path ps1-macos --filter BiosLibraryTests \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | tail -20
```
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/BiosLibrary.swift ps1-macos/Tests/PS1Tests/BiosLibraryTests.swift
git commit -m "feat(macos): add BiosLibrary with ps1-golden's region-selection rule"
```

---

## Task 13: The SwiftUI shell — Liquid Glass chrome

The window is full-size content so the Metal view extends under the title bar and chrome floats **over** the game. Without that the material has nothing to refract and the whole adoption is pointless. The game view itself gets no glass effect — nearest-neighbour PS1 pixels behind a refractive layer look wrong and it would cost GPU time for nothing.

**Files:**
- Create: `ps1-macos/Sources/PS1/EmulatorViewModel.swift`
- Create: `ps1-macos/Sources/PS1/GameHUD.swift`
- Create: `ps1-macos/Sources/PS1/EmptyStateView.swift`
- Create: `ps1-macos/Sources/PS1/ContentView.swift`
- Create: `ps1-macos/Sources/PS1/PS1App.swift`

**Interfaces:**
- Consumes: everything from Tasks 6-12.
- Produces: `@MainActor @Observable final class EmulatorViewModel`; the four views.

- [ ] **Step 1: Write the view model**

Create `ps1-macos/Sources/PS1/EmulatorViewModel.swift`:

```swift
import SwiftUI
import GameController

@MainActor
@Observable
final class EmulatorViewModel {
    enum Stage { case needsBIOS, needsDisc, playing }

    private(set) var stage: Stage = .needsBIOS
    private(set) var discTitle: String = ""
    var errorMessage: String?
    var showRawBinWarning = false

    private(set) var runner: EmulatorRunner?
    private var core: Ps1Core?
    private var ring: AudioRing?
    private var audio: AudioOutput?
    private let bios = BiosLibrary()

    private var input = InputMap()

    init() {
        stage = bios.folderURL == nil ? .needsBIOS : .needsDisc
        observeControllers()
    }

    var isPaused: Bool {
        get { runner?.isPaused ?? false }
        set { runner?.isPaused = newValue }
    }

    func chooseBIOSFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder holding your SCPH-*.bin BIOS files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bios.setFolder(url)
        stage = .needsDisc
    }

    func openDisc() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Open a .cue (preferred) or a raw .bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(disc: url)
    }

    func load(disc url: URL) {
        do {
            let isCue = url.pathExtension.lowercased() == "cue"
            let binURL = isCue ? try Self.binURL(forCue: url) : url

            let binData = try Data(contentsOf: binURL)
            let cueData = isCue ? try Data(contentsOf: url) : nil
            let biosData = try bios.biosData(forDisc: url.lastPathComponent)

            let core = try Ps1Core()
            try core.loadBIOS(biosData)
            try core.loadDisc(bin: binData, cue: cueData)

            let ring = AudioRing(capacity: 1 << 15)
            let runner = EmulatorRunner(core: core, ring: ring)
            let audio = try AudioOutput(ring: ring, runner: runner)

            self.core = core
            self.ring = ring
            self.runner = runner
            self.audio = audio

            runner.start()
            try audio.start()

            discTitle = url.deletingPathExtension().lastPathComponent
            stage = .playing
            // A raw .bin cannot represent audio tracks, so a CD-DA title opened
            // this way is silent — which looks like a bug unless we say so.
            showRawBinWarning = !isCue
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func reset() { runner?.isPaused = false; core?.reset() }

    func eject() {
        audio?.stop()
        runner?.stop()
        audio = nil
        runner = nil
        core = nil
        ring = nil
        discTitle = ""
        stage = .needsDisc
    }

    // MARK: Input

    func keyDown(_ keyCode: UInt16) -> Bool {
        guard let b = InputMap.button(forKey: keyCode) else { return false }
        input.press(b)
        runner?.setButtons(input.mask)
        return true
    }

    func keyUp(_ keyCode: UInt16) -> Bool {
        guard let b = InputMap.button(forKey: keyCode) else { return false }
        input.release(b)
        runner?.setButtons(input.mask)
        return true
    }

    private func observeControllers() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let pad = (note.object as? GCController)?.extendedGamepad else { return }
            MainActor.assumeIsolated { self?.bind(pad) }
        }
        for c in GCController.controllers() {
            if let pad = c.extendedGamepad { bind(pad) }
        }
    }

    private func bind(_ pad: GCExtendedGamepad) {
        pad.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var m = InputMap()
                if pad.dpad.up.isPressed    { m.press(.up) }
                if pad.dpad.down.isPressed  { m.press(.down) }
                if pad.dpad.left.isPressed  { m.press(.left) }
                if pad.dpad.right.isPressed { m.press(.right) }
                if pad.buttonA.isPressed    { m.press(.cross) }
                if pad.buttonB.isPressed    { m.press(.circle) }
                if pad.buttonX.isPressed    { m.press(.square) }
                if pad.buttonY.isPressed    { m.press(.triangle) }
                if pad.leftShoulder.isPressed  { m.press(.l1) }
                if pad.rightShoulder.isPressed { m.press(.r1) }
                if pad.leftTrigger.isPressed   { m.press(.l2) }
                if pad.rightTrigger.isPressed  { m.press(.r2) }
                if pad.buttonMenu.isPressed    { m.press(.start) }
                if pad.buttonOptions?.isPressed == true { m.press(.select) }
                self.input = m
                self.runner?.setButtons(m.mask)
            }
        }
    }

    // MARK: Helpers

    /// Resolves the `FILE "..."` line in a cue against the cue's own directory.
    private static func binURL(forCue cue: URL) throws -> URL {
        let text = try String(contentsOf: cue, encoding: .utf8)
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("FILE ") else { continue }
            guard let open = line.firstIndex(of: "\""),
                  let close = line.lastIndex(of: "\""), open < close else { continue }
            let name = String(line[line.index(after: open)..<close])
            return cue.deletingLastPathComponent().appendingPathComponent(name)
        }
        throw Ps1Error.badCue
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case Ps1Error.badBIOSSize:    return "That BIOS file is not 512 KB. PlayStation BIOS images are exactly 524,288 bytes."
        case Ps1Error.multiFileCue:   return "This cue sheet declares more than one FILE, which this emulator cannot lay out. Use a single-file rip."
        case Ps1Error.badCue:         return "That cue sheet could not be parsed."
        case Ps1Error.outOfMemory:    return "Out of memory."
        case Ps1Error.createFailed:   return "Could not start the emulator core."
        case BiosError.noFolderSelected: return "Choose a BIOS folder first."
        case BiosError.noMatchingBIOS(let r): return "No \(r.rawValue) BIOS found in your BIOS folder. This disc needs it."
        case BiosError.wrongSize(let n):  return "That BIOS file is \(n) bytes; it must be exactly 524,288."
        case BiosError.unreadable:    return "That BIOS file could not be read."
        default: return String(describing: error)
        }
    }
}
```

- [ ] **Step 2: Write the HUD**

Create `ps1-macos/Sources/PS1/GameHUD.swift`:

```swift
import SwiftUI

/// The floating control cluster.
///
/// Every effect lives in ONE GlassEffectContainer so they batch into a single
/// pass rather than N independent ones — a glass effect samples the drawable
/// behind it every frame, over a 60fps Metal view, so the batching is what
/// keeps the cost bounded. The HUD is also hidden during actual play.
struct GameHUD: View {
    @Bindable var model: EmulatorViewModel
    let isVisible: Bool

    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 12) {
                button(model.isPaused ? "play.fill" : "pause.fill", "Play/Pause") {
                    model.isPaused.toggle()
                }
                .glassEffectID("playpause", in: glass)

                button("arrow.counterclockwise", "Reset") { model.reset() }
                    .glassEffectID("reset", in: glass)

                button("eject.fill", "Eject") { model.eject() }
                    .glassEffectID("eject", in: glass)

                button("arrow.up.left.and.arrow.down.right", "Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .glassEffectID("fullscreen", in: glass)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .allowsHitTesting(isVisible)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
```

- [ ] **Step 3: Write the empty state**

Create `ps1-macos/Sources/PS1/EmptyStateView.swift`:

```swift
import SwiftUI

/// First launch — the one screen every user sees.
struct EmptyStateView: View {
    @Bindable var model: EmulatorViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 46, weight: .thin))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.title2.weight(.semibold))

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                HStack(spacing: 12) {
                    if model.stage == .needsBIOS {
                        Button("Choose BIOS Folder…") { model.chooseBIOSFolder() }
                            .buttonStyle(.glassProminent)
                    } else {
                        Button("Open Disc…") { model.openDisc() }
                            .buttonStyle(.glassProminent)
                        Button("Change BIOS Folder…") { model.chooseBIOSFolder() }
                            .buttonStyle(.glass)
                    }
                }
                .padding(.top, 4)
            }
            .padding(36)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .frame(maxWidth: 460)
        }
    }

    private var title: String {
        model.stage == .needsBIOS ? "Choose a BIOS folder" : "Open a disc"
    }

    private var subtitle: String {
        model.stage == .needsBIOS
            ? "Point at the folder holding your SCPH-*.bin files. The right one is picked per disc — a US BIOS in front of a PAL disc stops at the region-lock screen."
            : "A .cue is preferred. A raw .bin works, but it cannot represent audio tracks, so CD-DA music will be silent."
    }
}
```

- [ ] **Step 4: Write the content view**

Create `ps1-macos/Sources/PS1/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @Bindable var model: EmulatorViewModel

    @State private var hudVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.stage == .playing, let runner = model.runner {
                MetalDisplayView(runner: runner)
                    .ignoresSafeArea()

                GameHUD(model: model, isVisible: hudVisible)
                    .padding(.bottom, 28)
            } else {
                EmptyStateView(model: model)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onContinuousHover { phase in
            if case .active = phase { showHUDThenHide() }
        }
        .onAppear { showHUDThenHide() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            model.keyDown(press.key.keyCode) ? .handled : .ignored
        }
        .onKeyPress(phases: .up) { press in
            model.keyUp(press.key.keyCode) ? .handled : .ignored
        }
        .alert("Could not load", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Opened as a raw .bin", isPresented: $model.showRawBinWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("A raw .bin is a single data track at LBA 0 and cannot represent audio tracks. If this game has CD-DA music, it will be silent. Open the .cue instead.")
        }
    }

    /// Auto-hides a couple of seconds into play, returns on mouse movement.
    private func showHUDThenHide() {
        hudVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            hudVisible = false
        }
    }
}
```

`press.key.keyCode` may not exist on `KeyPress` — SwiftUI exposes `KeyEquivalent`, not a virtual key code. If it does not compile, replace the two `onKeyPress` modifiers with an `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp])` in `EmulatorViewModel.init`, which gives a real `event.keyCode: UInt16` — that is what `InputMap.button(forKey:)` is written against.

- [ ] **Step 5: Write the app entry point**

Create `ps1-macos/Sources/PS1/PS1App.swift`:

```swift
import SwiftUI

@main
struct PS1App: App {
    @State private var model = EmulatorViewModel()

    var body: some Scene {
        Window("PlayStation", id: "main") {
            ContentView(model: model)
        }
        // Full-size content: the Metal view extends under the title bar so the
        // glass chrome floats OVER the game rather than sitting in an opaque
        // strip above it. Without this the material has nothing to refract.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Disc…") { model.openDisc() }
                    .keyboardShortcut("o")
                Button("Choose BIOS Folder…") { model.chooseBIOSFolder() }
            }
            CommandMenu("Machine") {
                Button(model.isPaused ? "Resume" : "Pause") { model.isPaused.toggle() }
                    .keyboardShortcut("p")
                Button("Reset") { model.reset() }
                    .keyboardShortcut("r")
                Button("Eject") { model.eject() }
                    .keyboardShortcut("e")
            }
        }
    }
}
```

- [ ] **Step 6: Verify it compiles and the tests still pass**

```bash
REPO=$(git rev-parse --show-toplevel)
swift build --package-path ps1-macos \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | grep -viE "^\[|search path" | tail -20
swift test --package-path ps1-macos \
  -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | tail -10
```
Expected: `Build complete!`, and all tests pass.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Sources/PS1/GameHUD.swift \
        ps1-macos/Sources/PS1/EmptyStateView.swift ps1-macos/Sources/PS1/ContentView.swift \
        ps1-macos/Sources/PS1/PS1App.swift
git commit -m "feat(macos): add the SwiftUI shell with Liquid Glass chrome"
```

---

## Task 14: Bundle assembly, `zig build macos`, and acceptance

**Files:**
- Create: `ps1-macos/build.sh`
- Create: `ps1-macos/Info.plist`
- Modify: `build.zig`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything.
- Produces: `zig build macos` → `zig-out/PS1.app`.

- [ ] **Step 1: Write Info.plist**

Create `ps1-macos/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PS1</string>
    <key>CFBundleIdentifier</key>
    <string>dev.zzssxx.ps1</string>
    <key>CFBundleName</key>
    <string>PlayStation</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMainNibFile</key>
    <string></string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
```

- [ ] **Step 2: Write build.sh**

Create `ps1-macos/build.sh`:

```bash
#!/bin/bash
# Assembles zig-out/PS1.app.
#
# The static library is linked by ABSOLUTE path rather than by an unsafeFlags
# entry in Package.swift: a relative path there resolves against the linker's
# working directory and breaks the moment the package is built from anywhere
# but its own root.
#
# There is no default.metallib — the offline `metal` compiler ships with Xcode
# and this project builds against Command Line Tools only, so the display
# shader is compiled at runtime from a string. See DisplayShader.swift.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO/ps1-macos"
APP="$REPO/zig-out/PS1.app"

if [ ! -f "$REPO/zig-out/lib/libps1core.a" ]; then
    echo "error: zig-out/lib/libps1core.a is missing — run 'zig build capi-lib' first" >&2
    exit 1
fi

echo "==> swift build -c release"
swift build -c release \
    --package-path "$PKG" \
    -Xlinker -L"$REPO/zig-out/lib" \
    -Xlinker -lps1core

BIN="$(swift build -c release --package-path "$PKG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PS1" "$APP/Contents/MacOS/PS1"
cp "$PKG/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature: unsigned SwiftUI apps are killed on launch by Gatekeeper on
# recent macOS. This is not notarization — that is explicitly out of scope.
codesign --force --sign - "$APP" 2>/dev/null || \
    echo "warning: ad-hoc codesign failed; the app may not launch" >&2

echo "==> built $APP"
```

Then: `chmod +x ps1-macos/build.sh`

- [ ] **Step 3: Add the `macos` step to build.zig**

Add at the top of `build.zig`:

```zig
const builtin = @import("builtin");
```

And after the `capi_lib_step` block:

```zig
    // The product. macOS-only: it must fail with a clear message on any other
    // target rather than producing a broken bundle.
    const macos_step = b.step("macos", "Build the native macOS app bundle (zig-out/PS1.app)");
    if (builtin.os.tag == .macos) {
        const app = b.addSystemCommand(&.{"ps1-macos/build.sh"});
        app.step.dependOn(&install_lib.step);
        macos_step.dependOn(&app.step);
    } else {
        macos_step.dependOn(&b.addFail(
            "`zig build macos` requires macOS (SwiftUI, Metal and AudioToolbox are host frameworks)",
        ).step);
    }
```

- [ ] **Step 4: Build the bundle**

```bash
zig build macos 2>&1 | tail -20
ls -la zig-out/PS1.app/Contents/MacOS/PS1
```
Expected: the bundle exists and the binary is present.

- [ ] **Step 5: Verify the whole test suite is still green**

```bash
zig build test 2>&1 | tail -10
REPO=$(git rev-parse --show-toplevel)
swift test --package-path ps1-macos -Xlinker -L"$REPO/zig-out/lib" -Xlinker -lps1core 2>&1 | tail -10
zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -20
```
Expected: Zig tests pass, Swift tests pass, **every trace-golden workload OK**.

A golden divergence at this point means core behaviour leaked in. Fix it — do not re-capture.

- [ ] **Step 6: Acceptance — three real games**

This is the spec's acceptance bar and it is a **manual** check; there is no automated substitute.

```bash
open zig-out/PS1.app
```

For each of Croc, Spyro and Silent Hill, from its `.cue` in `games/`:

- [ ] boots to gameplay
- [ ] runs at full speed (audio does not stutter, which is the audible tell — audio is the master clock, so a slow core starves the ring)
- [ ] has sound
- [ ] responds to a gamepad

If a game boots but stutters, check the emulator thread is not being starved before touching pacing constants. If a game shows a black screen with working audio, the CPU is parked in the BIOS unresolved-exception hang — that is a core bug, not a frontend one, and is out of this plan's scope.

- [ ] **Step 7: Document the frontend in CLAUDE.md**

The repository layout section lists four frontends and now there are six (`ps1-capi` and `ps1-macos`). Update:

- the intro paragraph's "driven by five frontends" count
- the **Repository layout** block, adding:
  ```
  ps1-capi/            C ABI static library (libps1core.a) — the contract ps1-macos links
  ps1-macos/           native SwiftUI app (SwiftPM + build.sh -> zig-out/PS1.app)
  ```
- the **Quick commands** table, adding `zig build capi-lib` and `zig build macos`
- a short **macOS app** subsection recording the two toolchain workarounds, because both will look like mistakes to a future reader: shaders are compiled at runtime because `xcrun metal` needs Xcode, and `libps1core.a` is repacked with `xcrun libtool` because Apple's `ld` rejects Zig's own archives.

- [ ] **Step 8: Commit**

```bash
git add ps1-macos/build.sh ps1-macos/Info.plist build.zig CLAUDE.md
git commit -m "build(macos): assemble PS1.app via zig build macos; document the frontend"
```

---

## Notes for the executor

**Two deviations from the spec, both forced by the toolchain and both verified during planning:**

1. **Spec §8 says `build.sh` compiles `Display.metal` with `xcrun metal` into `Resources/default.metallib`.** That compiler ships with Xcode, which is not installed. Shaders are compiled at runtime from a Swift string instead (`DisplayShader.swift`), verified working on this machine. There is no `.metal` file and no `.metallib` in the bundle.

2. **Spec §8 says the static library is `libps1core.a` from a Zig static-library artifact.** Zig's archiver emits members Apple's `ld` rejects outright. The library is emitted as one object and repacked with `xcrun libtool -static`; the resulting archive links as `-lps1core` exactly as the spec intends.

**One spec gap resolved:** `Disc.initFromCue` cannot fail — it silently falls back to a single data track on a cue it cannot parse. `PS1_ERR_BAD_CUE` is therefore decided in `ps1-capi` before the call, and `countCueFiles` moves from `ps1-golden` into `ps1-core/src/disc.zig` so one rule serves both callers.

**Out of scope, per spec §10** — do not add them: memory-card persistence, save states, a settings UI, the Metal rasterizer, upscaling/filtering, analog controller support, code signing and notarization beyond the ad-hoc signature the app needs to launch.
