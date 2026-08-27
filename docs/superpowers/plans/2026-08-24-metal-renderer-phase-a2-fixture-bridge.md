# Metal Renderer Phase A2 — The Fixture Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define the `.p1fx` fixture format and build both ends of it — a `ps1-golden stream-capture` mode that writes recorded GP0 command streams, and a Swift loader that reads them — so Phase B has a runnable gate before any Metal code exists.

**Architecture:** The record type is declared once in `ps1-capi/include/ps1.h` and imported by Swift through the existing `CPs1` module, so layout is a fact rather than a coincidence. A fixture is a header, a frame table, a records blob and a payload blob; payload offsets stay frame-relative so neither side rebases anything. A small synthetic fixture containing only memory-mover commands is committed to git and is the one fixture whose VRAM hashes Swift actually verifies; the PL ROM and Croc fixtures are generated, structurally checked, and banked for Phase B.

**Tech Stack:** Zig 0.16.0, `ps1-golden`, Swift 6 + swift-testing under `xcodebuild`, the `CPs1` module map, FNV-1a 64.

**Spec:** `docs/superpowers/specs/2026-08-24-metal-renderer-phase-a2-fixture-bridge-design.md` — read it first, especially § What A2 proves, and what it merely banks.

---

## Context

Phase A is landed (`d6ecd4f`, `c92447d`). `command.Command` is an `extern struct` pinned at 72 bytes by a `comptime` block, `command.replay(stream, vram, env)` exists, and `trace-golden -- stream-verify` proves the stream lossless across 23,449 frames of ten workloads with peaks of 3,715 records and 106,496 payload words per frame.

A2 adds no emulated behaviour. Every core gate is a **freeze check**: a moved golden or PeterLemon floor is a bug in this phase, not a baseline to update.

---

## Global Constraints

- **Zig 0.16.0 only.** `std.Io.Dir.cwd()`, `std.process.Init`, `std.ArrayList(...).empty` (unmanaged — `append`/`print` take the allocator as first argument), `addRunArtifact`, `b.addOptions`. Run `zig fmt` before every commit.
- **A2 changes no rendered output and no emulated behaviour.** `trace-golden -- verify`, `trace-golden -- stream-verify` and `test-roms-pl` must be green at **every** commit. There is no recapture in this phase.
- **`zig build test` must stay green at every commit.**
- **`ps1-core/src` is not modified at all in this phase.** The capture tool reads the core; it does not change it. If a task seems to need a core change, stop and ask.
- **`-D` options go BEFORE `--`.** `zig build trace-golden -Doptimize=ReleaseFast -- stream-capture`. Anything after `--` is an argument to `ps1-golden`.
- **Run `ps1-golden` and the ROM suites with `-Doptimize=ReleaseFast`** — ~25x faster, identical results.
- **`zig build test-roms-pl` prints a `failed command: …/test … --listen=-` line and still exits 0.** That is not a red gate — the suite's `debug.print` output confuses the build runner's `--listen` protocol, so zig re-runs the binary standalone. Redirect the log to a file and read `echo $?`.
- **Swift tests need `zig build capi-lib` and `zig build metallib` first**, then `ps1-macos/test.sh`. Both need full Xcode. `test.sh` passes no `-quiet` on purpose.
- **No file in `ps1-core/src` over ~600 lines** (not exercised here, but the house rule). New `ps1-golden` and Swift files stay under ~300.
- **Little-endian is asserted, never assumed**, on both sides.
- **Commit style:** one commit per task, directly on `master`, ending with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  ```

---

## Design decisions taken (do not relitigate mid-execution)

**1. The record type lives in `ps1.h`, not in a Swift struct.** Swift does not guarantee C-compatible layout for its own structs; a raw 72-byte read into a Swift struct would rely on something the language does not promise. This narrows Phase A's Decision 5 — it adds a *type* only. `ps1_take_frame_stream` and `gpu_sink = .dual` for `ps1-capi` stay in Phase B.

**2. FNV-1a 64, not `std.hash.Wyhash`.** Wyhash is a standard-library implementation that may change across Zig releases, so a fixture format pinned to it breaks silently on a toolchain upgrade — presenting as "Swift disagrees with Zig", the most confusing shape a bridge bug can take. FNV-1a is six lines in either language and frozen by definition. `state_hash.zig` keeps Wyhash; the two hashes serve different masters.

**3. Payload offsets stay frame-relative.** A `vram_write_data` record's `.x` indexes into its own frame's payload run, exactly as `command.replay` already assumes. Rebasing is arithmetic, and arithmetic done twice in two languages can disagree.

**4. The synthetic fixture is committed; everything else is generated.** It is a few kilobytes, needs neither BIOS nor disc, and is the only fixture whose hashes A2 verifies — so the executable gate runs on a fresh clone with zero prerequisites. The spec's "generated rather than committed" rule is about gigabytes of real-game frames.

**5. The capture tool picks its own PL cycle budgets.** It does not mirror `peterlemon_test.zig`'s, because the fixture needs only to be deterministic. The only thing duplicated between the two files is six file paths, so a budget divergence is harmless rather than silent.

---

## File Structure

- `ps1-capi/include/ps1.h` — **modified** (Task 1). `Ps1GpuVertex`, `Ps1GpuCommand`, `Ps1GpuCommandKind`, and three `_Static_assert`s.
- `ps1-golden/src/fixture.zig` — **new** (Tasks 2, 3). The FNV-1a hash, the header/frame-table types, `Writer`, and `parse` for the Zig round-trip test.
- `ps1-golden/src/fixture_test.zig` — **new** (Tasks 2, 3). Hash vectors and the format round trip.
- `ps1-golden/src/synthetic.zig` — **new** (Task 4). Builds the memory-mover fixture from a bare `Gpu`.
- `ps1-golden/src/main.zig` — **modified** (Tasks 4, 5, 6). `Mode.stream_capture`, the new flags, the EXE workload kind.
- `ps1-golden/src/golden.zig` — **modified** (Task 5). `Workload.source`.
- `ps1-macos/Sources/PS1/Fnv1a.swift` — **new** (Task 2).
- `ps1-macos/Sources/PS1/FixtureFile.swift` — **new** (Task 7).
- `ps1-macos/Sources/PS1/ShadowVram.swift` — **new** (Task 8).
- `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift` — **new** (Tasks 1, 2, 7, 8).
- `ps1-macos/test.sh` — **modified** (Task 7). A warning, not an exit.
- `ps1-core/tests/goldens/fixtures/synthetic-movers.p1fx` — **new, committed** (Task 4).
- `build.zig` — **modified** (Tasks 2, 9). The `fixture_test` binary; the `fixtures` step.
- `.gitignore` — **modified** (Task 4). An un-ignore for the committed fixture.
- `CLAUDE.md` — **modified** (Task 9).

---

## Task 1: The record type in `ps1.h`

Declare the fixture record once, in C, where both Swift and (later) the Metal shader can see it. Nothing reads it yet — this task exists alone so the ABI change is reviewable on its own.

**Files:**
- Modify: `ps1-capi/include/ps1.h`
- Create: `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Ps1GpuVertex`, `Ps1GpuCommand` (72 bytes), `Ps1GpuCommandKind` with 17 values, `PS1_GPU_COMMAND_STRIDE`, `PS1_GPU_KIND_COUNT`.

- [x] **Step 1: Add the types to `ps1.h`**

Insert immediately after the `Ps1Display` struct (`ps1.h:54-64`), before `ps1_run_frame`:

```c
/* ---- GP0 command stream records -------------------------------------------
 *
 * The mirror of ps1-core/src/gpu/command.zig's `Command`, which is an
 * `extern struct` pinned at 72 bytes by a comptime block in that file.
 *
 * Declared HERE rather than in Swift because Swift does not guarantee
 * C-compatible layout for its own structs: a raw read of a 72-byte record into
 * a Swift struct would rely on something the language does not promise. Coming
 * through this header makes the layout a fact.
 *
 * Phase A2 uses these to read .p1fx fixtures. Phase B adds the live handoff.
 */

typedef enum {
    PS1_GPU_DRAW_TRIANGLE = 0,
    PS1_GPU_DRAW_SHADED_TRIANGLE,
    PS1_GPU_DRAW_TEXTURED_TRIANGLE,
    PS1_GPU_DRAW_RECTANGLE,
    PS1_GPU_DRAW_TEXTURED_RECTANGLE,
    PS1_GPU_DRAW_LINE,
    PS1_GPU_DRAW_SHADED_LINE,
    PS1_GPU_SET_DRAW_ENV,
    PS1_GPU_LATCH_TEXPAGE,
    PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED,
    PS1_GPU_RESET_DRAW_ENV,
    PS1_GPU_FILL_RECT,
    PS1_GPU_COPY_RECT,
    PS1_GPU_VRAM_WRITE_SETUP,
    PS1_GPU_VRAM_WRITE_DATA,
    PS1_GPU_VRAM_WRITE_ABORT,
    PS1_GPU_VRAM_READ_SETUP
} Ps1GpuCommandKind;

#define PS1_GPU_KIND_COUNT      17
#define PS1_GPU_COMMAND_STRIDE  72

typedef struct {
    int16_t  x, y;
    uint8_t  u, v;
    uint16_t _pad;
    uint32_t color;   /* 24-bit BGR as it arrives on the wire; Gouraud only */
} Ps1GpuVertex;

typedef struct {
    uint8_t  kind;    /* Ps1GpuCommandKind */
    uint8_t  opcode;
    uint8_t  transparent;
    uint8_t  _pad0;
    uint32_t value;
    uint16_t clut;
    uint16_t tpage;
    int32_t  x, y, x2, y2, w, h;
    Ps1GpuVertex v[3];
} Ps1GpuCommand;

_Static_assert(sizeof(Ps1GpuVertex) == 12, "Ps1GpuVertex layout changed");
_Static_assert(sizeof(Ps1GpuCommand) == PS1_GPU_COMMAND_STRIDE,
               "Ps1GpuCommand layout changed — command.zig pins 72");
_Static_assert(PS1_GPU_VRAM_READ_SETUP + 1 == PS1_GPU_KIND_COUNT,
               "Ps1GpuCommandKind count drifted from command.Kind");
```

- [x] **Step 2: Write the failing Swift test**

Create `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`:

```swift
import Testing
import Foundation
import CPs1
@testable import PS1

// The layout guards. These are the reason the record is declared in C: a field
// added to command.Command without updating ps1.h shears every record in every
// fixture, and this is where that gets caught.
@Test func gpuCommandStrideIs72() {
    #expect(MemoryLayout<Ps1GpuCommand>.stride == 72)
    #expect(MemoryLayout<Ps1GpuCommand>.size == 72)
    #expect(MemoryLayout<Ps1GpuVertex>.stride == 12)
}

@Test func gpuCommandKindCountIs17() {
    #expect(Int(PS1_GPU_KIND_COUNT) == 17)
    #expect(PS1_GPU_VRAM_READ_SETUP.rawValue == 16)
}
```

- [x] **Step 3: Run it to verify it fails**

```bash
zig build capi-lib && ps1-macos/test.sh 2>&1 | tail -30
```

Expected before Step 1 is applied: a compile error, `cannot find 'Ps1GpuCommand' in scope`. If Step 1 is already applied, both tests pass — that is the real check, and it is what Step 4 confirms.

- [x] **Step 4: Run the gate**

```bash
zig build capi-lib
zig build
ps1-macos/test.sh 2>&1 | tail -30
```

Expected: `capi-lib` builds (the `_Static_assert`s fire at C compile time if the layout is wrong — but note nothing in the Zig build compiles this header, so the assertions are proved only by the Swift build), and the two new tests pass alongside the existing 68.

- [x] **Step 5: Commit**

```bash
git add ps1-capi/include/ps1.h ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift
git commit -F - <<'MSG'
feat(capi): declare the GP0 command record in ps1.h

The fixture format and, in Phase B, the live stream handoff both need
this record on the Apple side. It is declared in C rather than mirrored
in Swift because Swift does not guarantee C-compatible struct layout,
so a raw 72-byte read into a Swift struct would rely on something the
language does not promise.

Narrows Phase A's Decision 5: this adds a type, not the .dual sink
switch and not ps1_take_frame_stream.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 2: FNV-1a 64 on both sides, pinned by vectors

The hash convention is the single thing most likely to fail silently across the language boundary, so it gets its own task and its own literal test vectors on each side — neither verified only against the other.

**Files:**
- Create: `ps1-golden/src/fixture.zig`
- Create: `ps1-golden/src/fixture_test.zig`
- Create: `ps1-macos/Sources/PS1/Fnv1a.swift`
- Modify: `build.zig`, `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `fixture.fnv1a(bytes: []const u8) u64`, `fixture.hashVram(v: *const ps1.gpu.Vram) u64`, and Swift `Fnv1a.hash(_:)` / `Fnv1a.hash(vram:)`.

- [x] **Step 1: Write the failing Zig test**

Create `ps1-golden/src/fixture_test.zig`:

```zig
//! The .p1fx format and its hash, pinned independently on the Zig side.
//! ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift pins the SAME literal
//! vectors on the Swift side, so neither implementation is verified only
//! against the other — which is what a cross-language convention needs.

const std = @import("std");
const ps1 = @import("ps1_core");
const fixture = @import("fixture.zig");

test "fixture: FNV-1a 64 matches the published vectors" {
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fixture.fnv1a(""));
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fixture.fnv1a("a"));
    try std.testing.expectEqual(@as(u64, 0x85944171f73967e8), fixture.fnv1a("foobar"));
}

test "fixture: VRAM is hashed as little-endian u16, full 1024x512" {
    // Pins the BYTE ORDER, which the ASCII vectors above cannot.
    const px = [_]u16{ 0x0000, 0x7FFF, 0x8001, 0x1234 };
    try std.testing.expectEqual(
        @as(u64, 0x1b86415c70511fc8),
        fixture.fnv1a(std.mem.sliceAsBytes(px[0..])),
    );

    // Pins the EXTENT: the full VRAM, not the display window.
    const v = try std.testing.allocator.create(ps1.gpu.Vram);
    defer std.testing.allocator.destroy(v);
    v.* = .{};
    try std.testing.expectEqual(@as(u64, 0xa96777069d622325), fixture.hashVram(v));
}
```

- [x] **Step 2: Register the test binary in `build.zig`**

Immediately after the `stream_test` block (around `build.zig:201`):

```zig
    // The fixture format and its hash. Needs ps1_core for `gpu.Vram`; the
    // recording module is not required, but sharing it avoids a fourth core
    // module compile.
    const fixture_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-golden/src/fixture_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    fixture_test.root_module.addImport("ps1_core", record_core_mod);
    test_step.dependOn(&b.addRunArtifact(fixture_test).step);
```

Update the comment at `build.zig:133-134` from "fourteen of them" to "fifteen of them", both occurrences.

- [x] **Step 3: Run it to verify it fails**

```bash
zig build test -Dtest-filter="fixture:"
```

Expected: FAIL — `unable to load 'ps1-golden/src/fixture.zig'`, because the file does not exist yet.

- [x] **Step 4: Write the minimal `fixture.zig`**

Create `ps1-golden/src/fixture.zig`:

```zig
//! The .p1fx fixture format: a recorded GP0 command stream on disk, plus the
//! per-frame VRAM hash a consumer checks it against.
//!
//! Little-endian throughout, asserted rather than assumed.

const std = @import("std");
const ps1 = @import("ps1_core");

comptime {
    if (@import("builtin").cpu.arch.endian() != .little) {
        @compileError(".p1fx is little-endian; this target is not");
    }
}

/// FNV-1a 64.
///
/// Deliberately NOT `std.hash.Wyhash`, which state_hash.zig uses. Wyhash is a
/// standard-library implementation that may change across Zig releases, so a
/// FILE FORMAT pinned to it breaks silently on a toolchain upgrade — and the
/// failure presents as "Swift disagrees with Zig", the most confusing shape a
/// bridge bug can take. This is six lines in either language and frozen by
/// definition.
pub fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// The full 1024x512, as little-endian u16 in row-major order — not the
/// display window.
pub fn hashVram(v: *const ps1.gpu.Vram) u64 {
    return fnv1a(std.mem.sliceAsBytes(v.data[0..]));
}
```

- [x] **Step 5: Run the Zig tests to verify they pass**

```bash
zig build test -Dtest-filter="fixture:"
```

Expected: PASS, both tests.

- [x] **Step 6: Write the Swift side and its vectors**

Create `ps1-macos/Sources/PS1/Fnv1a.swift`:

```swift
import Foundation

/// FNV-1a 64, the .p1fx fixture hash.
///
/// Mirrors ps1-golden/src/fixture.zig. Deliberately not the Wyhash the trace
/// harness uses: that is a Zig-standard-library implementation which may change
/// across releases, and a file format pinned to it would break silently on a
/// toolchain upgrade. Both sides are pinned against the same literal vectors so
/// neither is verified only against the other.
enum Fnv1a {
    static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return h
    }

    static func hash(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { hash($0) }
    }

    /// VRAM as little-endian u16, row-major, full extent.
    static func hash(vram: [UInt16]) -> UInt64 {
        vram.withUnsafeBytes { hash($0) }
    }
}
```

Append to `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`:

```swift
@Test func fnv1aMatchesThePublishedVectors() {
    #expect(Fnv1a.hash(Data()) == 0xcbf2_9ce4_8422_2325)
    #expect(Fnv1a.hash(Data("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
    #expect(Fnv1a.hash(Data("foobar".utf8)) == 0x8594_4171_f739_67e8)
}

@Test func fnv1aHashesVramAsLittleEndianU16() {
    #expect(Fnv1a.hash(vram: [0x0000, 0x7FFF, 0x8001, 0x1234]) == 0x1b86_415c_7051_1fc8)

    let zeroVram = [UInt16](repeating: 0, count: 1024 * 512)
    #expect(Fnv1a.hash(vram: zeroVram) == 0xa967_7706_9d62_2325)
}
```

- [x] **Step 7: Run the full gate**

```bash
zig fmt build.zig ps1-golden/src
zig build test
zig build capi-lib
ps1-macos/test.sh 2>&1 | tail -30
```

Expected: `zig build test` green (15 binaries now), all four Swift tests passing. The two `0xa96777069d622325` results must agree — if they do not, the byte order or the extent differs between the two, and that is exactly the bug this task exists to catch.

- [x] **Step 8: Commit**

```bash
git add build.zig ps1-golden/src/fixture.zig ps1-golden/src/fixture_test.zig \
        ps1-macos/Sources/PS1/Fnv1a.swift ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift
git commit -F - <<'MSG'
feat(fixture): FNV-1a 64, pinned independently in Zig and Swift

The hash convention is the piece most likely to fail silently across the
language boundary, so both sides carry the same literal vectors rather
than being checked only against each other.

Not Wyhash: that is a std-library implementation which may change across
Zig releases, and a file format pinned to it breaks on a toolchain
upgrade, presenting as "Swift disagrees with Zig".

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 3: The format — writer, parser, round trip

**Files:**
- Modify: `ps1-golden/src/fixture.zig`, `ps1-golden/src/fixture_test.zig`

**Interfaces:**
- Consumes: `fixture.fnv1a`, `fixture.hashVram`.
- Produces:
  - `fixture.magic`, `fixture.version`, `fixture.record_stride`, `fixture.kind_count`, `fixture.header_bytes`, `fixture.frame_entry_bytes`
  - `fixture.FrameEntry` (`record_off`, `record_count`, `payload_off`, `payload_count`, `vram_hash`)
  - `fixture.Writer` with `.empty`, `addFrame(a, stream, vram_hash) !void`, `serialize(a) ![]u8`
  - `fixture.Parsed` with `frames`, `records`, `payload`, and `frameStream(i) ps1.gpu.command.Stream`
  - `fixture.parse(a, bytes) !Parsed`

- [x] **Step 1: Write the failing round-trip test**

Append to `ps1-golden/src/fixture_test.zig`:

```zig
const command = ps1.gpu.command;

test "fixture: two frames round-trip through serialize and parse" {
    const a = std.testing.allocator;

    var w = fixture.Writer.empty;
    defer w.deinit(a);

    // Frame 0: two records, no payload.
    const f0 = [_]command.Command{
        .{ .kind = .fill_rect, .value = 0x7C1F, .x = 4, .y = 8, .w = 16, .h = 2 },
        .{ .kind = .set_draw_env, .opcode = 0xE6, .value = 3 },
    };
    try w.addFrame(a, .{ .records = &f0, .payload = &.{}, .complete = true }, 0x1111_2222_3333_4444);

    // Frame 1: one record plus a payload run. The record's .x is an offset
    // into THIS FRAME's payload, which is the invariant the format keeps.
    const f1 = [_]command.Command{
        .{ .kind = .vram_write_data, .x = 0, .y = 3 },
    };
    const p1 = [_]u32{ 0xDEAD_BEEF, 0x0BAD_F00D, 0x1234_5678 };
    try w.addFrame(a, .{ .records = &f1, .payload = &p1, .complete = true }, 0x5555_6666_7777_8888);

    const bytes = try w.serialize(a);
    defer a.free(bytes);

    const p = try fixture.parse(a, bytes);
    defer p.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), p.frames.len);
    try std.testing.expectEqual(@as(u64, 0x1111_2222_3333_4444), p.frames[0].vram_hash);
    try std.testing.expectEqual(@as(u64, 0x5555_6666_7777_8888), p.frames[1].vram_hash);

    const s0 = p.frameStream(0);
    try std.testing.expectEqual(@as(usize, 2), s0.records.len);
    try std.testing.expectEqual(command.Kind.fill_rect, s0.records[0].kind);
    try std.testing.expectEqual(@as(u32, 0x7C1F), s0.records[0].value);
    try std.testing.expectEqual(@as(i32, 16), s0.records[0].w);
    try std.testing.expectEqual(@as(u8, 0xE6), s0.records[1].opcode);

    const s1 = p.frameStream(1);
    try std.testing.expectEqual(@as(usize, 3), s1.payload.len);
    try std.testing.expectEqual(@as(u32, 0x0BAD_F00D), s1.payload[1]);
    // Frame-relative: record .x is 0 even though frame 1's payload starts at
    // word 0 of the file only because frame 0 had none.
    try std.testing.expectEqual(@as(i32, 0), s1.records[0].x);
    try std.testing.expect(s1.complete);
}

test "fixture: parse rejects a bad magic and a stride mismatch" {
    const a = std.testing.allocator;

    var w = fixture.Writer.empty;
    defer w.deinit(a);
    try w.addFrame(a, .{ .records = &.{}, .payload = &.{}, .complete = true }, 0);
    const good = try w.serialize(a);
    defer a.free(good);

    const bad_magic = try a.dupe(u8, good);
    defer a.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, fixture.parse(a, bad_magic));

    const bad_stride = try a.dupe(u8, good);
    defer a.free(bad_stride);
    std.mem.writeInt(u32, bad_stride[12..16], 64, .little);
    try std.testing.expectError(error.StrideMismatch, fixture.parse(a, bad_stride));

    try std.testing.expectError(error.Truncated, fixture.parse(a, good[0..16]));
}
```

- [x] **Step 2: Run it to verify it fails**

```bash
zig build test -Dtest-filter="fixture:"
```

Expected: FAIL — `struct 'fixture' has no member named 'Writer'`.

- [x] **Step 3: Implement the format in `fixture.zig`**

Append to `ps1-golden/src/fixture.zig`:

```zig
const command = ps1.gpu.command;

pub const magic = "PS1FIXT\x00".*;
pub const version: u32 = 1;
pub const record_stride: u32 = @sizeOf(command.Command);
pub const kind_count: u32 = @typeInfo(command.Kind).@"enum".fields.len;
pub const header_bytes: usize = 48;
pub const frame_entry_bytes: usize = 24;

comptime {
    if (record_stride != 72) @compileError("Command stride changed; bump .p1fx version");
    if (kind_count != 17) @compileError("Kind count changed; bump .p1fx version and update ps1.h");
}

/// One frame's slice of the concatenated regions. `payload_off` is in WORDS.
pub const FrameEntry = struct {
    record_off: u32,
    record_count: u32,
    payload_off: u32,
    payload_count: u32,
    vram_hash: u64,
};

pub const ParseError = error{
    BadMagic,
    BadVersion,
    StrideMismatch,
    KindCountMismatch,
    Truncated,
    BadOffsets,
} || std.mem.Allocator.Error;

pub const Writer = struct {
    frames: std.ArrayList(FrameEntry),
    records: std.ArrayList(command.Command),
    payload: std.ArrayList(u32),

    pub const empty: Writer = .{
        .frames = .empty,
        .records = .empty,
        .payload = .empty,
    };

    pub fn deinit(self: *Writer, a: std.mem.Allocator) void {
        self.frames.deinit(a);
        self.records.deinit(a);
        self.payload.deinit(a);
    }

    /// Records are appended VERBATIM. A `vram_write_data` record's `.x` stays
    /// frame-relative and is never rebased — `command.replay` already reads it
    /// that way, and rebasing is arithmetic that two languages could disagree
    /// about.
    pub fn addFrame(self: *Writer, a: std.mem.Allocator, s: command.Stream, vram_hash: u64) !void {
        std.debug.assert(s.complete);
        try self.frames.append(a, .{
            .record_off = @intCast(self.records.items.len),
            .record_count = @intCast(s.records.len),
            .payload_off = @intCast(self.payload.items.len),
            .payload_count = @intCast(s.payload.len),
            .vram_hash = vram_hash,
        });
        try self.records.appendSlice(a, s.records);
        try self.payload.appendSlice(a, s.payload);
    }

    pub fn serialize(self: *const Writer, a: std.mem.Allocator) ![]u8 {
        const total = header_bytes +
            frame_entry_bytes * self.frames.items.len +
            @sizeOf(command.Command) * self.records.items.len +
            @sizeOf(u32) * self.payload.items.len;

        const out = try a.alloc(u8, total);
        errdefer a.free(out);

        @memcpy(out[0..8], &magic);
        std.mem.writeInt(u32, out[8..12], version, .little);
        std.mem.writeInt(u32, out[12..16], record_stride, .little);
        std.mem.writeInt(u32, out[16..20], kind_count, .little);
        std.mem.writeInt(u32, out[20..24], @intCast(self.frames.items.len), .little);
        std.mem.writeInt(u64, out[24..32], @intCast(self.records.items.len), .little);
        std.mem.writeInt(u64, out[32..40], @intCast(self.payload.items.len), .little);
        std.mem.writeInt(u64, out[40..48], 0, .little);

        var off: usize = header_bytes;
        for (self.frames.items) |f| {
            std.mem.writeInt(u32, out[off..][0..4], f.record_off, .little);
            std.mem.writeInt(u32, out[off..][4..8], f.record_count, .little);
            std.mem.writeInt(u32, out[off..][8..12], f.payload_off, .little);
            std.mem.writeInt(u32, out[off..][12..16], f.payload_count, .little);
            std.mem.writeInt(u64, out[off..][16..24], f.vram_hash, .little);
            off += frame_entry_bytes;
        }

        const rec_bytes = std.mem.sliceAsBytes(self.records.items);
        @memcpy(out[off .. off + rec_bytes.len], rec_bytes);
        off += rec_bytes.len;

        const pay_bytes = std.mem.sliceAsBytes(self.payload.items);
        @memcpy(out[off .. off + pay_bytes.len], pay_bytes);

        return out;
    }
};

pub const Parsed = struct {
    frames: []FrameEntry,
    records: []command.Command,
    payload: []u32,

    pub fn deinit(self: Parsed, a: std.mem.Allocator) void {
        a.free(self.frames);
        a.free(self.records);
        a.free(self.payload);
    }

    pub fn frameStream(self: Parsed, i: usize) command.Stream {
        const f = self.frames[i];
        return .{
            .records = self.records[f.record_off .. f.record_off + f.record_count],
            .payload = self.payload[f.payload_off .. f.payload_off + f.payload_count],
            .complete = true,
        };
    }
};

pub fn parse(a: std.mem.Allocator, bytes: []const u8) ParseError!Parsed {
    if (bytes.len < header_bytes) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &magic)) return error.BadMagic;
    if (std.mem.readInt(u32, bytes[8..12], .little) != version) return error.BadVersion;
    if (std.mem.readInt(u32, bytes[12..16], .little) != record_stride) return error.StrideMismatch;
    if (std.mem.readInt(u32, bytes[16..20], .little) != kind_count) return error.KindCountMismatch;

    const frame_count = std.mem.readInt(u32, bytes[20..24], .little);
    const total_records = std.mem.readInt(u64, bytes[24..32], .little);
    const total_payload = std.mem.readInt(u64, bytes[32..40], .little);

    const want = header_bytes +
        frame_entry_bytes * frame_count +
        @sizeOf(command.Command) * total_records +
        @sizeOf(u32) * total_payload;
    if (bytes.len != want) return error.Truncated;

    const frames = try a.alloc(FrameEntry, frame_count);
    errdefer a.free(frames);

    var off: usize = header_bytes;
    for (frames) |*f| {
        f.* = .{
            .record_off = std.mem.readInt(u32, bytes[off..][0..4], .little),
            .record_count = std.mem.readInt(u32, bytes[off..][4..8], .little),
            .payload_off = std.mem.readInt(u32, bytes[off..][8..12], .little),
            .payload_count = std.mem.readInt(u32, bytes[off..][12..16], .little),
            .vram_hash = std.mem.readInt(u64, bytes[off..][16..24], .little),
        };
        if (f.record_off + f.record_count > total_records) return error.BadOffsets;
        if (f.payload_off + f.payload_count > total_payload) return error.BadOffsets;
        off += frame_entry_bytes;
    }

    const records = try a.alloc(command.Command, @intCast(total_records));
    errdefer a.free(records);
    const rec_bytes = std.mem.sliceAsBytes(records);
    @memcpy(rec_bytes, bytes[off .. off + rec_bytes.len]);
    off += rec_bytes.len;

    const payload = try a.alloc(u32, @intCast(total_payload));
    errdefer a.free(payload);
    const pay_bytes = std.mem.sliceAsBytes(payload);
    @memcpy(pay_bytes, bytes[off .. off + pay_bytes.len]);

    return .{ .frames = frames, .records = records, .payload = payload };
}
```

- [x] **Step 4: Run the tests to verify they pass**

```bash
zig build test -Dtest-filter="fixture:"
```

Expected: PASS, all four `fixture:` tests.

- [x] **Step 5: Commit**

```bash
zig fmt ps1-golden/src
git add ps1-golden/src/fixture.zig ps1-golden/src/fixture_test.zig
git commit -F - <<'MSG'
feat(fixture): the .p1fx writer, parser and round-trip test

Header, frame table, records blob, payload blob. Payload offsets stay
frame-relative so a vram_write_data record's .x means what
command.replay already assumes and neither side rebases anything.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 4: The synthetic fixture and `stream-capture`

The one fixture whose hashes Swift actually verifies. It is built from a bare `Gpu` driven by real GP0 words — not from hand-built records — so it exercises the recorder path, and it is committed to git so the executable gate runs on a fresh clone.

**Files:**
- Create: `ps1-golden/src/synthetic.zig`
- Modify: `ps1-golden/src/main.zig`, `.gitignore`
- Create: `ps1-core/tests/goldens/fixtures/synthetic-movers.p1fx`

**Interfaces:**
- Consumes: `fixture.Writer`, `fixture.hashVram`.
- Produces: `synthetic.build(a) ![]u8`; `Mode.stream_capture`; `--out=<dir>`.

- [x] **Step 1: Write the generator**

Create `ps1-golden/src/synthetic.zig`:

```zig
//! The committed memory-mover fixture.
//!
//! Every command here is a VRAM move rather than a rasterization, which is what
//! makes it checkable from Swift without a rasterizer: ~120 lines of ShadowVram
//! reproduce it exactly, and its per-frame hashes are the only ones Phase A2
//! actually verifies.
//!
//! Driven by real GP0 words through a bare Gpu rather than by hand-built
//! records, so the recorder path is exercised too.

const std = @import("std");
const ps1 = @import("ps1_core");
const fixture = @import("fixture.zig");

const Gpu = ps1.gpu.Gpu;

const Case = struct {
    gpu: *Gpu,
    w: fixture.Writer = fixture.Writer.empty,
    a: std.mem.Allocator,

    fn gp0(self: *Case, word: u32) void {
        _ = self.gpu.writeGp0(word);
    }

    /// GP0 words queue into a 16-entry FIFO gated on cycle_debt while GP1
    /// executes immediately, so an undrained interleave silently reorders the
    /// stream. Always drain before a gp1() and before ending a frame.
    fn drain(self: *Case) void {
        _ = self.gpu.step(50_000_000);
    }

    fn gp1(self: *Case, word: u32) void {
        self.drain();
        self.gpu.writeGp1(word);
    }

    /// Ends a frame: drains, takes the stream, hashes VRAM, appends.
    fn endFrame(self: *Case) !void {
        self.drain();
        const s = self.gpu.sink.rec.takeFrame();
        std.debug.assert(s.complete);
        try self.w.addFrame(self.a, s, fixture.hashVram(&self.gpu.vram));
    }
};

/// A GP0(A0) upload of `w` x `h` at (x, y), payload filled deterministically.
/// `seed` shifts the pattern so successive uploads differ.
fn upload(c: *Case, x: u16, y: u16, w: u16, h: u16, seed: u16) void {
    c.gp0(0xA0000000);
    c.gp0(@as(u32, x) | (@as(u32, y) << 16));
    c.gp0(@as(u32, w) | (@as(u32, h) << 16));

    // The word count must come from the AXIS EXTENT, not the literal field:
    // `vram.zig`'s axisExtent reads w == 0 as the whole 1024-pixel axis and
    // h == 0 as the whole 512 rows. Taking the literal sends zero words for a
    // whole-axis upload, which leaves `write_active` true with the transfer
    // outstanding — and `gp0.zig`'s `if (vram.write_active)` then swallows the
    // NEXT frame's commands as payload.
    const ew: u32 = if (w == 0) 1024 else w;
    const eh: u32 = if (h == 0) 512 else h;

    const words = (ew * eh + 1) / 2;
    var i: u32 = 0;
    while (i < words) : (i += 1) {
        const lo: u16 = seed +% @as(u16, @truncate(i *% 2));
        const hi: u16 = seed +% @as(u16, @truncate(i *% 2 +% 1));
        c.gp0(@as(u32, lo) | (@as(u32, hi) << 16));
    }
}

/// Builds the fixture and returns its serialized bytes; caller frees.
pub fn build(a: std.mem.Allocator) ![]u8 {
    const gpu = try a.create(Gpu);
    defer a.destroy(gpu);
    gpu.* = Gpu.init();
    gpu.sink.rec.arm();

    var c = Case{ .gpu = gpu, .a = a };
    defer c.w.deinit(a);

    // Frame 0 — a plain upload, mask off. Establishes texels, some with bit 15
    // set (the pattern runs through 0x8000+), which later frames read back.
    c.gp0(0xE6000000);
    upload(&c, 0, 0, 32, 8, 0x7FF0);
    try c.endFrame();

    // Frame 1 — Fill Rectangle is UNMASKED even with E6 check+set on. Hardware
    // ignores E6 for fills, and this is the single write in the whole core that
    // does; a Swift mover that routes fills through the masked store fails here
    // and nowhere else.
    c.gp0(0xE6000003);
    // GP0(02)'s colour is BGR888 on the wire and `gp0.zig` runs it through
    // Color.getColor16 before it reaches the record, so the word is chosen for
    // what it DECODES to: r=0xF8>>3=0x1F, g=0x00, b=0x78>>3=0x0F, i.e. the
    // record's `.value` is ABGR1555 0x3C1F. Writing 0x02003C1F here instead —
    // the obvious reading — records 0x00E3.
    c.gp0(0x027800F8); // GP0(02) fill, colour 0x3C1F once decoded
    c.gp0(0x00000000); // at (0, 0)
    c.gp0(0x00080020); // 32 wide, 8 tall
    try c.endFrame();

    // Frame 2 — VRAM->VRAM copy, masked, overlapping FORWARD (dst below-right
    // of src, so the copy runs backwards).
    c.gp0(0xE6000002);
    c.gp0(0x80000000);
    c.gp0(0x00000000); // source (0, 0)
    c.gp0(0x00020004); // destination (4, 2)
    c.gp0(0x00080020); // 32 x 8
    try c.endFrame();

    // Frame 3 — the same copy the other way, mask off, so the backwards and
    // forwards branches of copyRect are both covered.
    c.gp0(0xE6000000);
    c.gp0(0x80000000);
    c.gp0(0x00020004); // source (4, 2)
    c.gp0(0x00000000); // destination (0, 0)
    c.gp0(0x00080020);
    try c.endFrame();

    // Frame 4 — w == 0 means the WHOLE AXIS, not an empty rectangle. One full
    // 1024-pixel row is 512 payload words, which keeps the committed file small.
    //
    // h == 0 is NOT exercised here, and deliberately so: it means the full 512
    // rows, i.e. 262,144 payload words and a ~1 MB committed fixture. The spec
    // asks for both, but the axisExtent rule is the same code for either axis
    // and one of them proves it. If you want the other covered, put it in a
    // GENERATED fixture, not this one.
    upload(&c, 0, 300, 0, 1, 0x1234);
    try c.endFrame();

    // Frame 5 — a payload aborted mid-transfer by GP1(01). The remaining words
    // of the declared 16x16 never arrive; the pixels already written stay.
    c.gp0(0xA0000000);
    c.gp0(0x00400040); // (64, 64)
    c.gp0(0x00100010); // 16 x 16 => 128 payload words
    var i: u32 = 0;
    while (i < 8) : (i += 1) c.gp0(0xAAAA5555);
    c.gp1(0x01000000); // abort; drains first, per Case.gp1
    c.gp0(0x02007FFF); // a fill afterwards proves the machine is still sane
    c.gp0(0x00600060);
    c.gp0(0x00040008);
    try c.endFrame();

    return c.w.serialize(a);
}
```

- [x] **Step 2: Add `stream-capture` to `main.zig`**

Add the import beside the existing ones:

```zig
const fixture = @import("fixture.zig");
const synthetic = @import("synthetic.zig");
```

Extend `Mode` and `Options`:

```zig
const Mode = enum { capture, verify, stream_verify, stream_capture };
```

```zig
const Options = struct {
    mode: Mode,
    filter: ?[]const u8 = null,
    instructions: u64 = default_instructions,
    interval: u64 = default_interval,
    bios_override: ?[]const u8 = null,
    out_dir: []const u8 = "zig-out/fixtures",
};
```

In `parseArgs`, extend the mode dispatch and add the flag:

```zig
    else if (std.mem.eql(u8, mode, "stream-capture"))
        .stream_capture
```

```zig
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            opts.out_dir = arg["--out=".len..];
```

Add to `usage`:

```
    \\  stream-capture  write .p1fx fixtures of the recorded command stream
    \\
    \\  --out=<dir>             fixture output directory (default zig-out/fixtures)
```

In `main`, **before** the workload loop, handle the synthetic fixture, which needs no workload at all:

```zig
    if (opts.mode == .stream_capture) {
        try std.Io.Dir.cwd().makePath(init.io, opts.out_dir);

        // The synthetic fixture is not a workload: no BIOS, no disc, no CPU.
        // It is also the only one committed to git, because it is the only one
        // whose hashes the Swift side can verify without a rasterizer.
        const bytes = try synthetic.build(a);
        const path = try std.fmt.allocPrint(a, "{s}/synthetic-movers.p1fx", .{opts.out_dir});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
        std.debug.print("  {s: <22} {d} bytes   WRITTEN\n", .{ "synthetic-movers", bytes.len });

        // The synthetic fixture is the ONLY thing stream-capture writes until
        // Task 5 adds runStreamCapture, so returning here keeps the mode out of
        // the workload loop — which would otherwise boot all ten workloads for
        // 600M instructions apiece and then hit the `unreachable` below.
        // Task 5 deletes this `return`.
        return;
    }
```

Adding `.stream_capture` to `Mode` also breaks the exhaustive `switch (opts.mode)`
that follows `runWorkload` (`main.zig:105`). Add the arm, or this task does not
compile:

```zig
            .stream_verify, .stream_capture => unreachable, // handled above
```

- [x] **Step 3: Generate it and check it is reproducible**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --out=zig-out/fixtures
cp zig-out/fixtures/synthetic-movers.p1fx /tmp/a.p1fx
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --out=zig-out/fixtures
cmp /tmp/a.p1fx zig-out/fixtures/synthetic-movers.p1fx && echo REPRODUCIBLE
```

Expected: `REPRODUCIBLE`, and a file of roughly 4-8 KB. If `cmp` differs, something non-deterministic leaked into the writer — check for a path, a timestamp or a hash-map iteration order.

- [x] **Step 4: Commit the fixture into the tree**

`.gitignore` has a blanket `/zig-out/`, so the committed copy lives with the other checked-in test data instead. Add an un-ignore beside the existing one for the reverb goldens:

```
!ps1-core/tests/goldens/fixtures/*.p1fx
```

Then:

```bash
mkdir -p ps1-core/tests/goldens/fixtures
cp zig-out/fixtures/synthetic-movers.p1fx ps1-core/tests/goldens/fixtures/
git add -f ps1-core/tests/goldens/fixtures/synthetic-movers.p1fx
```

- [x] **Step 5: Run the gate**

```bash
zig fmt ps1-golden/src
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify > /tmp/v.log 2>&1; echo $?
```

Expected: `zig build test` green; `verify` exit 0 with 10/10 OK. `main.zig` changed, so `verify` must be re-proven.

- [x] **Step 6: Commit**

```bash
git add .gitignore ps1-golden/src/main.zig ps1-golden/src/synthetic.zig
git commit -F - <<'MSG'
feat(fixture): stream-capture, and the committed synthetic fixture

Six frames of memory-mover commands only — fills, masked and unmasked
copies in both overlap directions, a whole-axis upload, and a payload
aborted mid-transfer by GP1(01). No rasterization, so Swift can check
its VRAM hashes with ~120 lines and no shader.

Driven by real GP0 words through a bare Gpu rather than hand-built
records, so the recorder path is exercised too. Committed, unlike the
generated fixtures: it needs no BIOS or disc, so the executable gate
runs on a fresh clone.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 5: EXE-sideload workloads and the PL fixtures

**Files:**
- Modify: `ps1-golden/src/golden.zig`, `ps1-golden/src/main.zig`

**Interfaces:**
- Consumes: `fixture.Writer`, `fixture.hashVram`, `Mode.stream_capture`.
- Produces: `golden.Source` (`.bios_only`, `.disc`, `.exe`), `Workload.source`, `--capture-from=<instr>`, `--frames=<n>`, `runStreamCapture`.

- [x] **Step 1: Give `Workload` a source**

In `ps1-golden/src/golden.zig`, replace the `Workload` struct:

```zig
/// Where a workload's software comes from. `exe` is a PS-EXE sideload, which
/// bypasses BIOS CD boot exactly as the ROM suites do — the PeterLemon ROMs
/// have no disc.
pub const Source = union(enum) {
    bios_only,
    disc: []const u8, // cue path
    exe: []const u8, // .exe path
};

pub const Workload = struct {
    key: []const u8,
    source: Source,
    bios_path: []const u8,
};
```

In `discover`, the `bios-only` entry becomes:

```zig
    try out.append(allocator, .{
        .key = try allocator.dupe(u8, "bios-only"),
        .source = .bios_only,
        .bios_path = bios_us,
    });
```

and each discovered disc's append changes `.cue_path = cue_path` to `.source = .{ .disc = cue_path }`. Nothing else in `discover` moves.

Then fix the read sites. `grep -n "cue_path" ps1-golden/src/*.zig` finds all of them; the only one outside `discover` is in `loadMachine`, handled in Step 2.

- [x] **Step 2: Teach `loadMachine` the EXE branch**

`loadMachine` today reads:

```zig
    if (wl.cue_path) |cue_path| {
        // …loads the cue text, the .bin, the optional .sbi, calls setDisc…
    }
```

Change only that `if` into a `switch`, leaving its disc body byte-for-byte as it is:

```zig
    switch (wl.source) {
        // A PS-EXE sideload attaches nothing here. It needs the BIOS booted far
        // enough to have set up its jump tables before loadExe can run, and
        // loadMachine does not own the Cpu — so the caller boots, then calls
        // sideloadExe below.
        .bios_only, .exe => {},
        .disc => |cue_path| {
            // …the existing disc body, moved in unchanged…
        },
    }
```

Then add the helper the capture path calls after booting:

```zig
/// PL ROMs boot the BIOS for 25M instructions to initialise its jump tables,
/// then sideload. Mirrors peterlemon_test.zig's preamble; the budget is OURS
/// and deliberately not shared with that file, since a fixture needs only to be
/// deterministic, not to match the test.
const pl_boot_instructions: u64 = 25_000_000;
const pl_run_instructions: u64 = 10_000_000;

fn sideloadExe(a: std.mem.Allocator, io: std.Io, cpu: *ps1.cpu.Cpu, exe_path: []const u8) !void {
    const exe = try std.Io.Dir.cwd().readFileAlloc(io, exe_path, a, .limited(10 << 20));
    defer a.free(exe);
    try cpu.loadExe(exe);
}
```

- [x] **Step 3: Add the six PL workloads**

In `golden.zig`, after the `bios-only` entry in `discover`:

```zig
    // The PeterLemon ROMs. Checked into test-roms/, so unlike the discs these
    // are present on every clone. Paths duplicated from peterlemon_test.zig;
    // the cycle budgets deliberately are NOT — see pl_boot_instructions.
    const pl_roms = [_]struct { key: []const u8, path: []const u8 }{
        .{ .key = "pl-hello-world", .path = "test-roms/peterlemon/hello-world/HelloWorld16BPP.exe" },
        .{ .key = "pl-cpu-add", .path = "test-roms/peterlemon/cpu/add/CPUADD.exe" },
        .{ .key = "pl-render-polygon", .path = "test-roms/peterlemon/gpu/render-polygon/RenderPolygon16BPP.exe" },
        .{ .key = "pl-render-line", .path = "test-roms/peterlemon/gpu/render-line/RenderLine16BPP.exe" },
        .{ .key = "pl-render-rectangle", .path = "test-roms/peterlemon/gpu/render-rectangle/RenderRectangle16BPP.exe" },
        .{ .key = "pl-render-texture-polygon", .path = "test-roms/peterlemon/gpu/render-texture-polygon/RenderTexturePolygon15BPP.exe" },
    };
    for (pl_roms) |r| {
        try out.append(allocator, .{
            .key = try allocator.dupe(u8, r.key),
            .source = .{ .exe = try allocator.dupe(u8, r.path) },
            .bios_path = bios_us,
        });
    }
```

**These workloads must be skipped by `capture`, `verify` and `stream-verify`.** They have no goldens and adding them would make the standing gate red. In `main`'s workload loop, immediately after the filter check:

```zig
        // EXE workloads exist only for fixture capture: they have no
        // machine-state goldens, and adding them to verify would report a
        // regression that is really a missing baseline.
        if (wl.source == .exe and opts.mode != .stream_capture) continue;
```

- [x] **Step 4: Add the capture flags and `runStreamCapture`**

Add to `Options`:

```zig
    capture_from: u64 = 0,
    frames: u64 = 0, // 0 = until the instruction budget runs out
```

Parse `--capture-from=` and `--frames=` beside the existing flags, and document both in `usage`.

Add, modelled on `runStreamVerify` (same button schedule, same vblank-edge detection):

```zig
/// Records frames into a .p1fx. Structurally `runStreamVerify` minus the
/// comparison and plus the writing: recording starts once the instruction
/// counter reaches `capture_from`, and stops after `frames` frames.
fn runStreamCapture(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_path: []const u8,
    opts: Options,
) !usize {
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);
    try loadMachine(a, io, wl, bios_path, bus);

    var budget = opts.instructions;
    if (wl.source == .exe) {
        var b: u64 = 0;
        while (b < pl_boot_instructions) : (b += 1) cpu.step();
        try sideloadExe(a, io, &cpu, wl.source.exe);
        budget = pl_run_instructions;
    }

    bus.gpu.sink.rec.arm();

    var w = fixture.Writer.empty;
    defer w.deinit(a);

    var prev_vblank = false;
    var press_idx: usize = 0;
    var i: u64 = 0;
    while (i < budget) : (i += 1) {
        if (i % press_period == 0) {
            bus.sio.setButtons(press_seq[press_idx]);
            press_idx = (press_idx + 1) % press_seq.len;
        }
        if (i % press_period == press_hold) bus.sio.setButtons(released);

        cpu.step();

        const vblank = bus.gpu.is_vblank;
        defer prev_vblank = vblank;
        if (!vblank or prev_vblank) continue;

        // The recorder is armed from the start so the stream stays in step,
        // but frames before the window are dropped rather than written.
        const s = bus.gpu.sink.rec.takeFrame();
        if (i < opts.capture_from) continue;
        if (!s.complete) return error.StreamOverflow;

        try w.addFrame(a, s, fixture.hashVram(&bus.gpu.vram));
        if (opts.frames != 0 and w.frames.items.len >= opts.frames) break;
    }

    const bytes = try w.serialize(a);
    const path = try std.fmt.allocPrint(a, "{s}/{s}.p1fx", .{ opts.out_dir, wl.key });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    std.debug.print("  {s: <22} {d} frames   {d} bytes   WRITTEN\n", .{
        wl.key, w.frames.items.len, bytes.len,
    });
    return w.frames.items.len;
}
```

Dispatch it in the workload loop beside the `stream_verify` branch. The
`.stream_capture => unreachable` arm on the `switch (opts.mode)` that follows
`runWorkload` is already there from Task 4; what must go now is Task 4's
**`return` at the end of the synthetic block** — `stream-capture` has to reach
the workload loop from here on. Leave the rest of that block, including the
`makePath`, exactly as it is.

- [x] **Step 5: Run the capture**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --filter=pl-
ls -la zig-out/fixtures/
```

Expected: six `pl-*.p1fx` files, each with a nonzero frame count. `pl-hello-world` should be small; `pl-render-polygon` the largest.

- [x] **Step 6: Prove the standing gate is untouched**

```bash
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify > /tmp/v.log 2>&1; echo $?; tail -12 /tmp/v.log
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify > /tmp/sv.log 2>&1; echo $?
zig build test-roms-pl -Doptimize=ReleaseFast > /tmp/pl.log 2>&1; echo $?
```

Expected: all exit 0; `verify` and `stream-verify` each report exactly the same **ten** workloads as before — the six `pl-*` entries must NOT appear, per Step 3's guard. If they do, the guard is missing and the gate will read as six new regressions.

- [x] **Step 7: Commit**

```bash
zig fmt ps1-golden/src
git add ps1-golden/src/golden.zig ps1-golden/src/main.zig
git commit -F - <<'MSG'
feat(fixture): EXE-sideload workloads and the PeterLemon fixtures

Workload.source becomes a union so a workload can be a PS-EXE sideload
rather than a disc. The six PL ROMs draw the pathological geometry no
commercial game emits, which is why they are in the fixture set.

They are skipped by capture/verify/stream-verify: they have no
machine-state goldens, and including them would report a missing
baseline as a regression.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 6: Measure the Croc window, then pin it

The spec deliberately refuses to name an instruction here. This task finds one.

**Files:**
- Modify: `ps1-golden/src/main.zig`

**Interfaces:**
- Consumes: `runStreamCapture`.
- Produces: `--probe`, and `croc_capture_from` / `croc_frames` pinned as constants.

- [x] **Step 1: Add a probe that measures instead of writing**

In `runStreamCapture`, immediately after `const s = bus.gpu.sink.rec.takeFrame();`:

```zig
        if (opts.probe) {
            // One line per frame: instruction, records, payload words. Piped
            // into sort/awk to find the window with the heaviest A0 traffic,
            // which is what puts FMV in the fixture.
            std.debug.print("PROBE {d} {d} {d}\n", .{ i, s.records.len, s.payload.len });
            continue;
        }
```

A probe run records nothing, so it must not reach the `serialize`/`writeFile` at
the end of `runStreamCapture` either — otherwise measuring Croc replaces a good
`croc-*.p1fx` with an empty 48-byte header. Guard the tail:

```zig
    if (opts.probe) return 0;
```

Add `probe: bool = false` to `Options` and parse a bare `--probe` flag.

- [x] **Step 2: Run the probe over Croc**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture \
    --filter=croc --probe > /tmp/croc-probe.log 2>&1
grep '^PROBE' /tmp/croc-probe.log | wc -l
```

Expected: roughly 2,450 `PROBE` lines (this session's `stream-verify` counted 2,453 frames for Croc at 600M instructions).

- [x] **Step 3: Pick the densest 200-frame window**

```bash
grep '^PROBE' /tmp/croc-probe.log \
  | awk '{i[NR]=$2; p[NR]=$4} END {
      best=0; bi=0;
      for (s=1; s+199<=NR; s++) { t=0; for (k=s;k<s+200;k++) t+=p[k];
        if (t>best) {best=t; bi=s} }
      printf "start_frame=%d start_instr=%d payload_words=%d\n", bi, i[bi], best }'
```

Record the printed `start_instr`. That is the number to pin — an instruction, not a frame ordinal, because the button schedule is instruction-indexed and therefore reproducible.

Sanity-check it: the window's total payload should be well above the run's average, since the point of choosing Croc is FMV. If the densest window's payload is indistinguishable from the median, say so rather than pinning it — it means Croc's FMV is outside the 600M-instruction budget and the budget needs raising with `--instructions`.

- [x] **Step 4: Pin it**

Add beside `pl_boot_instructions`, substituting the measured value for `<MEASURED>`:

```zig
/// The Croc fixture's window, measured with `stream-capture --probe --filter=croc`
/// on 2026-08-24 as the densest 200 frames of A0 payload in a 600M-instruction
/// run — i.e. where the FMV is. Pinned by INSTRUCTION rather than by frame
/// ordinal: ps1-golden's button schedule is instruction-indexed, so an
/// instruction is reproducible and a frame number is not.
const croc_capture_from: u64 = <MEASURED>;
const croc_frames: u64 = 200;
```

Apply them as defaults when the workload is Croc and the user gave no explicit window:

```zig
    var capture_from = opts.capture_from;
    var frame_limit = opts.frames;
    if (std.mem.indexOf(u8, wl.key, "croc") != null and capture_from == 0 and frame_limit == 0) {
        capture_from = croc_capture_from;
        frame_limit = croc_frames;
    }
```

and use `capture_from`/`frame_limit` in the loop in place of `opts.capture_from`/`opts.frames`.

- [x] **Step 5: Generate and verify reproducibility**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --filter=croc
cp zig-out/fixtures/croc-*.p1fx /tmp/croc-a.p1fx
zig build trace-golden -Doptimize=ReleaseFast -- stream-capture --filter=croc
cmp /tmp/croc-a.p1fx zig-out/fixtures/croc-*.p1fx && echo REPRODUCIBLE
```

Expected: `REPRODUCIBLE`, 200 frames, a file in the tens of megabytes.

- [x] **Step 6: Commit**

```bash
zig fmt ps1-golden/src
git add ps1-golden/src/main.zig
git commit -F - <<'MSG'
feat(fixture): pin the Croc window by measurement

--probe dumps per-frame record and payload counts; the pinned window is
the densest 200 frames of A0 payload in a 600M-instruction run, which is
where the FMV is. Croc is in the fixture set precisely because the PL
ROMs never produce a large A0 upload or a 24bpp one.

Pinned by instruction, not by frame ordinal: the button schedule is
instruction-indexed, so an instruction is reproducible.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 7: The Swift loader and the structural gate

**Files:**
- Create: `ps1-macos/Sources/PS1/FixtureFile.swift`
- Modify: `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`, `ps1-macos/test.sh`

**Interfaces:**
- Consumes: `Ps1GpuCommand`, `PS1_GPU_COMMAND_STRIDE`, `PS1_GPU_KIND_COUNT`.
- Produces: `FixtureFile` with `init(contentsOf:) throws`, `frames: [FixtureFile.Frame]`, `records(for:) -> UnsafeBufferPointer<Ps1GpuCommand>`, `payload(for:) -> UnsafeBufferPointer<UInt32>`; `FixtureFile.Error`; `FixtureFile.repoURL`, `FixtureFile.url(named:)`.

- [x] **Step 1: Write the failing Swift test**

Append to `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`:

```swift
@Test func loadsTheCommittedSyntheticFixture() throws {
    let f = try FixtureFile(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    #expect(f.frames.count == 6)

    // Frame 0 is an A0 upload: a setup record then a coalesced payload run.
    let r0 = f.records(for: 0)
    #expect(r0.count >= 2)
    #expect(r0.contains { $0.commandKind == PS1_GPU_VRAM_WRITE_SETUP })
    #expect(r0.contains { $0.commandKind == PS1_GPU_VRAM_WRITE_DATA })
    #expect(f.payload(for: 0).count == 128)   // 32 x 8 pixels / 2 per word

    // Frame 1's fill must be present with the colour the generator wrote.
    let fill = f.records(for: 1).first { $0.commandKind == PS1_GPU_FILL_RECT }
    #expect(fill != nil)
    #expect(fill?.value == 0x3C1F)
    #expect(fill?.w == 32)
    #expect(fill?.h == 8)

    // Frame 5 aborts mid-payload.
    #expect(f.records(for: 5).contains { $0.commandKind == PS1_GPU_VRAM_WRITE_ABORT })
}

@Test func structurallyChecksTheGeneratedFixtures() throws {
    // Generated, not committed: absent on a fresh clone, and the Croc one is
    // absent on any machine without games/. Skipping is correct; failing is not.
    for name in ["pl-hello-world", "pl-render-polygon", "pl-render-texture-polygon"] {
        let url = FixtureFile.url(named: name)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }

        let f = try FixtureFile(contentsOf: url)
        #expect(f.frames.count > 0)
        for i in 0..<f.frames.count {
            let recs = f.records(for: i)
            for r in recs {
                #expect(r.kind < UInt8(PS1_GPU_KIND_COUNT))
            }
            // A vram_write_data record's .x is FRAME-relative and must address
            // inside this frame's own payload run.
            let payloadCount = f.payload(for: i).count
            for r in recs where r.commandKind == PS1_GPU_VRAM_WRITE_DATA {
                #expect(r.x >= 0)
                #expect(Int(r.x) + Int(r.y) <= payloadCount)
            }
        }
    }
}

@Test func rejectsABadMagic() throws {
    var bytes = try Data(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    bytes[0] = 0x58
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bad.p1fx")
    try bytes.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    #expect(throws: FixtureFile.Error.badMagic) {
        _ = try FixtureFile(contentsOf: tmp)
    }
}
```

- [x] **Step 2: Run it to verify it fails**

```bash
zig build capi-lib && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'FixtureFile' in scope`.

- [x] **Step 3: Write `FixtureFile.swift`**

Create `ps1-macos/Sources/PS1/FixtureFile.swift`:

```swift
import Foundation
import CPs1

/// A .p1fx fixture: a recorded GP0 command stream plus a per-frame VRAM hash.
///
/// The format is defined in ps1-golden/src/fixture.zig and documented in
/// docs/superpowers/specs/2026-08-24-metal-renderer-phase-a2-fixture-bridge-design.md.
///
/// The record type comes from ps1.h via CPs1 and is NOT redeclared here: Swift
/// does not guarantee C-compatible layout for its own structs, so a raw read
/// into a Swift struct would rely on something the language does not promise.
struct FixtureFile {
    enum Error: Swift.Error, Equatable {
        case badMagic
        case badVersion(UInt32)
        case strideMismatch(UInt32)
        case kindCountMismatch(UInt32)
        case truncated
        case badOffsets
    }

    struct Frame {
        let recordOff: Int
        let recordCount: Int
        let payloadOff: Int
        let payloadCount: Int
        let vramHash: UInt64
    }

    private static let magic = Data("PS1FIXT\0".utf8)
    private static let headerBytes = 48
    private static let frameEntryBytes = 24

    let frames: [Frame]
    private let bytes: Data
    private let recordsBase: Int
    private let payloadBase: Int

    init(contentsOf url: URL) throws {
        try self.init(Data(contentsOf: url))
    }

    init(_ data: Data) throws {
        guard data.count >= Self.headerBytes else { throw Error.truncated }
        guard data.prefix(8) == Self.magic else { throw Error.badMagic }

        let version = data.u32(at: 8)
        guard version == 1 else { throw Error.badVersion(version) }

        // The two layout guards. A field added to command.Command without
        // updating ps1.h shears every record in the file; a Kind added without
        // a mirror in ps1.h surfaces as an unrecognised record in Phase B.
        // Both are caught here instead.
        let stride = data.u32(at: 12)
        guard stride == UInt32(PS1_GPU_COMMAND_STRIDE) else { throw Error.strideMismatch(stride) }
        let kinds = data.u32(at: 16)
        guard kinds == UInt32(PS1_GPU_KIND_COUNT) else { throw Error.kindCountMismatch(kinds) }

        let frameCount = Int(data.u32(at: 20))
        let totalRecords = Int(data.u64(at: 24))
        let totalPayload = Int(data.u64(at: 32))

        let recordsBase = Self.headerBytes + Self.frameEntryBytes * frameCount
        let payloadBase = recordsBase + Int(PS1_GPU_COMMAND_STRIDE) * totalRecords
        guard data.count == payloadBase + 4 * totalPayload else { throw Error.truncated }

        var frames: [Frame] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let o = Self.headerBytes + Self.frameEntryBytes * i
            let f = Frame(
                recordOff: Int(data.u32(at: o)),
                recordCount: Int(data.u32(at: o + 4)),
                payloadOff: Int(data.u32(at: o + 8)),
                payloadCount: Int(data.u32(at: o + 12)),
                vramHash: data.u64(at: o + 16))
            guard f.recordOff + f.recordCount <= totalRecords,
                  f.payloadOff + f.payloadCount <= totalPayload else { throw Error.badOffsets }
            frames.append(f)
        }

        self.bytes = data
        self.frames = frames
        self.recordsBase = recordsBase
        self.payloadBase = payloadBase
    }

    /// Records for one frame. The buffer points into this file's retained Data
    /// and is valid for the lifetime of the FixtureFile.
    func records(for frame: Int) -> UnsafeBufferPointer<Ps1GpuCommand> {
        let f = frames[frame]
        let off = recordsBase + Int(PS1_GPU_COMMAND_STRIDE) * f.recordOff
        return bytes.withUnsafeBytes { raw in
            UnsafeBufferPointer(
                start: raw.baseAddress!.advanced(by: off).assumingMemoryBound(to: Ps1GpuCommand.self),
                count: f.recordCount)
        }
    }

    /// This frame's payload run. Record `.x` offsets are relative to THIS
    /// slice, never to the whole file — the format keeps them frame-relative so
    /// neither side rebases anything.
    func payload(for frame: Int) -> UnsafeBufferPointer<UInt32> {
        let f = frames[frame]
        let off = payloadBase + 4 * f.payloadOff
        return bytes.withUnsafeBytes { raw in
            UnsafeBufferPointer(
                start: raw.baseAddress!.advanced(by: off).assumingMemoryBound(to: UInt32.self),
                count: f.payloadCount)
        }
    }

    // MARK: - Locating fixtures

    /// Fixtures are build artifacts, not bundle resources — the app deliberately
    /// has no copy-resources phase (see the metallib note in CLAUDE.md). The
    /// repo root is derived from this file's own path at compile time.
    static var repoURL: URL {
        URL(fileURLWithPath: #filePath)             // …/ps1-macos/Sources/PS1/FixtureFile.swift
            .deletingLastPathComponent()            // …/PS1
            .deletingLastPathComponent()            // …/Sources
            .deletingLastPathComponent()            // …/ps1-macos
            .deletingLastPathComponent()            // repo root
    }

    /// The committed synthetic fixture lives with the other checked-in test
    /// data; everything else is generated into zig-out/fixtures/.
    static func url(named name: String) -> URL {
        let committed = repoURL
            .appendingPathComponent("ps1-core/tests/goldens/fixtures")
            .appendingPathComponent("\(name).p1fx")
        if FileManager.default.fileExists(atPath: committed.path) { return committed }
        return repoURL
            .appendingPathComponent("zig-out/fixtures")
            .appendingPathComponent("\(name).p1fx")
    }
}

extension Ps1GpuCommand {
    /// `kind` is a byte on the wire; the C enum imports into Swift as a
    /// RawRepresentable struct over UInt32. Going through this one accessor
    /// keeps every comparison in the app spelled the same way, rather than
    /// some sites casting the byte up and others casting the enum down.
    var commandKind: Ps1GpuCommandKind {
        Ps1GpuCommandKind(rawValue: UInt32(kind))
    }
}

private extension Data {
    func u32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func u64(at i: Int) -> UInt64 {
        UInt64(u32(at: i)) | UInt64(u32(at: i + 4)) << 32
    }
}
```

- [x] **Step 4: Run the tests to verify they pass**

```bash
zig build capi-lib && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: PASS. `loadsTheCommittedSyntheticFixture` runs off the committed file, so it passes with no generation step; `structurallyChecksTheGeneratedFixtures` skips any fixture not present.

- [x] **Step 5: Warn — do not exit — in `test.sh`**

After the two existing prerequisite checks in `ps1-macos/test.sh`:

```bash
# Unlike the two above this is a WARNING, not an error. The committed synthetic
# fixture is enough to run the executable half of the bridge gate, and the
# generated fixtures legitimately cannot exist on a machine without games/.
if [ ! -d "$REPO/zig-out/fixtures" ]; then
    echo "note: zig-out/fixtures is missing — the generated-fixture checks will skip." >&2
    echo "      run 'zig build fixtures' to produce them." >&2
fi
```

- [x] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/FixtureFile.swift \
        ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift ps1-macos/test.sh
git commit -F - <<'MSG'
feat(macos): read .p1fx fixtures from Swift

The loader plus the structural half of the bridge gate. Records come
from ps1.h through CPs1 and are read in place, so the 72-byte stride and
the 17-kind count are checked on load rather than shearing silently.

Fixtures are build artifacts, not bundle resources: the repo root comes
from #filePath, and an absent generated fixture SKIPS. A machine without
games/ cannot have the Croc one, and that is not a failure.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 8: `ShadowVram` and the executable gate

The half of A2 that actually executes: Swift applies the synthetic fixture's memory-mover commands and must reproduce the recorded VRAM hashes exactly.

**Files:**
- Create: `ps1-macos/Sources/PS1/ShadowVram.swift`
- Modify: `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`

**Interfaces:**
- Consumes: `FixtureFile`, `Fnv1a`, `Ps1GpuCommand`.
- Produces: `ShadowVram` with `data: [UInt16]`, `apply(_ cmd:payload:)`, `hash`.

- [x] **Step 1: Write the failing test**

Append to `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`:

```swift
// The executable half of the bridge gate. Every command in this fixture is a
// memory move rather than a rasterization, which is why Swift can check it at
// all: reproducing a rasterized frame is Phase B's job, and writing a second
// rasterizer is what Phase A's design was built to prevent.
@Test func replaysTheSyntheticFixtureAndMatchesEveryHash() throws {
    let f = try FixtureFile(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    var shadow = ShadowVram()

    for i in 0..<f.frames.count {
        let payload = f.payload(for: i)
        for cmd in f.records(for: i) {
            shadow.apply(cmd, payload: payload)
        }
        #expect(shadow.hash == f.frames[i].vramHash,
                "frame \(i) diverged")
    }
}

@Test func fillRectangleIgnoresTheMaskBits() {
    // The one write in the whole core that ignores GP0(E6). Frame 1 of the
    // synthetic fixture depends on it, but pin it directly too — if a shadow
    // routed fills through the masked store, only this would say why.
    var shadow = ShadowVram()
    shadow.data[0] = 0x8000                    // bit 15 set: the check bit would skip it
    shadow.maskCheck = true
    shadow.maskSet = true

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.value = 0x1234
    fill.w = 1
    fill.h = 1
    shadow.apply(fill, payload: UnsafeBufferPointer(start: nil, count: 0))

    #expect(shadow.data[0] == 0x1234)          // written, and bit 15 NOT or'd in
}
```

- [x] **Step 2: Run it to verify it fails**

```bash
ps1-macos/test.sh 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'ShadowVram' in scope`.

- [x] **Step 3: Write `ShadowVram.swift`**

Create `ps1-macos/Sources/PS1/ShadowVram.swift`:

```swift
import Foundation
import CPs1

/// A 1024x512 VRAM plus the GP0 commands that move memory around inside it:
/// Fill Rectangle, VRAM->VRAM copy, and the CPU->VRAM transfer FSM.
///
/// This mirrors ps1-core/src/gpu/vram.zig:51-198 and is a SECOND TRANSCRIPTION,
/// accepted knowingly and bounded deliberately: it duplicates the memory movers
/// only, never the rasterizer. Reproducing a rasterized frame in Swift is Phase
/// B's job, and writing a second rasterizer is exactly what Phase A's one-
/// interpreter design was built to prevent.
///
/// It is also not scaffolding — these are Phase B's 02/80/A0 passes, written a
/// phase early with a hash gate on them.
struct ShadowVram {
    static let width = 1024
    static let height = 512

    var data = [UInt16](repeating: 0, count: ShadowVram.width * ShadowVram.height)

    /// GP0(E6) bit 0: OR bit 15 into every pixel written.
    var maskSet = false
    /// GP0(E6) bit 1: skip pixels whose existing bit 15 is set.
    var maskCheck = false

    // CPU -> VRAM transfer state
    private var writeActive = false
    private var writeX = 0, writeY = 0, writeW = 0, writeH = 0
    private var currX = 0, currY = 0
    private var remaining = 0

    var hash: UInt64 { Fnv1a.hash(vram: data) }

    private static func index(_ x: Int, _ y: Int) -> Int { y * width + x }

    /// A width or height of 0 means the WHOLE AXIS, not an empty rectangle.
    private static func axisExtent(_ size: Int, _ full: Int) -> Int {
        size == 0 ? full : size
    }

    private mutating func maskedWrite(_ x: Int, _ y: Int, _ value: UInt16) {
        let i = Self.index(x, y)
        if maskCheck && (data[i] & 0x8000) != 0 { return }
        data[i] = value | (maskSet ? 0x8000 : 0)
    }

    mutating func apply(_ cmd: Ps1GpuCommand, payload: UnsafeBufferPointer<UInt32>) {
        switch cmd.commandKind {
        case PS1_GPU_SET_DRAW_ENV:
            // Only E6 moves the mask bits; the rest of the drawing environment
            // is rasterizer state this shadow does not model.
            if cmd.opcode == 0xE6 {
                maskSet = (cmd.value & 1) != 0
                maskCheck = (cmd.value & 2) != 0
            }

        case PS1_GPU_RESET_DRAW_ENV:
            maskSet = false
            maskCheck = false

        case PS1_GPU_FILL_RECT:
            fill(Int(cmd.x), Int(cmd.y), Int(cmd.w), Int(cmd.h), UInt16(truncatingIfNeeded: cmd.value))

        case PS1_GPU_COPY_RECT:
            copy(Int(cmd.x), Int(cmd.y), Int(cmd.x2), Int(cmd.y2), Int(cmd.w), Int(cmd.h))

        case PS1_GPU_VRAM_WRITE_SETUP:
            setupWrite(Int(cmd.x), Int(cmd.y), Int(cmd.w), Int(cmd.h))

        case PS1_GPU_VRAM_WRITE_DATA:
            let off = Int(cmd.x), len = Int(cmd.y)
            for k in off..<(off + len) { writeData(payload[k]) }

        case PS1_GPU_VRAM_WRITE_ABORT:
            writeActive = false

        default:
            // Rasterizing and read-setup records are not modelled. A fixture
            // containing them cannot be hash-checked here, which is why only
            // the synthetic one is.
            break
        }
    }

    /// GP0(02). DELIBERATELY unmasked — hardware ignores GP0(E6) for fills, and
    /// this is the only VRAM write in the core that does. It also CLIPS rather
    /// than wrapping, unlike copy.
    private mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt16) {
        guard h > 0, w > 0 else { return }
        for yy in 0..<h {
            for xx in 0..<w {
                let px = x + xx, py = y + yy
                if px >= 0 && px < Self.width && py >= 0 && py < Self.height {
                    data[Self.index(px, py)] = color
                }
            }
        }
    }

    /// GP0(80). Masked, and WRAPS on both axes rather than clipping. The
    /// direction matters when source and destination overlap.
    private mutating func copy(_ sx: Int, _ sy: Int, _ dx: Int, _ dy: Int, _ w: Int, _ h: Int) {
        let width = Self.axisExtent(w, Self.width)
        let height = Self.axisExtent(h, Self.height)
        let backwards = (dy > sy) || (dy == sy && dx > sx)

        let ys = backwards ? Array((0..<height).reversed()) : Array(0..<height)
        let xs = backwards ? Array((0..<width).reversed()) : Array(0..<width)

        for yy in ys {
            for xx in xs {
                let srcX = (sx + xx) & 0x3FF, srcY = (sy + yy) & 0x1FF
                let dstX = (dx + xx) & 0x3FF, dstY = (dy + yy) & 0x1FF
                maskedWrite(dstX, dstY, data[Self.index(srcX, srcY)])
            }
        }
    }

    private mutating func setupWrite(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        writeW = Self.axisExtent(w, Self.width)
        writeH = Self.axisExtent(h, Self.height)
        writeX = x
        writeY = y
        currX = 0
        currY = 0
        remaining = (writeW * writeH + 1) / 2
        writeActive = remaining > 0
    }

    private mutating func writePixel(_ pix: UInt16) {
        let px = writeX + currX, py = writeY + currY
        if px < Self.width && py < Self.height {
            maskedWrite(px, py, pix)
        }
        currX += 1
        if currX >= writeW {
            currX = 0
            currY += 1
        }
    }

    /// One 32-bit word is two pixels. The second is dropped when it would fall
    /// past the end of an odd-sized transfer.
    private mutating func writeData(_ value: UInt32) {
        guard writeActive else { return }
        writePixel(UInt16(truncatingIfNeeded: value))
        if (currY * writeW + currX) < (writeW * writeH) {
            writePixel(UInt16(truncatingIfNeeded: value >> 16))
        }
        if remaining > 0 { remaining -= 1 }
        if remaining == 0 { writeActive = false }
    }
}
```

- [x] **Step 4: Run the tests to verify they pass**

```bash
ps1-macos/test.sh 2>&1 | tail -30
```

Expected: PASS, both new tests. A failure at a specific frame index names the command class that diverged — frame 1 is the unmasked fill, frames 2-3 are the two copy directions, frame 4 is the whole-axis extent, frame 5 is the abort.

- [x] **Step 5: Commit**

```bash
git add ps1-macos/Sources/PS1/ShadowVram.swift ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift
git commit -F - <<'MSG'
feat(macos): ShadowVram, and the executable half of the bridge gate

Swift applies the synthetic fixture's memory-mover commands and matches
every recorded VRAM hash, which proves the byte format, the field decode
and the hash convention end to end.

A second transcription, accepted knowingly and bounded deliberately: the
memory movers only, never the rasterizer. These are also Phase B's
02/80/A0 passes, written a phase early with a hash gate on them.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 9: The `fixtures` build step, docs, and the closing gate

**Files:**
- Modify: `build.zig`, `CLAUDE.md`

- [x] **Step 1: Add `zig build fixtures`**

After the `golden_step` block in `build.zig`:

```zig
    // Regenerates the .p1fx fixtures the Swift bridge tests read. Separate from
    // `trace-golden` because it is a producer, not a gate, and because
    // ps1-macos/test.sh names it in its prerequisite warning.
    const fixtures_run = b.addRunArtifact(golden_exe);
    fixtures_run.step.dependOn(b.getInstallStep());
    fixtures_run.addArgs(&.{"stream-capture"});
    const fixtures_step = b.step("fixtures", "Write .p1fx command-stream fixtures to zig-out/fixtures");
    fixtures_step.dependOn(&fixtures_run.step);
```

- [x] **Step 2: Update `CLAUDE.md`**

Add a quick-commands row after the `stream-verify` one:

```
| `zig build fixtures` | Writes `.p1fx` command-stream fixtures to `zig-out/fixtures/` — the six PeterLemon ROMs plus a measured Croc window — for the Swift bridge tests. Run it `-Doptimize=ReleaseFast`. The synthetic memory-mover fixture is committed at `ps1-core/tests/goldens/fixtures/` instead, so the executable half of that gate needs no generation step. |
```

Update the `zig build test` row's count from **14** to **15** test binaries, and the `build.zig:133-134` comment likewise if Task 2 missed it.

Add to the repository layout, under `ps1-golden/`:

```
                     fixture.zig (.p1fx format + FNV-1a 64), synthetic.zig
                     (the committed memory-mover fixture), fixture_test.zig
```

and under `ps1-macos/`, note `FixtureFile.swift`, `ShadowVram.swift`, `Fnv1a.swift`.

Add a subsection after the GP0-sink one:

> **The fixture bridge is how Metal gets tested at all.** Metal runs only under
> `ps1-macos/test.sh`; the ROM suites run only in Zig. `zig build fixtures`
> writes `.p1fx` files — a header, a frame table, 72-byte records and a payload
> blob — that Swift reads through `FixtureFile`. **The record type is declared
> in `ps1-capi/include/ps1.h`, not mirrored in Swift**, because Swift does not
> guarantee C-compatible struct layout; the header's `record_stride` and
> `kind_count` are checked on load so a field or a `Kind` added on the Zig side
> fails loudly instead of shearing every record. The hash is **FNV-1a 64, not
> the trace harness's Wyhash** — Wyhash is a std-library implementation that can
> change across Zig releases, and a file format pinned to it would break on a
> toolchain upgrade while presenting as "Swift disagrees with Zig". Payload
> offsets are **frame-relative**: a `vram_write_data` record's `.x` indexes its
> own frame's run, exactly as `command.replay` reads it. Only the committed
> synthetic fixture has its VRAM hashes verified — `ShadowVram` models the
> memory movers, never the rasterizer — so the PL and Croc fixtures are
> structurally checked and otherwise banked for Phase B.

- [x] **Step 3: Run the complete closing gate**

```bash
zig fmt build.zig ps1-golden/src
zig build
zig build test
zig build capi-lib
zig build metallib
zig build test-roms-pl -Doptimize=ReleaseFast > /tmp/pl.log 2>&1; echo "PL=$?"
zig build test-roms-ja -Doptimize=ReleaseFast > /tmp/ja.log 2>&1; echo "JA=$?"   # 12/17, the same five
zig build trace-golden -Doptimize=ReleaseFast -- verify > /tmp/v.log 2>&1; echo "V=$?"
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify > /tmp/sv.log 2>&1; echo "SV=$?"
zig build fixtures -Doptimize=ReleaseFast
ps1-macos/test.sh 2>&1 | tail -30
```

Expected: everything green except `test-roms-ja`, which exits 1 at its documented 12/17 with the same five failures (`cdrom/getloc`, `cdrom/timing`, `mdec/4bit`, `mdec/8bit`, `mdec/step-by-step-log`). `verify` and `stream-verify` must each still report exactly **ten** workloads — the `pl-*` entries are capture-only.

- [x] **Step 4: Commit**

```bash
git add build.zig CLAUDE.md
git commit -F - <<'MSG'
docs: record the .p1fx fixture bridge, and add `zig build fixtures`

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Verification (the phase's exit criteria)

| Check | Command | Expected |
|---|---|---|
| Unit tests | `zig build test` | green, 15 binaries incl. `fixture:` |
| No core behaviour change | `trace-golden -- verify` | 10/10 OK, unchanged goldens |
| Stream still lossless | `trace-golden -- stream-verify` | 10/10 OK |
| No rendered-output change | `test-roms-pl -Doptimize=ReleaseFast` | green, floors unmoved |
| Hardware conformance unmoved | `test-roms-ja -Doptimize=ReleaseFast` | 12/17, the same five |
| Fixtures generate | `zig build fixtures` | 7 files (+ Croc where `games/` exists), byte-identical on a second run |
| The bridge, structural | `ps1-macos/test.sh` | green |
| The bridge, executable | `ps1-macos/test.sh` | every synthetic frame's hash matches |
| ABI builds | `zig build capi-lib` | builds |

The first four are **freeze checks**. A2 changes no emulated behaviour, so a moved golden or floor is a bug in the capture tool.

---

## What this plan deliberately does not do

- No Metal, no shader, no rasterization in Swift.
- No `ps1_take_frame_stream`, and no `gpu_sink = .dual` for `ps1-capi`. Phase B.
- No verification of the PL or Croc fixtures' VRAM hashes — nothing on the Swift side can yet produce a rasterized frame to compare against.
- No fixture for every disc. Breadth is `stream-verify`'s job, in Zig.
- No compression and no format migration path. Version 1 is the only version; a format change bumps it and regenerates, because fixtures are artifacts.

---

## Landed

Tasks 1-9 are complete: `22bd7ff` (the record type in `ps1.h`), `eb1a342`
(FNV-1a 64 on both sides), `c1bd64a`/`153927b` (the format), `b8332b6`
(`stream-capture` + the committed synthetic fixture), `778f02e`/`847003a`/
`4b5484b`/`c6c2e44`/`a4f40a1` (EXE-sideload workloads and the PL fixtures),
`006ea6e` (the measured Croc window), `c782e60`/`f900c9f` (the Swift loader),
`57d749f` (`ShadowVram` and the executable gate), `bc6b730` (`zig build
fixtures` and the docs).

Four things the plan did not anticipate, all landed after the closing gate as
their own commits — worth carrying into Phase B, which reuses every one of
these surfaces:

- **`4b5484b`/`847003a`: a capture window must start from a known VRAM state
  and must not open mid-transfer.** The recording window is blanked at its
  first frame, but only over VRAM *pixels*, and only at a frame boundary where
  no `A0` transfer is in flight — otherwise the fixture's first frame replays
  against a shadow that disagrees with the capture's own starting VRAM.
- **`f900c9f`/`edd3793`: the loader treats the file as hostile.** A `u64`
  header field must not be trusted into arithmetic (`f900c9f`), and a replayed
  record's payload offset/length must be bound-checked against its frame's run
  before indexing (`edd3793`). A fixture is an artifact, but a Swift trap in a
  test is indistinguishable from a bridge bug.
- **`a3a4826`: `ShadowVram`'s three mover behaviours needed pinning
  separately** — the unmasked fill, the overlap-reversed copy, and the
  whole-axis extent. The end-to-end hash gate passes over all three at once and
  cannot say which one is wrong when it fails.
- **`d19808d`: an empty `stream-capture` filter is not an error**, because the
  Croc workload matches nothing without `games/`. `verify`/`stream-verify`/
  `capture` keep the opposite rule.
