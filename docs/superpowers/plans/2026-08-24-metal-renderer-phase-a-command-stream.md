# Metal Renderer Phase A — The Command Stream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `gpu/gp0.zig` emit an ordered, lossless stream of typed POD commands alongside today's rasterization, and prove that replaying that stream reproduces VRAM byte for byte — with no GPU code and no output change.

**Architecture:** `gp0.zig` stops calling `Renderer` and `Vram` directly and calls a `Sink` instead. The sink builds one fixed-stride `Command` record per VRAM-visible effect, hands it to a single `execute()` that performs the effect, and — in a build compiled with `gpu_sink = .dual` — also appends it to a per-frame `Recorder`. Replay is `execute()` over the recorded records against a shadow `Vram`. Because the live path and the replay path run the *same* function on the *same* record, a field the sink forgets to fill is a field the rasterizer does not get either.

**Tech Stack:** Zig 0.16.0, `ps1-core` unit tests, `ps1-golden` (new `stream-verify` subcommand), the PeterLemon ratchet (`zig build test-roms-pl`), the trace-equivalence harness (`zig build trace-golden`).

**Spec:** `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md` — see § The seam, § What the stream carries, § Buffers, and § Phases → Phase A.

---

## Context

Phase 0 (committed, `35da268`..`25bcb4e`, recaptured in `47cd236`) converted the software rasterizer to integer edge functions and exact integer interpolation, so a CPU and a GPU rasterizer can evaluate the same formulas. Phase B will build a Metal backend that consumes a recorded GP0 command stream.

Every later phase rests on one assumption: **the stream is lossless.** If a state change, an implicit texpage latch, or a mid-payload abort is missing from it, the Metal backend renders the wrong thing — and the bug surfaces as "Metal disagrees with software", confounded with every genuine shader bug. Falsifying that assumption headlessly, in Zig, against full-VRAM equality, is far cheaper than finding it through a Metal backend.

Phase A therefore builds only the seam, the record types, the recorder, the replay and the gates. There is no Metal, no C ABI change, and no rendered-output change.

---

## Prerequisites (verify before Task 1)

Phase 0 is fully landed: `7caa804` recaptured the goldens and the PeterLemon
floors, and `47cd236` corrected the record of it. Phase A inherits that
baseline and adds nothing to it.

- [ ] **Confirm the baseline is green before touching anything**, so that a
  gate failing later in this phase is attributable to this phase:

  ```bash
  git status --porcelain                                    # expect: empty
  zig build test                                            # expect: green
  zig build test-roms-pl -Doptimize=ReleaseFast             # expect: green
  zig build trace-golden -Doptimize=ReleaseFast -- verify   # expect: all workloads OK
  ```

---

## Global Constraints

- **Zig 0.16.0 only.** `std.Io.Dir.cwd()`, `std.ArrayList(...).empty`, `addRunArtifact`, `b.addOptions`. Run `zig fmt` before every commit.
- **Phase A changes no rendered output.** `zig build trace-golden -- verify` and `zig build test-roms-pl` must be **green at every commit**, not just at the end. Unlike Phase 0 there is no recapture in this phase; a moved golden or floor is a bug in the seam.
- **`zig build test` must stay green at every commit.**
- **`renderer.zig`, `color.zig`, `vram.zig`, `registers.zig` and `primitive.zig` are not touched at all.** In particular `putPixel` and the five oversized-primitive drop sites stay exactly as they are.
- **No file in `ps1-core/src` over ~600 lines.** `gp0.zig` is 458 today and grows by ~30 lines; the three new files are all under 300.
- **`-D` options go BEFORE `--`.** `zig build trace-golden -Doptimize=ReleaseFast -- verify`. Anything after `--` is an argument to `ps1-golden`.
- **Run `ps1-golden` and the ROM suites with `-Doptimize=ReleaseFast`** — ~25x faster, identical results.
- **`zig build test-roms-pl` prints a `failed command: …/test … --listen=-` line and still exits 0.** That is not a red gate. The suite's per-ROM `debug.print` output confuses the build runner's `--listen` protocol, so zig re-runs the binary standalone, which passes; the step's exit code is the thing to read. Check `echo $?` (redirect the log rather than piping, or `$?` is the pager's) before treating a PL run as failed.
- **In the stream tests, `drain()` before every `gp1()` and before any direct `readData()`.** GP1 is immediate, GP0 is queued 16 deep behind `cycle_debt`, and an undrained interleave silently makes the test vacuous rather than red — see `StreamCase.drain`'s doc comment in Task 2 Step 3.
- **Commit style:** one commit per task, directly on `master`, ending with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  ```

---

## Design decisions taken (do not relitigate mid-execution)

**1. The sink is selected by a comptime build option, per core module.**
`Gp0Engine` lives inside `Gpu` inside `Bus`, and `Bus` is threaded through `cpu.zig`; making `Gpu` generic over a sink type would go viral into the CPU. Instead `build.zig` gives each *core module* a `gpu_options` import carrying `gpu_sink: enum { software, dual }`. Today's `core_mod`, `wasm_core_mod` and `capi_core_mod` get `.software`; a new `record_core_mod` gets `.dual` and is used by `ps1-golden`, the round-trip test and the ROM suites. In a `.software` build the recorder's storage type is a zero-sized struct, so `Bus` does not grow by a byte and there is no branch to predict.

**2. `Recorder.enabled` is a runtime flag, defaulting to false.** `.dual` is a build-time *capability*, not a build-time *commitment*. `ps1-golden` compiles with it so `stream-verify` exists at all, but its existing `capture` and `verify` subcommands must stay at today's speed, so they never arm it.

**3. One record type, one interpreter.** `command.execute(cmd, payload, vram, env)` is the single place a `Command` becomes a VRAM effect. The sink calls it on the live path; replay calls it in a loop. There is no second transcription of "what a textured triangle means" to drift out of step.

**4. `gp0.zig` loses its `Renderer` import entirely.** That is the structural guarantee behind losslessness: once gp0 cannot reach the rasterizer except through the sink, a new primitive cannot be added without appearing in the stream.

**5. `ps1-capi` is untouched.** The spec has it building with `DualSink`, but that is only meaningful once `ps1_take_frame_stream` exists, which is Phase B. Flipping it now would add ~6.5 MB to the app's `Bus` for no consumer.

---

## What the stream must carry (the closure argument)

The claim "these seventeen record kinds are all of it" is checkable, and it was checked while writing this plan. Every write to `Gpu.vram.data` in the core comes from exactly two places — `Renderer.putPixel` (`renderer.zig:45`) and `vram.zig`'s `maskedWrite`/`fillRectangle` — and every mutation of `Gpu.draw_env` comes from exactly four. Enumerated:

| Effect | Site today | Record kind |
|---|---|---|
| 7 draw entry points (incl. both quad halves, both polyline paths) | `gp0.zig:210…437` | `draw_triangle`, `draw_shaded_triangle`, `draw_textured_triangle`, `draw_rectangle`, `draw_textured_rectangle`, `draw_line`, `draw_shaded_line` |
| E1–E6 register writes | `gp0.zig:69` → `DrawingEnv.update` | `set_draw_env` |
| Implicit texpage latch by a textured **polygon** | `gp0.zig:260,270,285,298` → `latchPolygonTexpage` | `latch_texpage` |
| GP1(09) texture-disable latch | `gpu.zig:288` | `set_texture_disable_allowed` |
| GP1(00) wholesale `draw_env = .{}` | `gpu.zig:245` | `reset_draw_env` |
| GP0(02) Fill Rectangle (unmasked) | `gp0.zig:171` → `vram.fillRectangle` | `fill_rect` |
| GP0(80) VRAM→VRAM (masked, overlap-aware) | `gp0.zig:182` → `vram.copyRect` | `copy_rect` |
| GP0(A0) setup | `gp0.zig:191` → `vram.setupWrite` | `vram_write_setup` |
| GP0(A0) payload, word by word | `gp0.zig:26` → `vram.writeData` | `vram_write_data` |
| GP1(00)/GP1(01) aborting a payload mid-flight | `gpu.zig:240,260` | `vram_write_abort` |
| GP0(C0) setup | `gp0.zig:200` → `vram.setupRead` | `vram_read_setup` |

Three traps this table encodes, all named in the spec:

- **A textured polygon's blend mode comes from its own tpage word, not from the last E1 write.** `e1_texpage_mask` is `0b0000_1001_1111_1111` (`registers.zig:19`), which covers bits 5-6 — the semi-transparency mode `putPixel` reads at `renderer.zig:31`. A backend reconstructing state only from E1–E6 gets it wrong. **Rectangles do not latch**: `gp0.zig:342` reads the current `draw_mode & 0x1FF` instead.
- **GP0(02) is deliberately unmasked** while GP0(80)/GP0(A0) are masked. The mask is *not* recorded — `execute` recomputes it with `VramMask.fromE6(env.mask_bit)` from the replayed env, which holds the same value at that point in the stream by construction.
- **A single fat A0 record cannot represent an aborted transfer.** Setup, payload and abort are three ordered kinds. E6 cannot change mid-payload (`write_active` swallows every GP0 word), which is why the mask may be read at execute time for payload words too.

`vram_read_setup` mutates no pixels; it is recorded because Phase B serves GPUREAD from the shadow and wants the read window. **`vram_write_abort` is in the same class** — see the correction in Task 4 Step 4. Replay consumes decoded records rather than GP0 words, so an abort can never change a replayed pixel; its whole effect is the shadow's transfer cursor. Both kinds need an explicit state assertion, because `expectIdentical` is blind to them by construction.

---

## File Structure

- `build.zig` — the `gpu_sink` option, `record_core_mod`, the new test binary, and the ROM suites' core module. Modified in Tasks 1, 2 and 8.
- `ps1-core/src/gpu/command.zig` — **new.** `Kind`, `Vertex`, `Command`, `Stream`, `execute()`, `replay()`. The record type and its single interpretation, together.
- `ps1-core/src/gpu/recorder.zig` — **new.** Capacities, `Recorder`, the push methods, `takeFrame()`.
- `ps1-core/src/gpu/sink.zig` — **new.** `kind`, `Storage`, `Sink`. The seam `gp0.zig` calls.
- `ps1-core/src/gpu/gp0.zig` — modified: every `Renderer.*` and `Vram` mutator call becomes a `sink.*` call; the `Renderer` and `VramMask` imports are deleted.
- `ps1-core/src/gpu/gpu.zig` — modified: a `sink: Sink = .{}` field threaded into `gp0.write`, GP1(00)/(01)/(09) routed through it, new re-exports.
- `ps1-core/tests/vram_compare.zig` — **new.** `expectVramEqual`, shared by the two test files that need it.
- `ps1-core/tests/gpu_stream_test.zig` — **new.** The round-trip suite. Its own test binary, because it needs the recording core module.
- `ps1-core/tests/peterlemon_test.zig` — modified in Task 8: each PL ROM's frames are replayed and compared.
- `ps1-golden/src/main.zig` — modified in Task 7: the `stream-verify` subcommand.
- `ps1-golden/src/state_hash.zig` — modified in Task 1: the documented exclusion for `Gpu.sink`, in the same commit that adds the field.
- `CLAUDE.md` — modified in Task 9.

---

## Task 1: The sink seam, forwarding only

Introduce the build option and the three new files, and reroute `gp0.zig` through the sink. **Nothing records yet.** This task stands alone so that the one commit that could plausibly move a golden changes nothing else.

**Files:**
- Modify: `build.zig` (after `core_mod`, after `wasm_core_mod`, after `capi_core_mod`)
- Create: `ps1-core/src/gpu/command.zig`, `ps1-core/src/gpu/recorder.zig`, `ps1-core/src/gpu/sink.zig`
- Modify: `ps1-core/src/gpu/gp0.zig`, `ps1-core/src/gpu/gpu.zig`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `@import("gpu_options").gpu_sink` — `enum { software, dual }`, per core module.
  - `command.Kind`, `command.Vertex`, `command.Command`, `command.Stream`,
    `command.execute(cmd: Command, payload: []const u32, vram: *Vram, env: *DrawingEnv) void`,
    `command.replay(s: Stream, vram: *Vram, env: *DrawingEnv) void`.
  - `recorder.max_records: usize`, `recorder.max_payload_words: usize`, `recorder.Recorder`
    with `arm()`, `reset()`, `push(Command)`, `pushVramWriteData(u32)`, `takeFrame() Stream`,
    and fields `records`, `payload`, `count`, `payload_len`, `overflow`, `enabled`.
  - `sink.Sink`, with `Sink.kind`, `Sink.Storage` and the seventeen methods listed in Step 4.
  - `Gpu.sink: Sink`, and `Gp0Engine.write(value, sink, vram, draw_env, interrupt_flag)`.
  - Re-exports `ps1_core.gpu.command`, `ps1_core.gpu.recorder`, `ps1_core.gpu.Sink`, `ps1_core.gpu.Recorder`.

- [x] **Step 1: Add the `gpu_sink` build option**

In `build.zig`, immediately after `core_mod` is created (line 12):

```zig
    // Which GPU sink the core compiles with.
    //
    // `.software` is today's path: gp0.zig's effects go straight to the
    // rasterizer and nothing else, and `sink.Storage` is a zero-sized struct,
    // so a frontend that never asks for a command stream carries neither the
    // recorder's several megabytes nor a branch. `.dual` rasterizes AND
    // records.
    //
    // Selected per CORE MODULE rather than per frontend, because the sink
    // lives inside Gpu, which lives inside Bus, which cpu.zig threads
    // everywhere: a generic Gpu would go viral through the CPU.
    const GpuSink = enum { software, dual };

    const software_sink = b.addOptions();
    software_sink.addOption(GpuSink, "gpu_sink", .software);
    core_mod.addOptions("gpu_options", software_sink);
```

Add `wasm_core_mod.addOptions("gpu_options", software_sink);` immediately after `wasm_core_mod` is created, and `capi_core_mod.addOptions("gpu_options", software_sink);` immediately after `capi_core_mod` is created. One `*Step.Options` is a generated file and may be added to several modules.

- [x] **Step 2: Write `ps1-core/src/gpu/command.zig`**

```zig
//! One fixed-stride record per VRAM-visible GP0/GP1 effect, and the single
//! function that turns a record back into that effect.
//!
//! The live path and the replay path both call `execute`. That is deliberate:
//! a second transcription of "what a textured triangle means" is exactly the
//! kind of thing that drifts out of step, and a stream that has drifted is a
//! Metal backend rendering the wrong thing for reasons no shader test finds.
//!
//! `extern struct` throughout, because Phase A2 serializes these to a fixture
//! file and Phase B hands them across the C ABI.

const std = @import("std");
const Vram = @import("vram.zig").Vram;
const VramMask = @import("vram.zig").Mask;
const DrawingEnv = @import("registers.zig").DrawingEnv;
const Renderer = @import("renderer.zig").Renderer;

pub const Kind = enum(u8) {
    draw_triangle,
    draw_shaded_triangle,
    draw_textured_triangle,
    draw_rectangle,
    draw_textured_rectangle,
    draw_line,
    draw_shaded_line,
    set_draw_env,
    latch_texpage,
    set_texture_disable_allowed,
    reset_draw_env,
    fill_rect,
    copy_rect,
    vram_write_setup,
    vram_write_data,
    vram_write_abort,
    vram_read_setup,
};

pub const Vertex = extern struct {
    x: i16 = 0,
    y: i16 = 0,
    u: u8 = 0,
    v: u8 = 0,
    _pad: u16 = 0,
    /// 24-bit BGR as it arrives on the wire — the Gouraud paths only.
    color: u32 = 0,
};

/// Field meanings per kind. One flat layout rather than a union, so the buffer
/// is a plain array a C caller can walk with a fixed stride:
///
///   draw_triangle                v[0..2].x/.y, value = ABGR1555 colour, transparent
///   draw_shaded_triangle         v[0..2].x/.y/.color, transparent
///   draw_textured_triangle       v[0..2].x/.y/.u/.v, value = colour, clut, tpage, opcode, transparent
///   draw_rectangle               x, y, w, h, value = colour, transparent
///   draw_textured_rectangle      x, y, w, h, v[0].u/.v = texcoord, value = colour,
///                                clut, tpage, opcode, transparent
///   draw_line                    v[0..1].x/.y, value = colour, transparent
///   draw_shaded_line             v[0..1].x/.y/.color, transparent
///   set_draw_env                 opcode = 0xE1..0xE6, value = the register word
///   latch_texpage                tpage
///   set_texture_disable_allowed  value = 0 or 1
///   reset_draw_env               (no fields)
///   fill_rect                    x, y, w, h, value = ABGR1555 colour
///   copy_rect                    x, y = source, x2, y2 = destination, w, h
///   vram_write_setup             x, y, w, h
///   vram_write_data              x = offset into the payload buffer, y = word count
///   vram_write_abort             (no fields)
///   vram_read_setup              x, y, w, h
///
/// x/y are i32 rather than i16 because a transfer's coordinates come off the
/// wire as a full 16-bit field (`gp0.zig:186-189`) and are legal up to 65535 —
/// they simply clip everything out. Screen-space vertices really are i16.
pub const Command = extern struct {
    kind: Kind,
    opcode: u8 = 0,
    transparent: u8 = 0,
    _pad0: u8 = 0,
    value: u32 = 0,
    clut: u16 = 0,
    tpage: u16 = 0,
    x: i32 = 0,
    y: i32 = 0,
    x2: i32 = 0,
    y2: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    v: [3]Vertex = .{ .{}, .{}, .{} },
};

/// One frame's worth of stream. `complete` is false when the frame overran
/// `recorder.max_records` or `recorder.max_payload_words`: the records present
/// are then a PREFIX, and applying a prefix leaves a shadow VRAM permanently
/// out of step with the rasterizer, so an incomplete stream must be discarded
/// rather than replayed.
pub const Stream = struct {
    records: []const Command,
    payload: []const u32,
    complete: bool,
};

comptime {
    // The whole point of the flat layout is that a C caller can walk the
    // buffer with a fixed stride, and Phase A2 writes it to a fixture file.
    // Pin both here so a field added later is a compile error, not a silently
    // reshaped file format.
    if (@sizeOf(Vertex) != 12) @compileError("Vertex layout changed");
    if (@sizeOf(Command) != 72) @compileError("Command layout changed");
}

pub fn execute(cmd: Command, payload: []const u32, vram: *Vram, env: *DrawingEnv) void {
    const transp = cmd.transparent != 0;
    const color16: u16 = @truncate(cmd.value);

    switch (cmd.kind) {
        .draw_triangle => Renderer.drawTriangle(
            vram,
            env,
            cmd.v[0].x, cmd.v[0].y,
            cmd.v[1].x, cmd.v[1].y,
            cmd.v[2].x, cmd.v[2].y,
            color16,
            transp,
        ),
        .draw_shaded_triangle => Renderer.drawShadedTriangle(
            vram,
            env,
            cmd.v[0].x, cmd.v[0].y, cmd.v[0].color,
            cmd.v[1].x, cmd.v[1].y, cmd.v[1].color,
            cmd.v[2].x, cmd.v[2].y, cmd.v[2].color,
            transp,
        ),
        .draw_textured_triangle => Renderer.drawTexturedTriangle(
            vram,
            env,
            cmd.v[0].x, cmd.v[0].y, cmd.v[0].u, cmd.v[0].v,
            cmd.v[1].x, cmd.v[1].y, cmd.v[1].u, cmd.v[1].v,
            cmd.v[2].x, cmd.v[2].y, cmd.v[2].u, cmd.v[2].v,
            color16,
            cmd.clut,
            cmd.tpage,
            transp,
            cmd.opcode,
        ),
        .draw_rectangle => Renderer.drawRectangle(
            vram,
            env,
            @intCast(cmd.x),
            @intCast(cmd.y),
            cmd.w,
            cmd.h,
            color16,
            transp,
        ),
        .draw_textured_rectangle => Renderer.drawTexturedRectangle(
            vram,
            env,
            @intCast(cmd.x),
            @intCast(cmd.y),
            cmd.w,
            cmd.h,
            cmd.v[0].u,
            cmd.v[0].v,
            color16,
            cmd.clut,
            cmd.tpage,
            transp,
            cmd.opcode,
        ),
        .draw_line => Renderer.drawLine(
            vram,
            env,
            cmd.v[0].x, cmd.v[0].y,
            cmd.v[1].x, cmd.v[1].y,
            color16,
            transp,
        ),
        .draw_shaded_line => Renderer.drawShadedLine(
            vram,
            env,
            cmd.v[0].x, cmd.v[0].y, cmd.v[0].color,
            cmd.v[1].x, cmd.v[1].y, cmd.v[1].color,
            transp,
        ),

        .set_draw_env => env.update(cmd.opcode, cmd.value),
        .latch_texpage => env.latchPolygonTexpage(cmd.tpage),
        .set_texture_disable_allowed => env.texture_disable_allowed = cmd.value != 0,
        .reset_draw_env => env.* = .{},

        .fill_rect => vram.fillRectangle(
            @intCast(cmd.x),
            @intCast(cmd.y),
            @intCast(cmd.w),
            @intCast(cmd.h),
            color16,
        ),
        // The E6 mask is not recorded: it is read from the replayed env, which
        // carries the same value at this point in the stream by construction.
        .copy_rect => vram.copyRect(
            @intCast(cmd.x),
            @intCast(cmd.y),
            @intCast(cmd.x2),
            @intCast(cmd.y2),
            @intCast(cmd.w),
            @intCast(cmd.h),
            VramMask.fromE6(env.mask_bit),
        ),
        .vram_write_setup => vram.setupWrite(
            @intCast(cmd.x),
            @intCast(cmd.y),
            @intCast(cmd.w),
            @intCast(cmd.h),
        ),
        .vram_write_data => {
            const off: usize = @intCast(cmd.x);
            const len: usize = @intCast(cmd.y);
            for (payload[off .. off + len]) |word| {
                vram.writeData(word, VramMask.fromE6(env.mask_bit));
            }
        },
        .vram_write_abort => vram.write_active = false,
        .vram_read_setup => vram.setupRead(
            @intCast(cmd.x),
            @intCast(cmd.y),
            @intCast(cmd.w),
            @intCast(cmd.h),
        ),
    }
}

pub fn replay(s: Stream, vram: *Vram, env: *DrawingEnv) void {
    std.debug.assert(s.complete);
    for (s.records) |cmd| execute(cmd, s.payload, vram, env);
}
```

- [x] **Step 3: Write `ps1-core/src/gpu/recorder.zig`**

```zig
//! Fixed-capacity, per-frame capture of the command stream.
//!
//! No allocation, ever: the emulator thread in the macOS app runs at
//! .userInteractive QoS and must not touch an allocator. A frame exceeding
//! either capacity sets `overflow` and is then reported as INCOMPLETE rather
//! than as a shorter stream — a prefix silently applied to a shadow VRAM puts
//! it permanently out of step.

const std = @import("std");
const command = @import("command.zig");

/// Tekken 3 is known to build a self-referential ordering table, guarded at
/// 65,536 nodes in dma.zig, so "a frame cannot be that large" is not an
/// assumption available here.
pub const max_records: usize = 65_536;

/// A full 1024x512 CPU->VRAM upload is 262,144 words. Two of those per frame.
pub const max_payload_words: usize = 524_288;

pub const Recorder = struct {
    // `undefined` rather than a zero initializer. This saves nothing on the
    // Bus path — `memory.zig`'s `Bus.init` memsets the WHOLE bus to zero
    // before it calls `Gpu.init()`, so these six megabytes are written
    // regardless. It is kept for the direct path: a bare `Gpu.init()` (the
    // unit tests, and anything the later phases stand up) should not pay to
    // zero a buffer it is about to overwrite.
    records: [max_records]command.Command = undefined,
    payload: [max_payload_words]u32 = undefined,
    count: usize = 0,
    payload_len: usize = 0,
    overflow: bool = false,

    /// Off by default. `.dual` is a build-time CAPABILITY, not a build-time
    /// commitment: ps1-golden compiles with it so `stream-verify` exists, and
    /// its `capture`/`verify` subcommands must stay at today's speed.
    enabled: bool = false,

    pub fn arm(self: *Recorder) void {
        self.enabled = true;
        self.reset();
    }

    pub fn reset(self: *Recorder) void {
        self.count = 0;
        self.payload_len = 0;
        self.overflow = false;
    }

    pub fn push(self: *Recorder, cmd: command.Command) void {
        if (!self.enabled) return;
        if (self.count == max_records) {
            self.overflow = true;
            return;
        }
        self.records[self.count] = cmd;
        self.count += 1;
    }

    /// A CPU->VRAM payload word. Consecutive words extend the run in place
    /// rather than pushing a record each: a full-screen upload is 262,144
    /// words and would otherwise blow the record capacity four times over.
    /// A run ends the moment any other command intervenes, which is what keeps
    /// a GP1(01) abort mid-payload in the right place.
    pub fn pushVramWriteData(self: *Recorder, word: u32) void {
        if (!self.enabled) return;
        if (self.payload_len == max_payload_words) {
            self.overflow = true;
            return;
        }
        self.payload[self.payload_len] = word;
        self.payload_len += 1;

        if (self.count > 0 and self.records[self.count - 1].kind == .vram_write_data) {
            self.records[self.count - 1].y += 1;
            return;
        }
        self.push(.{
            .kind = .vram_write_data,
            .x = @intCast(self.payload_len - 1),
            .y = 1,
        });
    }

    /// Hands out the frame and resets. The slices point INTO the recorder and
    /// are valid only until the next recorded command, so consume the stream
    /// before stepping the CPU again.
    pub fn takeFrame(self: *Recorder) command.Stream {
        const s = command.Stream{
            .records = self.records[0..self.count],
            .payload = self.payload[0..self.payload_len],
            .complete = !self.overflow,
        };
        self.reset();
        return s;
    }
};
```

- [x] **Step 4: Write `ps1-core/src/gpu/sink.zig`**

```zig
//! The seam between GP0 command decode and the renderer.
//!
//! gp0.zig no longer imports `Renderer` and no longer calls `Vram`'s mutators:
//! every VRAM-visible effect goes through a Sink method, which builds the
//! record and then executes it. That is a structural guarantee rather than a
//! convention — with the import gone, a new primitive CANNOT be added without
//! appearing in the recorded stream, which is the assumption every later phase
//! of the Metal renderer rests on.

const std = @import("std");
const gpu_options = @import("gpu_options");
const Vram = @import("vram.zig").Vram;
const DrawingEnv = @import("registers.zig").DrawingEnv;
const command = @import("command.zig");
const recorder = @import("recorder.zig");

pub const Sink = struct {
    /// Declared on the struct rather than at file scope so a frontend or a
    /// test can ask `ps1_core.gpu.Sink.kind` without a second re-export.
    pub const kind = gpu_options.gpu_sink;

    /// Zero-sized in a software build, so Bus does not grow by the recorder's
    /// several megabytes for the frontends that never ask for a stream.
    pub const Storage = if (kind == .software) struct {} else recorder.Recorder;

    rec: Storage = .{},

    /// The one place a command becomes an effect. Recording and rasterizing
    /// see the SAME record, so a field the sink forgets to fill is a field the
    /// rasterizer does not get either.
    fn submit(self: *Sink, vram: *Vram, env: *DrawingEnv, cmd: command.Command) void {
        if (comptime Sink.kind == .dual) self.rec.push(cmd);
        command.execute(cmd, &.{}, vram, env);
    }

    pub fn drawTriangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x0: i16,
        y0: i16,
        x1: i16,
        y1: i16,
        x2: i16,
        y2: i16,
        color: u16,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_triangle,
            .transparent = @intFromBool(is_transparent),
            .value = color,
            .v = .{
                .{ .x = x0, .y = y0 },
                .{ .x = x1, .y = y1 },
                .{ .x = x2, .y = y2 },
            },
        });
    }

    pub fn drawShadedTriangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x0: i16,
        y0: i16,
        c0: u32,
        x1: i16,
        y1: i16,
        c1: u32,
        x2: i16,
        y2: i16,
        c2: u32,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_shaded_triangle,
            .transparent = @intFromBool(is_transparent),
            .v = .{
                .{ .x = x0, .y = y0, .color = c0 },
                .{ .x = x1, .y = y1, .color = c1 },
                .{ .x = x2, .y = y2, .color = c2 },
            },
        });
    }

    pub fn drawTexturedTriangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x0: i16,
        y0: i16,
        tu0: u8,
        tv0: u8,
        x1: i16,
        y1: i16,
        tu1: u8,
        tv1: u8,
        x2: i16,
        y2: i16,
        tu2: u8,
        tv2: u8,
        color: u16,
        clut: u16,
        tpage: u16,
        allow_transparency: bool,
        opcode: u8,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_textured_triangle,
            .opcode = opcode,
            .transparent = @intFromBool(allow_transparency),
            .value = color,
            .clut = clut,
            .tpage = tpage,
            .v = .{
                .{ .x = x0, .y = y0, .u = tu0, .v = tv0 },
                .{ .x = x1, .y = y1, .u = tu1, .v = tv1 },
                .{ .x = x2, .y = y2, .u = tu2, .v = tv2 },
            },
        });
    }

    pub fn drawRectangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: i16,
        y: i16,
        w: i32,
        h: i32,
        color: u16,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_rectangle,
            .transparent = @intFromBool(is_transparent),
            .value = color,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
        });
    }

    pub fn drawTexturedRectangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: i16,
        y: i16,
        w: i32,
        h: i32,
        tu: u8,
        tv: u8,
        color: u16,
        clut: u16,
        tpage: u16,
        allow_transparency: bool,
        opcode: u8,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_textured_rectangle,
            .opcode = opcode,
            .transparent = @intFromBool(allow_transparency),
            .value = color,
            .clut = clut,
            .tpage = tpage,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .v = .{ .{ .u = tu, .v = tv }, .{}, .{} },
        });
    }

    pub fn drawLine(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x0: i16,
        y0: i16,
        x1: i16,
        y1: i16,
        color: u16,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_line,
            .transparent = @intFromBool(is_transparent),
            .value = color,
            .v = .{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 }, .{} },
        });
    }

    pub fn drawShadedLine(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x0: i16,
        y0: i16,
        c0: u32,
        x1: i16,
        y1: i16,
        c1: u32,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_shaded_line,
            .transparent = @intFromBool(is_transparent),
            .v = .{
                .{ .x = x0, .y = y0, .color = c0 },
                .{ .x = x1, .y = y1, .color = c1 },
                .{},
            },
        });
    }

    pub fn setDrawEnv(self: *Sink, vram: *Vram, env: *DrawingEnv, opcode: u8, value: u32) void {
        self.submit(vram, env, .{ .kind = .set_draw_env, .opcode = opcode, .value = value });
    }

    pub fn latchTexpage(self: *Sink, vram: *Vram, env: *DrawingEnv, tpage: u16) void {
        self.submit(vram, env, .{ .kind = .latch_texpage, .tpage = tpage });
    }

    pub fn setTextureDisableAllowed(self: *Sink, vram: *Vram, env: *DrawingEnv, allowed: bool) void {
        self.submit(vram, env, .{
            .kind = .set_texture_disable_allowed,
            .value = @intFromBool(allowed),
        });
    }

    pub fn resetDrawEnv(self: *Sink, vram: *Vram, env: *DrawingEnv) void {
        self.submit(vram, env, .{ .kind = .reset_draw_env });
    }

    pub fn fillRect(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: i16,
        y: i16,
        w: i16,
        h: i16,
        color: u16,
    ) void {
        self.submit(vram, env, .{
            .kind = .fill_rect,
            .value = color,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
        });
    }

    pub fn copyRect(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        sx: u16,
        sy: u16,
        dx: u16,
        dy: u16,
        w: u16,
        h: u16,
    ) void {
        self.submit(vram, env, .{
            .kind = .copy_rect,
            .x = sx,
            .y = sy,
            .x2 = dx,
            .y2 = dy,
            .w = w,
            .h = h,
        });
    }

    pub fn vramWriteSetup(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: usize,
        y: usize,
        w: usize,
        h: usize,
    ) void {
        self.submit(vram, env, .{
            .kind = .vram_write_setup,
            .x = @intCast(x),
            .y = @intCast(y),
            .w = @intCast(w),
            .h = @intCast(h),
        });
    }

    /// The payload word does not go through `submit`: the recorder's run
    /// coalescing and the one-word slice `execute` needs do not line up.
    pub fn vramWriteData(self: *Sink, vram: *Vram, env: *DrawingEnv, value: u32) void {
        if (comptime Sink.kind == .dual) self.rec.pushVramWriteData(value);
        const words = [_]u32{value};
        command.execute(.{ .kind = .vram_write_data, .x = 0, .y = 1 }, &words, vram, env);
    }

    pub fn vramWriteAbort(self: *Sink, vram: *Vram, env: *DrawingEnv) void {
        self.submit(vram, env, .{ .kind = .vram_write_abort });
    }

    pub fn vramReadSetup(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: usize,
        y: usize,
        w: usize,
        h: usize,
    ) void {
        self.submit(vram, env, .{
            .kind = .vram_read_setup,
            .x = @intCast(x),
            .y = @intCast(y),
            .w = @intCast(w),
            .h = @intCast(h),
        });
    }
};
```

- [x] **Step 5: Reroute `gp0.zig` through the sink**

Delete `const Renderer = @import("renderer.zig").Renderer;` and `const VramMask = @import("vram.zig").Mask;`. Add `const Sink = @import("sink.zig").Sink;`. Change the entry point at `gp0.zig:24` to

```zig
    pub fn write(self: *Gp0Engine, value: u32, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, interrupt_flag: *bool) u32 {
```

and thread `sink` down to `execute` and every helper (`fillRectangle`, `copyRectangle`, `setupVramWrite`, `setupVramRead`, the eleven `drawXxx`, `continuePolyline`, and the file-level `drawTexturedTriangle`). Rewrite each call site:

| Line | Was | Becomes |
|---|---|---|
| `:26` | `vram.writeData(value, VramMask.fromE6(draw_env.mask_bit))` | `sink.vramWriteData(vram, draw_env, value)` |
| `:69` | `draw_env.update(opcode, self.cmd_buffer[0])` | `sink.setDrawEnv(vram, draw_env, opcode, self.cmd_buffer[0])` |
| `:171` | `vram.fillRectangle(x, y, w, h, color16)` | `sink.fillRect(vram, draw_env, x, y, w, h, color16)` |
| `:182` | `vram.copyRect(sx, sy, dx, dy, w, h, VramMask.fromE6(...))` | `sink.copyRect(vram, draw_env, sx, sy, dx, dy, w, h)` |
| `:191` | `vram.setupWrite(x, y, w, h)` | `sink.vramWriteSetup(vram, draw_env, x, y, w, h)` |
| `:200` | `vram.setupRead(x, y, w, h)` | `sink.vramReadSetup(vram, draw_env, x, y, w, h)` |
| `:260,270,285,298` | `draw_env.latchPolygonTexpage(tpage)` | `sink.latchTexpage(vram, draw_env, tpage)` |
| every `Renderer.drawXxx(vram, draw_env, …)` | | `sink.drawXxx(vram, draw_env, …)` |

`fillRectangle` and `setupVramWrite`/`setupVramRead` currently take only `vram`; give them `draw_env` too. Three helpers take `draw_env: *const Regs.DrawingEnv`; widen them to `*Regs.DrawingEnv`, since `execute` needs a mutable env. **The latch must stay before its draw** — `gp0.zig:260` and `:270` call it before the vertices are decoded, `:285` and `:298` after; either is fine, but it must precede the `sink.drawTexturedTriangle` call.

- [x] **Step 6: Give `Gpu` the sink and route GP1 through it**

At the top of `gpu.zig`:

```zig
pub const command = @import("command.zig");
pub const recorder = @import("recorder.zig");
pub const Sink = @import("sink.zig").Sink;
pub const Recorder = @import("recorder.zig").Recorder;
```

Add the field next to `gp0`:

```zig
    /// Zero-sized unless the core was built with `gpu_sink = .dual`.
    sink: Sink = .{},
```

`processFifoWord` (`:223`):

```zig
        const debt = self.gp0.write(value, &self.sink, &self.vram, &self.draw_env, &self.interrupt_flag);
```

GP1(00) (`:240`, `:245`), GP1(01) (`:260`), GP1(09) (`:288`) — **replace** the direct assignments, do not leave them alongside the sink call, or the effect happens twice and records once:

```zig
            0x00 => {
                self.gp0.words_remaining = 0;
                self.gp0.words_read = 0;
                self.sink.vramWriteAbort(&self.vram, &self.draw_env);
                self.disp_env.display_disabled = true;
                self.interrupt_flag = false;
                self.dma_direction = 0;
                self.disp_env.display_mode = 0;
                self.sink.resetDrawEnv(&self.vram, &self.draw_env);
                ...
            },
            0x01 => {
                self.gp0.words_remaining = 0;
                self.gp0.words_read = 0;
                self.sink.vramWriteAbort(&self.vram, &self.draw_env);
            },
            ...
            0x09 => self.sink.setTextureDisableAllowed(&self.vram, &self.draw_env, (value & 1) != 0),
```

- [x] **Step 7: Account for the new field in `state_hash.zig`**

`ps1-golden/src/state_hash.zig` names every hashed field by hand precisely so a
structural change to the core cannot slip through it, and the spec makes this a
same-commit requirement: a new field on a dumped struct is either hashed or
documented as an exclusion. `Gpu.sink` is an exclusion. Add inside `hashGpu`,
next to the other GPU state:

```zig
    // `g.sink` is deliberately NOT hashed. It is host capture state, not
    // machine state: in a `gpu_sink = .software` build it is a zero-sized
    // struct, and in the `.dual` build ps1-golden itself uses it is a capture
    // buffer whose contents are an artifact of when `stream-verify` last
    // drained it. Hashing it would make `capture`/`verify` disagree with
    // `stream-verify` for reasons that have nothing to do with the emulated
    // machine. Same category as the host pointers and `cdrom.debug_enable`.
```

Add the same one-liner to the module doc comment's exclusion list at the top of
the file.

Note `state_hash.zig` already has a `Sink` of its own — the hash sink. This task
adds only a comment, so nothing collides; if a later phase needs `gpu.Sink` in
this file, alias it at the import.

- [x] **Step 8: Build and run the full gate**

```bash
zig fmt build.zig ps1-core/src/gpu
zig build
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

Expected: all four green, `trace-golden` OK for every workload. A moved golden means the reroute changed behaviour — walk the call-site table again; the usual causes are a `latchPolygonTexpage` that moved relative to its draw, or a GP1 assignment left in place next to its sink call.

- [x] **Step 9: Measure the cost of the shared `execute` path**

The live path now builds a 72-byte record per primitive and passes it to `execute` instead of calling the renderer directly. That should scalarize away, but "should" is not a measurement, and the wasm build runs at real time with no headroom.

```bash
for i in 1 2 3; do
  /usr/bin/time -p zig build trace-golden -Doptimize=ReleaseFast -- \
    verify --filter=croc --instructions=100000000
done
```

Run the same three on the tree before the change and record both numbers in the commit message. Use `git stash -u`, not a bare `git stash`: the three new files are untracked at this point and a bare stash leaves them behind. **If the regression exceeds ~3%, do not proceed**: replace `submit` with a direct `Renderer.*` call in each sink method (keeping `command.execute` for replay only) and re-measure. That trade — duplicated call sites for speed — is acceptable; it costs the "one interpreter" guarantee, and Tasks 2–6 then carry that weight alone.

- [x] **Step 10: Commit**

```bash
git add build.zig ps1-core/src/gpu ps1-golden/src/state_hash.zig
git commit -F - <<'MSG'
refactor(gpu): route GP0 effects through a sink seam

gp0.zig no longer imports Renderer and no longer calls Vram's mutators.
Every VRAM-visible effect becomes a fixed-stride Command that a single
execute() turns back into that effect, so a new primitive cannot be
added without appearing in the stream Phase B will consume.

Nothing records yet: the sink's storage is zero-sized under the default
`gpu_sink = .software`, so no frontend grows or branches.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 2: Recording and replay, proven on triangles

Turn on recording under `.dual`, stand up the round-trip test binary, and prove byte-identical replay for the three triangle kinds and both quad paths.

**Files:**
- Modify: `build.zig` (recording core module, new test binary)
- Create: `ps1-core/tests/vram_compare.zig`
- Create: `ps1-core/tests/gpu_stream_test.zig`

**Interfaces:**
- Consumes: everything Task 1 produced.
- Produces:
  - `record_core_mod` in `build.zig` — a `ps1_core` module with `gpu_sink = .dual`.
  - `vram_compare.expectVramEqual(want: *const Vram, got: *const Vram) !void`.
  - Test helpers in `gpu_stream_test.zig`: `xy(x, y) u32`, `StreamCase` with
    `init`, `deinit`, `gp0`, `gp1`, `fullArea`, `expectIdentical`;
    `uploadPattern(c, x, y, w, h, seed)`; `expectEnvEqual(want, got) !void`.

- [x] **Step 1: Add the recording core module and the stream test to `build.zig`**

After the `software_sink` block:

```zig
    const recording_sink = b.addOptions();
    recording_sink.addOption(GpuSink, "gpu_sink", .dual);

    // A second copy of the core, compiled with the recorder present. Used by
    // ps1-golden's `stream-verify`, the round-trip test and the ROM suites;
    // every other consumer keeps `core_mod` and pays nothing.
    const record_core_mod = b.createModule(.{
        .root_source_file = b.path("ps1-core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    record_core_mod.addOptions("gpu_options", recording_sink);
```

Then, alongside `golden_test` and `capi_test`:

```zig
    // The command-stream round trip. Its own binary because it needs the
    // recording core module; the nine files in `unit_test_files` do not.
    const stream_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-core/tests/gpu_stream_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    stream_test.root_module.addImport("ps1_core", record_core_mod);
    test_step.dependOn(&b.addRunArtifact(stream_test).step);
```

- [x] **Step 2: Write `ps1-core/tests/vram_compare.zig`**

```zig
//! Full-VRAM equality with a readable failure. `expectEqualSlices` over
//! 524,288 pixels prints a diff nobody can use; what a divergence needs is how
//! many pixels moved and where the first one is.

const std = @import("std");
const ps1_core = @import("ps1_core");
const Vram = ps1_core.gpu.Vram;

pub fn expectVramEqual(want: *const Vram, got: *const Vram) !void {
    var diffs: usize = 0;
    var first: usize = 0;
    for (want.data, got.data, 0..) |w, g, i| {
        if (w == g) continue;
        if (diffs == 0) first = i;
        diffs += 1;
    }
    if (diffs == 0) return;
    std.debug.print(
        "\nVRAM diverged: {d} pixels; first at ({d},{d}) want={x:0>4} got={x:0>4}\n",
        .{ diffs, first % 1024, first / 1024, want.data[first], got.data[first] },
    );
    return error.VramDiverged;
}
```

- [x] **Step 3: Write the round-trip harness and its first test**

Create `ps1-core/tests/gpu_stream_test.zig`:

```zig
//! Phase A gate: a recorded command stream, replayed into a shadow VRAM, must
//! reproduce the rasterizer's VRAM byte for byte.
//!
//! This binary is compiled against the recording core module (`gpu_sink =
//! .dual`); the other unit-test files are not, and cannot see the recorder.

const std = @import("std");
const ps1_core = @import("ps1_core");
const expectVramEqual = @import("vram_compare.zig").expectVramEqual;

const Gpu = ps1_core.gpu.Gpu;
const Vram = ps1_core.gpu.Vram;
const DrawingEnv = ps1_core.gpu.Regs.DrawingEnv;
const command = ps1_core.gpu.command;
const recorder = ps1_core.gpu.recorder;

comptime {
    // If this binary ends up on the software core module the whole suite is
    // vacuous, so fail the build rather than pass silently.
    if (ps1_core.gpu.Sink.kind != .dual) @compileError("gpu_stream_test needs gpu_sink = .dual");
}

fn xy(x: u16, y: u16) u32 {
    return @as(u32, x & 0x7FF) | (@as(u32, y & 0x7FF) << 16);
}

/// Both the Gpu (1 MB of VRAM plus 6.5 MB of recorder) and the shadow VRAM
/// are heap-allocated: 8.5 MB of test-runner stack is not available.
const StreamCase = struct {
    a: std.mem.Allocator,
    gpu: *Gpu,
    shadow: *Vram,
    env: DrawingEnv = .{},

    fn init(a: std.mem.Allocator) !StreamCase {
        const gpu = try a.create(Gpu);
        gpu.* = Gpu.init();
        gpu.sink.rec.arm();

        const shadow = try a.create(Vram);
        shadow.* = .{};

        return .{ .a = a, .gpu = gpu, .shadow = shadow };
    }

    fn deinit(self: *StreamCase) void {
        self.a.destroy(self.gpu);
        self.a.destroy(self.shadow);
    }

    fn gp0(self: *StreamCase, word: u32) void {
        _ = self.gpu.writeGp0(word);
    }

    fn gp1(self: *StreamCase, word: u32) void {
        self.gpu.writeGp1(word);
    }

    /// Drains the GP0 FIFO so every queued word has actually executed.
    ///
    /// **Call this before every `gp1()` and before any direct `gpu.readData()`,
    /// and it is not optional.** GP1 writes execute immediately
    /// (`gpu.zig:232`), while GP0 words queue into a 16-entry FIFO gated on
    /// `cycle_debt` — and once the debt goes positive, `writeGp0` only retires
    /// a word when the FIFO is already full, so the FIFO sits a **permanent 16
    /// words behind** for the rest of the test. A `gp1()` issued without
    /// draining therefore lands 16 GP0 words earlier than the source reads,
    /// and the queued words are applied AFTER it.
    ///
    /// The trap is that `expectIdentical` still passes: the live path and the
    /// replay see the same order either way, so the round trip is green and the
    /// test has quietly stopped exercising the scenario its name describes.
    /// Task 3's GP1(00) test is the sharp example — 7 GP0 words are written
    /// before the reset and only 1 has executed, so the E3/E4/E5 writes land
    /// after `draw_env = .{}` and the drawing area is not the default at all.
    fn drain(self: *StreamCase) void {
        _ = self.gpu.step(50_000_000);
    }

    /// Full drawing area, zero offset — the same preamble gpu_test.zig uses.
    fn fullArea(self: *StreamCase) void {
        self.gp0(0xE3000000);
        self.gp0(0xE407FFFF);
        self.gp0(0xE5000000);
    }

    fn expectIdentical(self: *StreamCase) !void {
        self.drain();
        const s = self.gpu.sink.rec.takeFrame();
        try std.testing.expect(s.complete);
        command.replay(s, self.shadow, &self.env);
        try expectVramEqual(&self.gpu.vram, self.shadow);
    }
};

/// Issues GP0(A0) for a w x h rectangle at (x, y) plus the (w*h+1)/2 payload
/// words that follow it, filled with a deterministic pattern. Every test that
/// samples a texture needs real texels in VRAM first, and they have to arrive
/// through the stream like everything else.
fn uploadPattern(c: *StreamCase, x: u16, y: u16, w: u16, h: u16, seed: u16) void {
    c.gp0(0xA0000000);
    c.gp0(@as(u32, x) | (@as(u32, y) << 16));
    c.gp0(@as(u32, w) | (@as(u32, h) << 16));

    const words = (@as(u32, w) * @as(u32, h) + 1) / 2;
    var i: u32 = 0;
    while (i < words) : (i += 1) {
        const lo: u16 = seed +% @as(u16, @truncate(i *% 2));
        const hi: u16 = seed +% @as(u16, @truncate(i *% 2 +% 1));
        c.gp0(@as(u32, lo) | (@as(u32, hi) << 16));
    }
}

fn expectEnvEqual(want: *const DrawingEnv, got: *const DrawingEnv) !void {
    try std.testing.expectEqual(want.draw_mode, got.draw_mode);
    try std.testing.expectEqual(want.tex_window, got.tex_window);
    try std.testing.expectEqual(want.area_top_left, got.area_top_left);
    try std.testing.expectEqual(want.area_bot_right, got.area_bot_right);
    try std.testing.expectEqual(want.offset, got.offset);
    try std.testing.expectEqual(want.mask_bit, got.mask_bit);
    try std.testing.expectEqual(want.texture_disable_allowed, got.texture_disable_allowed);
}

test "Stream: flat triangle and flat quad round-trip" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0x20FF00FF); // flat triangle, magenta
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x40, 0x10));
    c.gp0(xy(0x28, 0x40));

    c.gp0(0x2800FF00); // flat quad, green
    c.gp0(xy(0x60, 0x60));
    c.gp0(xy(0xA0, 0x60));
    c.gp0(xy(0x60, 0xA0));
    c.gp0(xy(0xA0, 0xA0));

    try c.expectIdentical();
}
```

- [x] **Step 4: Confirm it passes, and confirm it CAN fail**

```bash
zig build test -Dtest-filter="Stream: flat triangle"
```

Expected: **PASS.** There is no red step to stage here and it would be dishonest
to invent one: Task 1's `submit` already pushes under `.dual`, `arm()` already
enables it, and Step 1's `build.zig` wiring is the last piece. Note also that an
unwired binary would **not** fail with `VRAM diverged` — the file's
`comptime { if (Sink.kind != .dual) @compileError(...) }` makes that a compile
error, which is the point of the guard.

What is worth two minutes is proving the assertion is live. In `sink.zig`,
temporarily change `drawTriangle` to call `command.execute(...)` directly
instead of `submit(...)`, so the effect still happens but is not recorded:

```zig
    // TEMPORARY — revert before committing.
    pub fn drawTriangle(...) void {
        const cmd: command.Command = .{ ... };
        command.execute(cmd, &.{}, vram, env);
    }
```

Re-run. Expected: **FAIL** with `VRAM diverged: <n> pixels; first at (…)`, the
triangle painted live and absent from the shadow. Restore `submit` and confirm
green again. A round-trip test that cannot fail is not a gate; this is the one
place in Task 2 worth spending the time to prove otherwise. (Task 3 Step 2 does
the same for the texpage latch, which is the record most likely to be dropped
for real.)

- [x] **Step 5: Watch for a stack overflow in `Bus.init`, and fix it if it fires**

Under `.dual` a `Gpu` is ~7.7 MB by value: 1 MB of VRAM plus the recorder's
~6.7 MB. `memory.zig:125` is `bus.gpu = Gpu.init();` and `Gpu.init` is
`return .{};`, so result-location semantics *should* construct it straight into
the heap-allocated `Bus` with no temporary — but "should" is the operative word,
and a Debug build that materialises the temporary overflows the stack instantly.

If `zig build test` segfaults or reports a stack overflow inside `Bus.init`
(or inside `StreamCase.init`, which does the same thing through
`gpu.* = Gpu.init()`), the fix is to drop the by-value round trip at the call
site rather than to shrink the recorder:

```zig
-   bus.gpu = Gpu.init();
+   bus.gpu = .{};
```

If it does not fire, change nothing — `Gpu.init()` is the convention every other
device in `Bus.init` follows and is not worth breaking speculatively.

- [x] **Step 6: Add the shaded and textured triangle round-trips**

```zig
test "Stream: Gouraud triangle and quad round-trip with dithering on" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gp0(0xE1000200); // E1 with dither ON — the shaded path reads bit 9

    c.gp0(0x300000FF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x0000FF00);
    c.gp0(xy(0x50, 0x10));
    c.gp0(0x00FF0000);
    c.gp0(xy(0x30, 0x50));

    c.gp0(0x380000FF);
    c.gp0(xy(0x80, 0x80));
    c.gp0(0x0000FF00);
    c.gp0(xy(0xC0, 0x80));
    c.gp0(0x00FF0000);
    c.gp0(xy(0x80, 0xC0));
    c.gp0(0x00FFFFFF);
    c.gp0(xy(0xC0, 0xC0));

    try c.expectIdentical();
}

test "Stream: a textured triangle round-trips through the CLUT it samples" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // The CLUT and the texture page are uploaded THROUGH the stream, and the
    // draw then samples VRAM the stream itself wrote. That dependency is the
    // property the whole design turns on: replay only reproduces the draw if
    // it reproduced the upload first.
    uploadPattern(&c, 0, 300, 16, 1, 0x1234); // 16-entry CLUT at (0,300)
    uploadPattern(&c, 0, 256, 64, 64, 0x0F0F); // 4bpp page at (0,256)

    // clut word  = (y << 6) | (x / 16)         -> (300 << 6) | 0 = 0x4B00
    // tpage word = (page_y_flag << 4) | (x/64) -> 0x10, depth 0 (4bpp)
    c.gp0(0x24808080); // textured triangle, modulated, opaque
    c.gp0(xy(0x20, 0x20));
    c.gp0(0x4B000000); // clut, u=0,  v=0
    c.gp0(xy(0x60, 0x20));
    c.gp0(0x00100040); // tpage, u=64, v=0
    c.gp0(xy(0x40, 0x60));
    c.gp0(0x00003F20); // u=32, v=63

    try c.expectIdentical();
}
```

- [x] **Step 7: Run the three tests**

```bash
zig build test -Dtest-filter="Stream:"
```

Expected: PASS. A divergence on the textured test alone means the tpage latch is recorded in the wrong order relative to its draw.

- [x] **Step 8: Full gate and commit**

```bash
zig fmt build.zig ps1-core/tests
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
git add build.zig ps1-core/tests/gpu_stream_test.zig ps1-core/tests/vram_compare.zig
git commit -F - <<'MSG'
test(gpu): prove the command stream replays triangles byte-identically

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 3: State changes — E1–E6, the texpage latch, GP1(00) and GP1(09)

The spec calls the implicit texpage latch the thing "a backend that reconstructs state purely from recorded E1–E6 writes gets wrong for every textured polygon". Pin it, and pin the other three state records with it.

**Files:**
- Test: `ps1-core/tests/gpu_stream_test.zig` (append)

**Interfaces:**
- Consumes: `StreamCase`, `uploadPattern`, `expectEnvEqual`, `xy` from Task 2.
- Produces: no new API.

- [x] **Step 1: Write the texpage-latch test**

```zig
test "Stream: a textured polygon's own tpage sets the blend mode, not the last E1" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // 15bpp texels with bit15 set, so the polygon's semi-transparency runs.
    uploadPattern(&c, 0, 256, 64, 64, 0x8421);

    // E1 selects semi-transparency mode 0 (B/2 + F/2), 15bpp, page (0,256)...
    c.gp0(0xE1000000 | 0x10 | (2 << 7) | (0 << 5));

    // ...and a solid background to blend against.
    c.gp0(0x60FFFFFF);
    c.gp0(xy(0x20, 0x20));
    c.gp0(xy(0x40, 0x40));

    // ...but the polygon carries mode 2 (B - F) in bits 5-6 of its OWN tpage
    // word, which latchPolygonTexpage writes straight into draw_mode, and
    // which putPixel then reads. Dropping the latch record leaves the replay
    // blending with mode 0 and every covered pixel differs.
    const tpage: u32 = 0x10 | (2 << 7) | (2 << 5);
    c.gp0(0x27000000); // textured triangle, semi-transparent, raw texture
    c.gp0(xy(0x20, 0x20));
    c.gp0(0x00000000);
    c.gp0(xy(0x50, 0x20));
    c.gp0(tpage << 16);
    c.gp0(xy(0x30, 0x50));
    c.gp0(0x00003F20);

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
}
```

- [x] **Step 2: Run it, then prove it can fail**

```bash
zig build test -Dtest-filter="Stream: a textured polygon's own tpage"
```

Expected: PASS. Then **deliberately break the recording**: in `sink.zig`, temporarily change `latchTexpage` to call `command.execute(...)` directly instead of `submit(...)`, so the effect still happens live but is not recorded. Re-run and confirm the test FAILS. Restore `submit`. A round-trip test that cannot fail is not a gate, and this is the one place worth spending two minutes proving that.

Two notes from doing it:

- The failure you see is the **pixels**, not `expectEnvEqual` — `VRAM diverged: 1176 pixels; first at (32,32) want=fbde got=c210`. `expectIdentical` runs first and returns an error, so the `expectEnvEqual` line below it never executes. Both checks are genuinely broken by the dropped record; only one of them is observable per run. Do not read the absence of an env failure as the env being fine.
- The same two minutes are worth spending on the GP1 records from Steps 4 and 5, which are the other two most likely to be dropped, and which the plan originally left unproven. Breaking `setTextureDisableAllowed` and `resetDrawEnv` the same way fails both tests, and fails them on *different* assertions — GP1(09) on `expectEnvEqual` (`expected 3774875648, found 3774873600`, i.e. bit 11) and GP1(00) on the pixels (`256 pixels; first at (80,80)`), which is exactly the 16x16 rect the reset should have clipped away. Restore both.

- [x] **Step 3: Write the E1–E6 test**

```zig
test "Stream: E1-E6 writes between draws reach the replayed environment" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // E3/E4: a tighter drawing area clips the second of two identical rects.
    c.gp0(0x60FF0000);
    c.gp0(xy(0x40, 0x40));
    c.gp0(0x00200020);
    c.gp0(0xE3000000 | 0x48 | (0x48 << 10));
    c.gp0(0xE4000000 | 0x50 | (0x50 << 10));
    c.gp0(0x6000FF00);
    c.gp0(xy(0x40, 0x40));
    c.gp0(0x00200020);

    // E5: the same rect again, displaced by the drawing offset.
    c.gp0(0xE3000000);
    c.gp0(0xE407FFFF);
    c.gp0(0xE5000000 | 0x80 | (0x60 << 11));
    c.gp0(0x600000FF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00180018);

    // E6: set-mask on, so the rect comes back with bit15 set.
    c.gp0(0xE5000000);
    c.gp0(0xE6000001);
    c.gp0(0x60FFFFFF);
    c.gp0(xy(0x120, 0x30));
    c.gp0(0x00100010);

    // E2: a texture window folds the sampled u/v of a textured rectangle.
    c.gp0(0xE6000000);
    uploadPattern(&c, 0, 0x100, 64, 64, 0x2468);
    c.gp0(0xE1000000 | 0x10 | (2 << 7)); // page (0,256), 15bpp
    c.gp0(0xE2000000 | 0x1F | (0x1F << 5));
    c.gp0(0x64808080);
    c.gp0(xy(0x160, 0x30));
    c.gp0(0x00000000);
    c.gp0(0x00200020);

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
}
```

- [x] **Step 4: Write the GP1(09) test**

```zig
test "Stream: GP1(09) gates the E1 texture-disable bit" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // Bit 11 is masked off while GP1(09) has not enabled it...
    c.gp0(0xE1000000 | (1 << 11));
    c.drain();
    try std.testing.expectEqual(@as(u32, 0), c.gpu.draw_env.draw_mode & (1 << 11));

    // ...and survives afterwards. Drop the GP1(09) record and the replayed
    // env masks the second write off too, so the two envs disagree.
    c.gp1(0x09000001);
    c.gp0(0xE1000000 | (1 << 11));
    c.drain();
    try std.testing.expectEqual(@as(u32, 1 << 11), c.gpu.draw_env.draw_mode & (1 << 11));

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
}
```

- [x] **Step 5: Write the GP1(00) test**

```zig
test "Stream: GP1(00) resets the drawing environment mid-stream" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gp0(0xE5000000 | 0x40 | (0x40 << 11)); // offset (64, 64)

    c.gp0(0x60FF00FF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00100010);

    // Without this the E3/E4/E5 preamble is still sitting in the GP0 FIFO when
    // the reset executes, and lands AFTER it — the drawing area is then the
    // full one, the rectangle below paints, and the test is green for the
    // wrong reason. See StreamCase.drain.
    c.drain();

    c.gp1(0x00000000); // GPU reset: draw_env = .{}

    // The same rectangle again. After the reset the drawing area is the
    // DEFAULT (top-left 0,0 and bottom-right 0,0), so it paints nothing at
    // all; without the reset record the replay paints 16x16 at (80,80).
    c.gp0(0x6000FF00);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00100010);

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
}
```

- [x] **Step 6: Run, gate, commit**

```bash
zig build test -Dtest-filter="Stream:"
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig fmt ps1-core/tests/gpu_stream_test.zig
git commit -am "test(gpu): pin the stream's state records, including the implicit texpage latch

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: VRAM access — fill, copy, upload, abort, read setup

The four paths that never touch the `Renderer` seam, and the ones the spec says the original design under-specified.

**Files:**
- Test: `ps1-core/tests/gpu_stream_test.zig` (append)

**Interfaces:**
- Consumes: `StreamCase`, `uploadPattern`, `xy` from Task 2.
- Produces: no new API.

- [x] **Step 1: Fill is unmasked; the copy and the upload are not**

```zig
test "Stream: fill rectangle ignores E6 while copy and upload honour it" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // Pre-mark bit15 at each masked write's DESTINATION, not at the fill's.
    // check-mask tests the pixel already in VRAM where the write is going, so
    // marking the source proves nothing — and marking the fill's target proves
    // less than nothing, because the fill overwrites the marks (bit15 clear)
    // before either masked path runs, leaving `check` never once exercised.
    uploadPattern(&c, 0x40, 0x10, 16, 16, 0x8000); // A0's destination
    uploadPattern(&c, 0x10, 0x40, 16, 16, 0x8000); // the copy's destination
    uploadPattern(&c, 0x10, 0x10, 16, 16, 0x8000); // and the fill's, for contrast

    c.gp0(0xE6000003); // set-mask AND check-mask

    // GP0(02) deliberately ignores both: this repaints the marked block at
    // (0x10,0x10) outright, bit15 included, where a masked write would skip it.
    c.gp0(0x02FF00FF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00200020);

    // A0 honours both: the 16x16 marked block at (0x40,0x10) is skipped
    // pixel-for-pixel, and only the surrounding rows of the 16x32 upload land.
    uploadPattern(&c, 0x40, 0x10, 16, 32, 0x00AA);

    // GP0(80) honours both: the marked block at the destination is skipped,
    // and what does get written picks up bit15 from set-mask.
    c.gp0(0x80000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x10, 0x40));
    c.gp0(xy(0x20, 0x20));

    try c.expectIdentical();
}
```

- [x] **Step 2: The overlapping copy, in both directions**

`vram.zig:154` reverses iteration order when `(dy > sy) or (dy == sy and dx > sx)`. Cover both branches over a source region that is *not* uniform, so a wrong direction smears visibly instead of reproducing itself.

```zig
test "Stream: an overlapping VRAM-to-VRAM copy round-trips in both directions" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    uploadPattern(&c, 0x10, 0x10, 32, 32, 0x0101);

    // Forwards branch: destination above and left of the source.
    c.gp0(0x80000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x08, 0x08));
    c.gp0(xy(32, 32));

    // Backwards branch: destination below and right, overlapping.
    c.gp0(0x80000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x18, 0x18));
    c.gp0(xy(32, 32));

    try c.expectIdentical();
}
```

- [x] **Step 3: A long upload coalesces into one run and still samples right**

```zig
test "Stream: a long upload coalesces into one payload run" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    uploadPattern(&c, 0, 0x100, 256, 64, 0x3C3C); // 8,192 payload words
    c.drain();

    // One setup record and ONE data record, not 8,192 of them — a wrong `y`
    // on the run replays the wrong texel count and the quad below diverges.
    const rec = &c.gpu.sink.rec;
    const run = rec.records[rec.count - 1];
    try std.testing.expectEqual(command.Kind.vram_write_data, run.kind);
    try std.testing.expectEqual(@as(i32, 8192), run.y);
    try std.testing.expectEqual(command.Kind.vram_write_setup, rec.records[rec.count - 2].kind);

    c.gp0(0xE1000000 | 0x10 | (2 << 7)); // page (0,256), 15bpp

    c.gp0(0x2D808080); // textured quad, raw
    c.gp0(xy(0x20, 0x20));
    c.gp0(0x00000000); // u=0,  v=0   (clut unused at 15bpp)
    c.gp0(xy(0x60, 0x20));
    c.gp0((0x10 | (2 << 7)) << 16 | 0x0040); // tpage word; u=64, v=0
    c.gp0(xy(0x20, 0x60));
    c.gp0(0x00003F00); // u=0,  v=63
    c.gp0(xy(0x60, 0x60));
    c.gp0(0x00003F40); // u=64, v=63

    try c.expectIdentical();
}
```

- [x] **Step 4: The abort — GP1(01) and GP1(00) mid-payload**

**Correction, found by executing this step.** The rationale in the code comment
below — "drop the abort record and the replay eats all three of these words into
the transfer it still thinks is running" — **is wrong, and the version of these
two tests that asserts only on pixels passes with `vram_write_abort` dropped
entirely** (verified by routing `vramWriteAbort` around `submit`). Replay
consumes *records*, not GP0 words: by the time a word reaches the stream it has
already been decoded, so the three words after the abort arrive as one
`draw_rectangle` record whether or not the abort was recorded. Nothing
downstream can expose the stale cursor through a pixel either — the live side
stops emitting payload words the moment it aborts, and the next transfer's
`vram_write_setup` overwrites `write_x/y/w/h/remaining/active` before any
payload resumes. `vram_write_abort` is therefore **pixel-invisible in replay,
always**.

It is still a required record — Phase B inherits the same shadow — so pin it the
way Step 5 already pins `vram_read_setup`, on the shadow's transfer state:

```zig
    try std.testing.expect(!c.shadow.write_active);
```

with the pixel comment reworded to say the replay *cannot* get the decode wrong.
With that line both tests fail cleanly when the record is dropped.

The general rule this exposes, worth carrying into Tasks 5–6: **a record that
mutates no pixel cannot be pinned by `expectIdentical`.** Two of the seventeen
kinds are in that class — `vram_write_abort` and `vram_read_setup` — and both
need an explicit assertion on the shadow's transfer state. Every other kind
either writes VRAM or feeds `DrawingEnv`, which `expectEnvEqual` covers.

```zig
test "Stream: GP1(01) aborts a CPU-to-VRAM payload mid-flight" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0xA0000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00100010); // 16x16 -> 128 words expected
    var i: u32 = 0;
    while (i < 40) : (i += 1) c.gp0(0xDEAD0000 | i); // only 40 arrive
    c.drain(); // all 40 have really executed before the abort — StreamCase.drain

    c.gp1(0x01000000); // abort

    // The next GP0 word must be decoded as a COMMAND, not swallowed as
    // payload. Drop the abort record and the replay eats all three of these
    // words into the transfer it still thinks is running.
    c.gp0(0x60FF0000);
    c.gp0(xy(0x50, 0x50));
    c.gp0(0x00080008);

    try c.expectIdentical();
}

test "Stream: GP1(00) aborts a payload and resets the environment together" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0xA0000000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00100010);
    var i: u32 = 0;
    while (i < 40) : (i += 1) c.gp0(0xBEEF0000 | i);
    c.drain();

    c.gp1(0x00000000);

    // Two ordered effects from one GP1 word: the transfer aborts AND the
    // drawing area goes back to its default, which is a single pixel.
    c.gp0(0x6000FF00);
    c.gp0(xy(0x50, 0x50));
    c.gp0(0x00080008);

    try c.expectIdentical();
    try expectEnvEqual(&c.gpu.draw_env, &c.env);
}
```

- [x] **Step 5: GP0(C0) read setup does not perturb the replay**

```zig
test "Stream: a VRAM-to-CPU read setup replays the window, not the cursor" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    uploadPattern(&c, 0x20, 0x20, 16, 16, 0x5A5A);

    c.gp0(0xC0000000);
    c.gp0(xy(0x20, 0x20));
    c.gp0(0x00100010);

    // readData() is immediate; the C0 that arms it is not. Undrained, the
    // transfer has not been set up yet and all 128 reads return gpu_read_data
    // instead of VRAM, so the drain below is what makes them real reads.
    c.drain();

    var i: usize = 0;
    while (i < 128) : (i += 1) _ = c.gpu.readData();

    c.gp0(0x60FF00FF);
    c.gp0(xy(0x50, 0x50));
    c.gp0(0x00100010);

    try c.expectIdentical();

    // The setup IS replayed, so the shadow's read WINDOW matches. The drains
    // are not recorded, because reading VRAM mutates no pixel.
    //
    // That leaves the shadow's read CURSOR permanently unadvanced —
    // `read_remaining` never decrements and `read_active` never clears — which
    // is fine for Phase A (expectVramEqual compares `.data` only) but is a real
    // open question for Phase B: serving GPUREAD from the shadow needs the
    // drains recorded too, or the cursor driven from the live side. Do not read
    // this test as evidence that Phase B's GPUREAD path already works.
    try std.testing.expect(c.shadow.read_active);
    try std.testing.expectEqual(@as(usize, 0x20), c.shadow.read_x);
    try std.testing.expectEqual(@as(usize, 16), c.shadow.read_w);
}
```

- [x] **Step 6: Run, gate, commit**

```bash
zig build test -Dtest-filter="Stream:"
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig fmt ps1-core/tests/gpu_stream_test.zig
git commit -am "test(gpu): pin the stream's VRAM-access records and mid-payload aborts

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: Lines, polylines and rectangles

The remaining four draw entry points, plus the polyline path — which reaches `drawLine`/`drawShadedLine` from a completely different place in `gp0.zig` (`:378`, `:406`) and is easy to miss.

**Files:**
- Test: `ps1-core/tests/gpu_stream_test.zig` (append)

- [x] **Step 1: Mono and shaded lines, including a zero-length one**

```zig
test "Stream: mono and shaded lines round-trip, including a zero-length one" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();
    c.gp0(0xE1000200); // dither on — the shaded-line gradient reads bit 9

    c.gp0(0x40FFFFFF);
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x60, 0x40));

    c.gp0(0x500000FF);
    c.gp0(xy(0x10, 0x50));
    c.gp0(0x00FF0000);
    c.gp0(xy(0x60, 0x50));

    // Zero length: one pixel, and the `steps == 0` guard in drawShadedLine.
    c.gp0(0x500000FF);
    c.gp0(xy(0x70, 0x70));
    c.gp0(0x00FFFFFF);
    c.gp0(xy(0x70, 0x70));

    try c.expectIdentical();
}
```

- [x] **Step 2: Polylines, counting the records as well as the pixels**

```zig
test "Stream: polylines record one line per segment" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0x480000FF); // mono polyline, 4 vertices -> 3 segments
    c.gp0(xy(0x10, 0x10));
    c.gp0(xy(0x40, 0x10));
    c.gp0(xy(0x40, 0x40));
    c.gp0(xy(0x10, 0x40));
    c.gp0(0x55555555);

    c.gp0(0x5800FF00); // shaded polyline, 3 vertices -> 2 segments
    c.gp0(xy(0x60, 0x10));
    c.gp0(0x000000FF);
    c.gp0(xy(0x90, 0x10));
    c.gp0(0x00FF0000);
    c.gp0(xy(0x90, 0x40));
    c.gp0(0x55555555);

    c.drain();

    // A polyline path that silently records nothing still passes a VRAM check
    // wherever the shadow happens to be black, so count the records too.
    var mono: usize = 0;
    var shaded: usize = 0;
    const rec = &c.gpu.sink.rec;
    for (rec.records[0..rec.count]) |cmd| {
        switch (cmd.kind) {
            .draw_line => mono += 1,
            .draw_shaded_line => shaded += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 3), mono);
    try std.testing.expectEqual(@as(usize, 2), shaded);

    try c.expectIdentical();
}
```

- [x] **Step 3: All three rectangle size classes, plain and textured**

```zig
test "Stream: all three rectangle size classes, plain and textured" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0x60FF0000); // variable size
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x000C0014);

    c.gp0(0x7000FF00); // 8x8
    c.gp0(xy(0x40, 0x10));

    c.gp0(0x780000FF); // 16x16
    c.gp0(xy(0x60, 0x10));

    uploadPattern(&c, 0, 0x100, 64, 64, 0x1357);

    // A textured RECTANGLE does not latch — gp0.zig:342 reads the CURRENT
    // texpage instead — so this E1 write is what selects the page it samples,
    // and dropping the set_draw_env record leaves the replay sampling page 0.
    c.gp0(0xE1000000 | 0x10 | (2 << 7));

    c.gp0(0x64808080); // variable size, modulated
    c.gp0(xy(0x10, 0x40));
    c.gp0(0x00000000);
    c.gp0(0x00200020);

    c.gp0(0x74808080); // 8x8
    c.gp0(xy(0x40, 0x40));
    c.gp0(0x00001010);

    c.gp0(0x7C808080); // 16x16
    c.gp0(xy(0x60, 0x40));
    c.gp0(0x00002020);

    try c.expectIdentical();
}
```

- [x] **Step 4: The oversized-primitive drop rule survives the round trip**

```zig
test "Stream: an oversized primitive is dropped identically on both sides" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    c.gp0(0x60FFFFFF); // 1024 wide -> refused, not clipped
    c.gp0(xy(0, 0));
    c.gp0(1024 | (8 << 16));

    c.gp0(0x40FFFFFF); // 600 tall -> refused
    c.gp0(xy(0x10, 0));
    c.gp0(xy(0x10, 600));

    c.drain();

    // Both are RECORDED — the sink runs before the renderer's refusal — and
    // dropped again by the same renderer on replay, so both sides stay black.
    //
    // Count the two KINDS, not the total: fullArea() alone leaves three
    // set_draw_env records, so `count >= 2` would pass with neither oversized
    // primitive recorded at all — which is precisely the failure this test
    // exists to catch.
    var rects: usize = 0;
    var lines: usize = 0;
    const rec = &c.gpu.sink.rec;
    for (rec.records[0..rec.count]) |cmd| {
        switch (cmd.kind) {
            .draw_rectangle => rects += 1,
            .draw_line => lines += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 1), lines);

    for (c.gpu.vram.data) |px| try std.testing.expectEqual(@as(u16, 0), px);

    try c.expectIdentical();
}
```

- [x] **Step 5: Run, gate, commit**

```bash
zig build test -Dtest-filter="Stream:"
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig fmt ps1-core/tests/gpu_stream_test.zig
git commit -am "test(gpu): pin the stream's line, polyline and rectangle records

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 6: Overflow and the incomplete stream

An overflowed frame is a *prefix*, and a prefix applied to a shadow VRAM puts it permanently out of step. Make that state loud rather than silent.

**Files:**
- Test: `ps1-core/tests/gpu_stream_test.zig` (append)

- [x] **Step 1: Write the record-capacity test**

```zig
test "Stream: exceeding the record capacity marks the frame incomplete" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // Zero-area triangles: recorded in full, refused by the rasterizer before
    // it touches a pixel, so this loop costs almost nothing.
    var i: usize = 0;
    while (i < recorder.max_records + 16) : (i += 1) {
        c.gp0(0x20FFFFFF);
        c.gp0(xy(0, 0));
        c.gp0(xy(0, 0));
        c.gp0(xy(0, 0));
    }
    c.drain();

    try std.testing.expect(c.gpu.sink.rec.overflow);
    const s = c.gpu.sink.rec.takeFrame();
    try std.testing.expect(!s.complete);
    // The records it DID keep are still exposed, which is exactly why the
    // flag has to be checked: a caller that ignored it would apply a prefix.
    // `command.replay` asserts on `complete` rather than trusting anyone.
    try std.testing.expectEqual(recorder.max_records, s.records.len);

    // takeFrame resets, so the next frame starts clean.
    c.gp0(0x60FF0000);
    c.gp0(xy(0x10, 0x10));
    c.gp0(0x00080008);
    c.drain();
    try std.testing.expect(c.gpu.sink.rec.takeFrame().complete);
}
```

- [x] **Step 2: Write the payload-capacity test**

```zig
test "Stream: exceeding the payload capacity marks the frame incomplete" {
    var c = try StreamCase.init(std.testing.allocator);
    defer c.deinit();
    c.fullArea();

    // A full-VRAM upload is 262,144 words; three of them overrun the
    // 524,288-word payload buffer.
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        c.gp0(0xA0000000);
        c.gp0(xy(0, 0));
        c.gp0(0x00000000); // w = h = 0 -> the whole 1024x512 axis extent
        var i: usize = 0;
        while (i < 262_144) : (i += 1) {
            c.gp0(0xA5A50000 | (@as(u32, @truncate(i)) & 0xFFFF));
        }
    }
    c.drain();

    try std.testing.expect(!c.gpu.sink.rec.takeFrame().complete);
}
```

- [x] **Step 3: Run, gate, commit**

```bash
zig build test -Dtest-filter="Stream:"
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig fmt ps1-core/tests/gpu_stream_test.zig
git commit -am "test(gpu): an overflowed frame reports incomplete, not short

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 7: `ps1-golden stream-verify` — the real-game gate

Several thousand frames of real-game boot, checked frame by frame against full VRAM. `ps1-golden` already owns workload discovery from `games/*/*.cue`, the multi-`FILE` skip rule, per-region BIOS selection, `.sbi` sidecars and `--filter`/`--instructions`; this reuses all of it.

**Files:**
- Modify: `build.zig` (point `golden_exe` at `record_core_mod`)
- Modify: `ps1-golden/src/main.zig`

**Interfaces:**
- Consumes: `record_core_mod`, `Recorder.arm/takeFrame`, `command.replay`.
- Produces: `zig build trace-golden -- stream-verify [--filter=…] [--instructions=…]`,
  and in `main.zig`: `Mode`, `loadMachine`, `StreamResult`, `Failure`, `runStreamVerify`,
  `firstDiff`, `dumpCommand`, `reportStream`.

- [x] **Step 1: Point ps1-golden at the recording core module**

**Replace** `build.zig:56` — do not add a second import. `golden_exe` already has
`addImport("ps1_core", core_mod)`, and a second import under the same name is an
error, not an override:

```zig
-   golden_exe.root_module.addImport("ps1_core", core_mod);
+   golden_exe.root_module.addImport("ps1_core", record_core_mod);
```

Leave `golden_test`'s module on `core_mod` — it tests `golden.zig`'s serializer and has no use for the recorder. The core is now compiled a fourth time; that is the cost of the comptime seam.

- [x] **Step 2: Confirm `capture`/`verify` are unaffected**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

Expected: still green, because `Recorder.enabled` defaults to false. **This is the check that the runtime arm flag was worth having.** If a golden moves here, the sink is not behaviour-neutral and Task 1 has a bug.

- [x] **Step 3: Extract the shared machine setup**

`runWorkload` (`main.zig:130-188`) does BIOS load, cue/bin/sbi load and `setDisc` before its sampling loop. Lift lines `:141-160` verbatim into

```zig
/// BIOS, disc image, cue and LibCrypt sidecar. Shared by `runWorkload` and
/// `runStreamVerify`; the two differ only in what they do with the machine.
fn loadMachine(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_path: []const u8,
    bus: *ps1.memory.Bus,
) !void {
    const bios = try std.Io.Dir.cwd().readFileAlloc(io, bios_path, a, .limited(1 << 20));
    defer a.free(bios);
    if (bios.len != 512 * 1024) return error.BadBiosSize;
    @memcpy(bus.bios[0..], bios);

    if (wl.cue_path) |cue_path| {
        const cue_text = try std.Io.Dir.cwd().readFileAlloc(io, cue_path, a, .limited(1 << 20));
        const bin_path = try std.fmt.allocPrint(a, "{s}.bin", .{cue_path[0 .. cue_path.len - 4]});
        const bin_bytes = try std.Io.Dir.cwd().readFileAlloc(io, bin_path, a, .limited(900 * 1024 * 1024));
        var d = ps1.disc.Disc.initFromCue(cue_text, bin_bytes);

        // A LibCrypt disc without its `.sbi` never gets past its own
        // protection check, so a run without one records a loop, not a boot.
        const sbi_path = try std.fmt.allocPrint(a, "{s}.sbi", .{cue_path[0 .. cue_path.len - 4]});
        if (std.Io.Dir.cwd().readFileAlloc(io, sbi_path, a, .limited(1 << 20))) |sbi| {
            d.setSbi(sbi);
        } else |_| {}

        bus.cdrom.setDisc(d);
    }
}
```

and call it from `runWorkload` in place of those lines. No behaviour change; run `verify` again to confirm before moving on.

- [x] **Step 4: Widen the mode**

```zig
const Mode = enum { capture, verify, stream_verify };
```

Replace `Options.capture: bool` with `mode: Mode`. In `parseArgs`:

```zig
    const mode = it.next() orelse return error.MissingMode;
    var opts = Options{ .mode = if (std.mem.eql(u8, mode, "capture"))
        .capture
    else if (std.mem.eql(u8, mode, "verify"))
        .verify
    else if (std.mem.eql(u8, mode, "stream-verify"))
        .stream_verify
    else
        return error.UnknownMode };
```

Update `usage`:

```zig
const usage =
    \\usage: ps1-golden <capture|verify|stream-verify> [options]
    \\
    \\  capture         rewrite the machine-state goldens
    \\  verify          diff machine state against the goldens
    \\  stream-verify   replay each frame's recorded GP0 command stream into a
    \\                  shadow VRAM and require full-VRAM equality with the
    \\                  software rasterizer
    \\
    \\  --filter=<substring>    only run workloads whose key contains this
    \\  --instructions=<n>      instructions per workload (default 600000000)
    \\  --interval=<n>          instructions between samples (default 2500000)
    \\  --bios=<path>           override the auto-selected BIOS
    \\
;
```

and replace `if (opts.capture)` in `main` with a switch. `--interval` is ignored by `stream-verify`, which samples per frame; say so in the usage line if it reads ambiguously.

- [x] **Step 5: Write `runStreamVerify` and its reporting**

```zig
const StreamResult = struct {
    frames: usize,
    /// The largest single-frame record and payload counts seen. Printed on
    /// success as well as failure: it is the only measurement we have of
    /// whether recorder.max_records and max_payload_words are sized right,
    /// and Phase B sizes its Metal buffers off it.
    peak_records: usize,
    peak_payload: usize,
    failure: ?Failure,
};

const Failure = struct {
    frame: usize,
    instr: u64,
    reason: enum { overflow, pixels },
    diff_pixels: usize = 0,
    first_x: usize = 0,
    first_y: usize = 0,
    want: u16 = 0,
    got: u16 = 0,
};

const Diff = struct { pixels: usize, index: usize, want: u16, got: u16 };

/// The equality fast path is load-bearing, not a micro-optimisation. This runs
/// once per emulated FRAME — on the order of 25,000 frames across the ten
/// workloads — and the counting loop below cannot vectorise: it carries a
/// dependency and an early-exit branch, so it is ~10^10 scalar compares on top
/// of a replay that already doubles every rasterisation. `std.mem.eql` lowers
/// to a vectorised memcmp and covers the case that holds on every frame except
/// the failing one.
fn firstDiff(want: *const ps1.gpu.Vram, got: *const ps1.gpu.Vram) ?Diff {
    if (std.mem.eql(u16, &want.data, &got.data)) return null;

    var found: ?Diff = null;
    var count: usize = 0;
    for (want.data, got.data, 0..) |w, g, i| {
        if (w == g) continue;
        count += 1;
        if (found == null) found = .{ .pixels = 0, .index = i, .want = w, .got = g };
    }
    if (found) |*d| {
        d.pixels = count;
        return d.*;
    }
    return null;
}

/// One flat, greppable line per record. When this fires it IS the debugging
/// session, the same way `verify`'s per-region attribution is.
fn dumpCommand(cmd: ps1.gpu.command.Command) void {
    std.debug.print(
        "      {s: <28} op={x:0>2} tr={d} val={x:0>8} clut={x:0>4} tpage={x:0>4} " ++
            "x={d} y={d} x2={d} y2={d} w={d} h={d} " ++
            "v0=({d},{d},{d},{d},{x:0>6}) v1=({d},{d},{d},{d},{x:0>6}) v2=({d},{d},{d},{d},{x:0>6})\n",
        .{
            @tagName(cmd.kind), cmd.opcode, cmd.transparent, cmd.value, cmd.clut, cmd.tpage,
            cmd.x,              cmd.y,      cmd.x2,          cmd.y2,    cmd.w,    cmd.h,
            cmd.v[0].x,         cmd.v[0].y, cmd.v[0].u,      cmd.v[0].v, cmd.v[0].color,
            cmd.v[1].x,         cmd.v[1].y, cmd.v[1].u,      cmd.v[1].v, cmd.v[1].color,
            cmd.v[2].x,         cmd.v[2].y, cmd.v[2].u,      cmd.v[2].v, cmd.v[2].color,
        },
    );
}

fn runStreamVerify(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_path: []const u8,
    opts: Options,
) !StreamResult {
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);
    try loadMachine(a, io, wl, bios_path, bus);

    bus.gpu.sink.rec.arm();

    // The shadow starts where the rasterizer's VRAM starts: all zeros, default
    // drawing environment. Every mutation from then on arrives through the
    // stream, so the two stay in step for the WHOLE run rather than being
    // resynced per frame — which is what makes a divergence attributable to
    // the frame that caused it instead of to the frame that noticed it.
    const shadow = try a.create(ps1.gpu.Vram);
    shadow.* = .{};
    var shadow_env: ps1.gpu.Regs.DrawingEnv = .{};

    var result = StreamResult{
        .frames = 0,
        .peak_records = 0,
        .peak_payload = 0,
        .failure = null,
    };

    var prev_vblank = false;
    var press_idx: usize = 0;
    var i: u64 = 0;
    while (i < opts.instructions) : (i += 1) {
        if (i % press_period == 0) {
            bus.sio.setButtons(press_seq[press_idx]);
            press_idx = (press_idx + 1) % press_seq.len;
        }
        if (i % press_period == press_hold) bus.sio.setButtons(released);

        cpu.step();

        const vblank = bus.gpu.is_vblank;
        defer prev_vblank = vblank;
        if (!vblank or prev_vblank) continue;

        // The stream aliases the recorder's storage and is valid only until
        // emulation resumes, so it is consumed here, before the next step().
        const s = bus.gpu.sink.rec.takeFrame();
        result.frames += 1;
        result.peak_records = @max(result.peak_records, s.records.len);
        result.peak_payload = @max(result.peak_payload, s.payload.len);

        if (!s.complete) {
            result.failure = .{ .frame = result.frames, .instr = i, .reason = .overflow };
            return result;
        }

        ps1.gpu.command.replay(s, shadow, &shadow_env);

        if (firstDiff(&bus.gpu.vram, shadow)) |d| {
            std.debug.print("  {s: <22} frame {d}: {d} records (first 64 shown)\n", .{
                wl.key, result.frames, s.records.len,
            });
            for (s.records[0..@min(s.records.len, 64)]) |cmd| dumpCommand(cmd);
            result.failure = .{
                .frame = result.frames,
                .instr = i,
                .reason = .pixels,
                .diff_pixels = d.pixels,
                .first_x = d.index % 1024,
                .first_y = d.index / 1024,
                .want = d.want,
                .got = d.got,
            };
            return result;
        }
    }
    return result;
}

/// Returns true when the workload failed.
fn reportStream(key: []const u8, r: StreamResult) bool {
    if (r.failure) |f| {
        switch (f.reason) {
            .overflow => std.debug.print(
                "  {s: <22} OVERFLOW @ frame {d} (instr {d}) — raise recorder.max_records / max_payload_words\n",
                .{ key, f.frame, f.instr },
            ),
            .pixels => std.debug.print(
                "  {s: <22} DIVERGED @ frame {d} (instr {d}): {d} px, first ({d},{d}) raster={x:0>4} replay={x:0>4}\n",
                .{ key, f.frame, f.instr, f.diff_pixels, f.first_x, f.first_y, f.want, f.got },
            ),
        }
        return true;
    }
    std.debug.print("  {s: <22} {d} frames   peak {d} rec / {d} payload   OK\n", .{
        key, r.frames, r.peak_records, r.peak_payload,
    });
    return false;
}
```

Note the `defer prev_vblank = vblank;` inside the loop body: it runs at the end of every iteration, including the `continue`, which is the point.

In `main`'s workload loop, before the `runWorkload` call:

```zig
        if (opts.mode == .stream_verify) {
            const sr = runStreamVerify(wa, init.io, wl, bios_path, opts) catch |err| {
                std.debug.print("  {s: <22} ERROR {s}\n", .{ wl.key, @errorName(err) });
                failures += 1;
                continue;
            };
            if (reportStream(wl.key, sr)) failures += 1;
            continue;
        }
```

The existing `if (failures != 0) return error.TraceDivergence;` at the end already makes the process exit non-zero.

- [x] **Step 6: Run the gate**

```bash
# Cheap smoke first — bios-only reaches the BIOS boot screen, which exercises
# fills, uploads, rectangles and the logo's textured polygons.
zig build trace-golden -Doptimize=ReleaseFast -- \
  stream-verify --filter=bios-only --instructions=60000000

# Then the real thing: all ten workloads, production budget.
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
```

Expected: every workload OK, several thousand frames in total. **Record the per-workload frame counts and peak record/payload figures in the commit message, and the wall clock of the full run with them.** `stream-verify` is strictly more expensive than `verify` — it rasterizes everything twice and compares a megabyte per frame — and it lands in Task 9's final gate, so its runtime needs to be a known number rather than a surprise. Time it with `/usr/bin/time -p`.

**If a workload reports `overflow`:** that is real data, not a test bug. Raise the offending capacity in `recorder.zig` to the next power of two above the observed peak, note the game and the figure in the commit message, and re-run.

**If a workload reports a pixel divergence:** narrow with `--filter=<workload> --instructions=<just past the failing frame>` and read the record dump. Likely causes in order: an effect reaching VRAM without a sink call (grep `gp0.zig` and `gpu.zig` for `vram.` and `draw_env.` again — the closure argument above is the checklist); a record whose fields do not round-trip a value the renderer used; an ordering inversion between `latch_texpage` and its draw.

- [x] **Step 7: Commit**

```bash
zig fmt build.zig ps1-golden/src/main.zig
git add build.zig ps1-golden/src/main.zig
git commit -F - <<'MSG'
feat(golden): add stream-verify, a per-frame command-stream equivalence gate

Boots every workload with the recorder armed, replays each frame's GP0
command stream into a shadow VRAM carried across the whole run, and
requires full-VRAM equality with the software rasterizer.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 8: The PeterLemon ROMs replay too

The spec's Phase A gate is "the PeterLemon ROMs **and** several thousand frames of real-game boot". Task 7 delivered the second half. The PL ROMs are the first half, and they are worth having separately: they draw deliberately pathological geometry that no commercial game emits.

**Files:**
- Modify: `build.zig` (the `rom_suites` loop gets a per-suite core module)
- Modify: `ps1-core/tests/peterlemon_test.zig`

**Interfaces:**
- Consumes: `record_core_mod`, `vram_compare.expectVramEqual`, `Recorder.arm/takeFrame`, `command.replay`.
- Produces: `runPlTest` additionally asserting stream equivalence, and a private
  `stepWithStreamCheck(bus, cpu, count, shadow, env, prev_vblank) !void`.

- [x] **Step 1: Give the ROM suites the recording core module**

In `build.zig`'s `rom_suites` loop, both `skip_t` and `t` currently do
`root_module.addImport("ps1_core", core_mod)`. Change both to `record_core_mod`. The JA suite gains an unused recorder, which is 6.5 MB inside a heap-allocated `Bus` and no branches it does not take — not worth a second module to avoid.

- [x] **Step 2: Replay each PL ROM's frames**

In `peterlemon_test.zig`, add the import and the stepping helper:

```zig
const expectVramEqual = @import("vram_compare.zig").expectVramEqual;

/// Steps `count` instructions, draining and replaying the recorded stream at
/// every vblank edge. The shadow is carried across the whole test — BIOS boot
/// included — so a divergence is attributable to the frame that caused it.
fn stepWithStreamCheck(
    bus: *Bus,
    cpu: *Cpu,
    count: u64,
    shadow: *ps1_core.gpu.Vram,
    shadow_env: *ps1_core.gpu.Regs.DrawingEnv,
    prev_vblank: *bool,
) !void {
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        cpu.step();
        const vblank = bus.gpu.is_vblank;
        defer prev_vblank.* = vblank;
        if (!vblank or prev_vblank.*) continue;

        const s = bus.gpu.sink.rec.takeFrame();
        try std.testing.expect(s.complete);
        ps1_core.gpu.command.replay(s, shadow, shadow_env);
    }
}
```

In `runPlTest`, right after `var cpu = Cpu.init(bus);`:

```zig
    const shadow = try allocator.create(ps1_core.gpu.Vram);
    defer allocator.destroy(shadow);
    shadow.* = .{};
    var shadow_env: ps1_core.gpu.Regs.DrawingEnv = .{};
    var prev_vblank = false;
    bus.gpu.sink.rec.arm();
```

Replace the two `while (… ) : (…) { cpu.step(); }` loops (the 25M-cycle BIOS boot and the `max_cycles` run) with:

```zig
    try stepWithStreamCheck(bus, &cpu, 25_000_000, shadow, &shadow_env, &prev_vblank);
    // … cpu.loadExe(exe_data) … unchanged …
    try stepWithStreamCheck(bus, &cpu, max_cycles, shadow, &shadow_env, &prev_vblank);

    // The last frame is unfinished — the cycle budget does not land on a
    // vblank edge — so drain and apply its tail before comparing.
    const tail = bus.gpu.sink.rec.takeFrame();
    try std.testing.expect(tail.complete);
    ps1_core.gpu.command.replay(tail, shadow, &shadow_env);

    // Stronger than the ratchet below: the ratchet compares a 320x224 display
    // window reduced to 5 bits against a per-test floor, this compares all
    // 1024x512.
    try expectVramEqual(&bus.gpu.vram, shadow);
```

Leave `countReferenceMatches`, the floor logic and `PS1_UPDATE_GOLDENS` handling exactly as they are — the stream check is an addition, not a replacement, and the floors must not move.

- [x] **Step 3: Run the suite**

```bash
zig build test-roms-pl -Doptimize=ReleaseFast
```

Expected: green, with the same per-test match percentages printed as before. `cpu.loadExe` sideloads a PS-EXE and does not touch VRAM, so the shadow stays in step across it; if a test fails at exactly the load point, that assumption is wrong and `loadExe` needs checking for a VRAM write.

Also confirm `zig build test` still passes — the suite compile-checks and self-skips there, and it now compiles against a different core module.

- [x] **Step 4: Commit**

```bash
zig fmt build.zig ps1-core/tests/peterlemon_test.zig
git add build.zig ps1-core/tests/peterlemon_test.zig
git commit -F - <<'MSG'
test(gpu): replay the PeterLemon ROMs' command streams against full VRAM

The PL ROMs draw deliberately pathological geometry no commercial game
emits, and the full-VRAM equality here is a stronger check than the
320x224 5-bit ratchet they were already gating.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 9: Documentation and the closing gate

**Files:**
- Modify: `CLAUDE.md`

- [x] **Step 1: Update `CLAUDE.md`**

Three edits:

1. **Quick commands table** — add a row after the `trace-golden` one:

   ```
   | `zig build trace-golden -- stream-verify` | Boots every workload with the GP0 recorder armed, replays each frame's command stream into a shadow VRAM, and requires full-VRAM equality with the software rasterizer. The Phase A gate for the Metal renderer's command stream. Run it `-Doptimize=ReleaseFast`. |
   ```

2. **Repository layout** — add `command.zig`, `recorder.zig` and `sink.zig` to the `gpu/` block, and `gpu_stream_test` + `vram_compare` to the tests line.

   **Fix the test counts rather than incrementing the ones already written**, which are stale on both sides. `zig build test` runs **13** artifacts today — 9 `unit_test_files`, `golden_test`, `capi_test`, and the two ROM suites' compile-check-and-skip binaries — not the "eleven" `build.zig:100-101` claims and not the "9 unit-test files" the CLAUDE.md quick-commands row claims. After this phase it is **14**. `ps1-core/tests` then holds **ten** unit-test files, but `unit_test_files` in `build.zig` stays at **nine**, because `stream_test` is registered separately (it needs the recording core module). Update the `build.zig:100-101` comment in the same commit, and state the number as "14 test binaries" in the quick-commands row so the two cannot drift apart again.

3. **A new subsection under the GPU cheat-sheet**, in the file's voice:

   > **`gp0.zig` cannot reach the renderer.** Every VRAM-visible effect goes
   > through `gpu/sink.zig`, which builds a fixed-stride `command.Command` and
   > hands it to `command.execute` — the one function that turns a record into
   > an effect, used by the live path and by replay alike. The seam exists so
   > the Metal backend can consume an ordered stream, and the structural
   > guarantee is the missing import: a primitive that does not appear in the
   > sink does not draw. **The stream must carry the implicit texpage latch,
   > not just E1–E6** — `e1_texpage_mask` covers bits 5-6, the
   > semi-transparency mode, so a textured polygon's blend mode comes from its
   > own tpage word; rectangles do not latch. Which core module records is a
   > comptime build option (`gpu_sink`), `.software` everywhere except
   > `ps1-golden` and the two ROM suites; `Recorder.enabled` is a further
   > runtime flag, so `capture`/`verify` stay at today's speed. The
   > recorder's capacities (`max_records`, `max_payload_words`) are sized off
   > the peaks `stream-verify` prints — it prints them on success too, for
   > exactly that reason.

- [x] **Step 2: Run the complete gate one final time**

```bash
zig fmt build.zig ps1-core/src ps1-core/tests ps1-golden/src
zig build
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build test-roms-ja -Doptimize=ReleaseFast          # expect 12/17, the same five
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build capi-lib
```

Every one green (JA at its documented 12/17). `capi-lib` is in the list because `capi_core_mod` gained an options import in Task 1 and nothing since has built it.

- [x] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -F - <<'MSG'
docs: record the GP0 sink seam and the stream-verify gate

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Verification (the phase's exit criteria)

Phase A is done when all of these hold on a clean tree:

| Check | Command | Expected |
|---|---|---|
| Unit tests | `zig build test` | green, including the new `Stream:` suite |
| No rendered-output change | `zig build test-roms-pl -Doptimize=ReleaseFast` | green against the **unchanged** Phase 0 floors |
| No core behaviour change | `zig build trace-golden -Doptimize=ReleaseFast -- verify` | every workload OK against the **unchanged** Phase 0 goldens |
| Stream lossless, synthetic | `zig build test -Dtest-filter="Stream:"` | green |
| Stream lossless, ROMs | `zig build test-roms-pl -Doptimize=ReleaseFast` | full-VRAM equality per ROM |
| Stream lossless, real games | `zig build trace-golden -Doptimize=ReleaseFast -- stream-verify` | every workload OK, several thousand frames total |
| Hardware conformance unmoved | `zig build test-roms-ja -Doptimize=ReleaseFast` | 12/17, the same five |
| The macOS ABI still builds | `zig build capi-lib` | builds |
| No perf regression | Task 1 Step 8's timing | within ~3% of `HEAD` before Phase A |

The three "unchanged" entries are the load-bearing ones: **Phase A recaptures nothing.** A moved golden or a moved floor is a bug in the seam, not a baseline that needs updating.

---

## What Phase A deliberately does not do

- No Metal, no shader, no `.metal` file.
- No C ABI change. `ps1_take_frame_stream` and its ownership rule are Phase B; `ps1-capi` still compiles `.software` and the macOS app is untouched.
- No fixture format and no Swift loader — that is Phase A2, which the spec sequences next and which will need `command.Command` to be serializable. It already is: `extern struct`, no pointers, payload out of line.
- No hazard detection, no render-pass splitting, no batching. Those are properties of a GPU backend and have no meaning against a serial software replay.
- No change to `renderer.zig`, `color.zig`, `vram.zig`, `registers.zig` or `primitive.zig`.
