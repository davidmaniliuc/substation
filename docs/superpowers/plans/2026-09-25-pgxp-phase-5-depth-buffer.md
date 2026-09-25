# PGXP Phase 5 — Depth Buffer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DuckStation-parity PGXP depth buffer (`depth_buffer`, `transparent_depth`, `disable_2d`), as one exact integer 1/W test evaluated identically by the Zig software rasterizer and the Metal backend, with every existing gate unchanged and still strict.

**Architecture:** Each vertex carries an absolute integer reciprocal depth `iz = round(2^30 / W)` in the command record; 1/W is affine in screen space, so the existing exact `interp` produces it per pixel and the test is `iz >= stored`. `gp0` decides everything — which polygons test and write, when to clear (a `clear_depth` record), and `disable_2d` — through a new `gpu/depth.zig`, so a Metal replay only follows the record. The software plane is a `u32` array in `Vram`; the Metal plane is a third `.r32Uint` attachment that is MEMORYLESS while the setting is off and `.private` while it is on.

**Tech Stack:** Zig 0.16.0 (`ps1-core`, `ps1-golden`, `ps1-capi`, `ps1-trace`), Metal Shading Language (`ps1-macos/Shaders`), Swift + swift-testing (`ps1-macos`), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-09-25-pgxp-phase-5-depth-buffer-design.md`

---

## Global Constraints

Exact values from the spec and `CLAUDE.md`. Every task implicitly includes this section.

- **Zig 0.16.0**; run everything from the repo root.
- **With PGXP off, or with the depth buffer off, every output byte is unchanged BY CONSTRUCTION.** No vertex resolves (or no polygon is marked), so no `flag_depth_*` bit and no `clear_depth` record is produced. `trace-golden -- verify`, `trace-golden -- stream-verify`, Gate 1 and Gate 2 cannot move. **If one moves it is a gating bug, never a behaviour change** — never run `trace-golden -- capture`. (`verify` exits 1 on the pre-existing orphaned `mgs` golden; that line is not this plan's.)
- **`iz = round(2^30 / W)`, clamped to `[1, 2^30]`, and 0 when `W` is not `> 0`.** Computed once per vertex in `gp0` in `f64`, carried in the record, never re-derived.
- **The test is `iz >= stored`; the plane clears to 0 (infinitely far).** A depth is written only where the COLOUR is written.
- **Each depth bit is ANDed with "all three `iz` non-zero" at the point of use**, never substituted for it — the same structural guarantee Phase 4 keeps for `rw`.
- **The clear threshold is the constant 4096 in W units.** No per-game table.
- **The three settings default OFF and are NOT assigned in `Bus.init`.** Each folds in the master flag in exactly one accessor; `pgxpTransparentDepth` also folds in `pgxp_depth_buffer`.
- **Record: `Vertex` 24 -> 28 bytes, `Command` 108 -> 120, `Kind` count 17 -> 18 (`clear_depth` APPENDED), `.p1fx` version 3 -> 4, `Ps1PrimInstance` 51 -> 54 ints.**
- **No `f32` in either rasterizer's inner loop.** `f32` W appears only in `gp0`/`depth.zig`, before the sink.
- **Fill-rule bias stays `-1`; nothing in this plan touches coverage.**
- **`synthetic-primitives.p1fx` frames are APPENDED, never reordered.**
- **`zig fmt` before every commit.** Doc comments state reasoning; no thinking-out-loud comments; no copy-pasted blocks — extract the helper.
- **`trace-golden`, `fixtures` and `ps1-trace` runs are `-Doptimize=ReleaseFast`.**
- **`pkill -x Substation` before `ps1-macos/test.sh`**, which needs `zig build capi-lib` and `zig build metallib` first. The tell of the suite's known GPU-load crash is `Failing tests:` with zero `✘` lines — re-run before believing it.
- **Every guard test must be verified to FAIL against the naive implementation** before the implementation lands; each task names the mutation.
- **Never `git push`.** Commit locally to `master`, one commit per task.

## Review Focus

Inputs the spec implies but no spec-listed test exercises, most likely to bite first. Each has its test in the owning task.

1. **Toggling the depth buffer mid-game** (or toggling PGXP while it is on) must not leave a stale plane that hides the next frame's geometry, in EITHER rasterizer — the reset must be a recorded `clear_depth`, not a silent `@memset`, or Metal keeps the stale plane. → Task 4.
2. **A game re-writing E3/E4 with the SAME value every frame** must not clear depth mid-frame. → Task 5.
3. **Extreme W** — below 1, above 65535, NaN, negative — must produce an `iz` in `[1, 2^30]` or 0, never overflow `interp`. → Task 5.
4. **`ps1_reset` must preserve the three settings**, as it already does for the other six. → Task 4.
5. **A resync while depth is on** must adopt the software plane, or the first frame after it tests against zeros and `PS1_LIVE_DIFF` blames the renderer. → Task 10.

---

## File Structure

| File | Responsibility after this phase |
|---|---|
| `ps1-core/src/gpu/depth.zig` (NEW) | `reciprocal`, `decide`, `averageW`, `State` — every depth decision that is arithmetic, with no GP0 knowledge |
| `ps1-core/src/gpu/command.zig` | `Vertex.iz`; `flag_depth_test`/`flag_depth_write`; `Kind.clear_depth`; `execute` decodes `Renderer.DepthTest` |
| `ps1-core/src/gpu/sink.zig` | the three triangle entry points carry `iz`; `drawTriangle` gains `flags`; `clearDepth` |
| `ps1-core/src/gpu/gp0.zig` | the three setting mirrors, `depth_state`, `depthBits`, the E3/E4 clear, `disable_2d` in `unify`, `snapToIntegers` |
| `ps1-core/src/gpu/renderer.zig` | `DepthTest`; the test/write in `rasterizeTriangle`; `putPixel` returns whether it wrote |
| `ps1-core/src/gpu/vram.zig` | `depth` plane; resets in `maskedWrite`/`fillRectangle`; `clearDepth` |
| `ps1-core/src/gpu/gpu.zig` | re-exports `depth` |
| `ps1-core/src/memory.zig` | three fields, three accessors, three setters, `mirrorDepth` |
| `ps1-capi/include/ps1.h`, `ps1-capi/src/root.zig` | record mirror; three setters; `ps1_copy_depth`; reset snapshot |
| `ps1-golden/src/{fixture,synthetic_prims,main,pgxp_sweep}.zig` | version 4; frame 8; `--pgxp-on`/sweep force all three; `depth`/`depth_clears` ratchets |
| `ps1-trace/src/main.zig` | the `depth` lockstep knob |
| `ps1-macos/Shaders/{PrimInstance.h,Rasterizer.metal}` | instance fields/bits; `[[color(2)]]`; the test; resets; `ps1_depth_clear_fragment` |
| `ps1-macos/Sources/PS1/{MetalVram,MetalRasterizer,PrimBuilder,PrimEncoders,LiveRenderer,EmulatorRunner,Ps1Core,PgxpSetting,EmulatorViewModel,MetalDisplayView,ContentView,FixtureFile}.swift`, `Sources/PS1App/VideoCommands.swift` | the plane, its encoding, resync, the three settings |
| `ps1-core/tests/{gpu_test,gpu_stream_test}.zig`, `ps1-capi/src/capi_test.zig`, `ps1-golden/src/fixture_test.zig`, `ps1-macos/Tests/PS1Tests/*` | tests |
| `ps1-core/tests/goldens/{fixtures/*.p1fx,pgxp/floors.txt}` | regenerated fixtures; new ratchets |
| `CLAUDE.md`, `.claude/skills/{ps1-pgxp,ps1-gpu-metal}/SKILL.md` | rules |

`gp0.zig` is already 944 lines; `depth.zig` exists so this phase adds call sites there, not logic. `renderer.zig` grows ~30 lines past 616; accepted.

---

### Task 1: The record grows — `iz`, two bits, `clear_depth`, version 4

Pure transport. Nothing produces a non-zero `iz`, a depth bit or a `clear_depth` yet, so no pixel moves.

**Files:**
- Modify: `ps1-core/src/gpu/command.zig` (Kind, flags, Vertex, size asserts, `execute` arm)
- Modify: `ps1-capi/include/ps1.h` (kind enum, count, stride, Vertex, flags), `ps1-capi/src/root.zig` (its stride comptime check near `:519`)
- Modify: `ps1-golden/src/fixture.zig:41-49`
- Modify: `ps1-macos/Shaders/PrimInstance.h`, `ps1-macos/Shaders/Rasterizer.metal:6`
- Modify: `ps1-macos/Sources/PS1/{PrimBuilder,FixtureFile,MetalRasterizer}.swift`
- Test: `ps1-core/tests/gpu_stream_test.zig`, `ps1-macos/Tests/PS1Tests/{FixtureBridgeTests,MetalVramTests,MetalRasterizerTests}.swift`
- Regenerate: `ps1-core/tests/goldens/fixtures/synthetic-{movers,primitives}.p1fx`

**Interfaces:**
- Produces: `command.flag_depth_test: u8 = 1 << 2`, `command.flag_depth_write: u8 = 1 << 3`, `Vertex.iz: i32`, `Kind.clear_depth` (x, y, w, h = the rectangle); C `PS1_GPU_CLEAR_DEPTH` (= 17), `PS1_GPU_FLAG_DEPTH_TEST`, `PS1_GPU_FLAG_DEPTH_WRITE`, `Ps1GpuVertex.iz`; MSL `PS1_PRIM_DEPTH_TEST (1u << 7)`, `PS1_PRIM_DEPTH_WRITE (1u << 8)`, `PS1_PRIM_DEPTH_CLEAR = 10`, `Ps1PrimInstance.iz0/iz1/iz2`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_stream_test.zig`:

```zig
// --- Phase 5 Task 1: the record.

test "Phase5: the record carries iz and two depth bits, and clear_depth is appended" {
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(command.Vertex));
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(command.Command));
    // APPENDED: every existing kind keeps its number, so a version-3 reader's
    // table is a prefix of this one.
    try std.testing.expectEqual(@as(usize, 17), @intFromEnum(command.Kind.clear_depth));
    try std.testing.expectEqual(@as(u8, 1 << 2), command.flag_depth_test);
    try std.testing.expectEqual(@as(u8, 1 << 3), command.flag_depth_write);
}
```

In `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift` change the two `108` to `120`. In `MetalVramTests.swift:79-80` change `4 * 51` to `4 * 54`. Append to `MetalRasterizerTests.swift`, copying the neighbouring `theRecordsPerspectiveBitsReachTheInstance` test's `DrawEnv()` setup verbatim:

```swift
/// The depth bits and the three reciprocals reach the instance. Per bit, for
/// the same reason the perspective test is per bit: a swap would pass a test
/// that only checked "flags != 0".
@Test func theRecordsDepthBitsAndReciprocalsReachTheInstance() throws {
    for (recordBit, instanceBit) in [
        (PS1_GPU_FLAG_DEPTH_TEST, PS1_PRIM_DEPTH_TEST),
        (PS1_GPU_FLAG_DEPTH_WRITE, PS1_PRIM_DEPTH_WRITE),
    ] {
        var cmd = Ps1GpuCommand()
        cmd.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
        cmd.flags = UInt8(recordBit)
        cmd.v.0 = Ps1GpuVertex(x: 0, y: 0)
        cmd.v.1 = Ps1GpuVertex(x: 32, y: 0)
        cmd.v.2 = Ps1GpuVertex(x: 0, y: 32)
        cmd.v.0.iz = 100; cmd.v.1.iz = 200; cmd.v.2.iz = 300
        let inst = try #require(PrimBuilder.triangle(cmd, env: DrawEnv(), kind: Int32(PS1_PRIM_FLAT_TRI)))
        #expect(inst.flags & (PS1_PRIM_DEPTH_TEST | PS1_PRIM_DEPTH_WRITE) == instanceBit)
        #expect((inst.iz0, inst.iz1, inst.iz2) == (100, 200, 300))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `no member named 'clear_depth'`, `no member named 'flag_depth_test'`.

- [ ] **Step 3: Declare the record changes in `command.zig`**

Append `clear_depth,` as the LAST member of `Kind` (after `vram_read_setup`). Beside the two Phase 4 flags:

```zig
/// The depth-buffer pair. Separate bits because a transparent polygon under
/// `transparent_depth` TESTS but never WRITES. Each is ANDed with "all three
/// `iz` non-zero" at the point of use, exactly as the perspective bits are
/// ANDed with `rw`: with PGXP off nothing resolves, every `iz` is 0, and no
/// bit can reach a pixel.
pub const flag_depth_test: u8 = 1 << 2;
pub const flag_depth_write: u8 = 1 << 3;
```

In `Vertex`, after `rw`, replacing the last sentence of `rw`'s comment ("A depth buffer would want absolute W … when something reads it.") with nothing:

```zig
    /// ABSOLUTE reciprocal depth, `round(2^30 / W)` clamped to `[1, 2^30]`,
    /// from `depth.reciprocal`. Zero means no depth. The depth TEST compares
    /// across primitives, where `rw`'s per-primitive normalisation does not
    /// cancel, which is why this is a second field and not `rw` reused.
    iz: i32 = 0,
```

Update the per-kind table comment with `///   clear_depth                  x, y, w, h = the rectangle to reset to far`. Change the comptime asserts to `24 -> 28` and `108 -> 120`. Add an `execute` arm that does nothing yet — Task 2 fills it:

```zig
        // Task 2 gives the software plane something to clear.
        .clear_depth => {},
```

- [ ] **Step 4: Mirror it in `ps1.h` and the capi check**

In `Ps1GpuCommandKind` append `PS1_GPU_CLEAR_DEPTH` after `PS1_GPU_VRAM_READ_SETUP`. `PS1_GPU_KIND_COUNT 18`, `PS1_GPU_COMMAND_STRIDE 120`. In `Ps1GpuVertex` after `rw`:

```c
    /* Absolute reciprocal depth, round(2^30 / W) — see command.zig. Zero means
       no depth. Triangles only, and only while the depth buffer is on. */
    int32_t  iz;
```

Beside the perspective flags:

```c
/* The depth-buffer pair: a transparent polygon under transparent_depth tests
 * but does not write. Each is ANDed with "all three iz non-zero" at use. */
#define PS1_GPU_FLAG_DEPTH_TEST  (1u << 2)
#define PS1_GPU_FLAG_DEPTH_WRITE (1u << 3)
```

`_Static_assert(sizeof(Ps1GpuVertex) == 28, …)`, the command assert's message to "pins 120", and the kind assert to `PS1_GPU_CLEAR_DEPTH + 1 == PS1_GPU_KIND_COUNT`. In `ps1-capi/src/root.zig`, update whichever comptime block compares against `108`/`17` to `120`/`18` (`grep -n "108\|17" ps1-capi/src/root.zig`).

- [ ] **Step 5: Bump the fixture format**

`ps1-golden/src/fixture.zig`: `version: u32 = 4`, `record_stride != 120`, `kind_count != 18`. `ps1-macos/Sources/PS1/FixtureFile.swift:63`: `guard version == 4`.

- [ ] **Step 6: The instance and the builder**

`PrimInstance.h`: add `PS1_PRIM_DEPTH_CLEAR = 10` to the kind enum; beneath `PS1_PRIM_COLOR_PERSPECTIVE`:

```c
#define PS1_PRIM_DEPTH_TEST  (1u << 7) /* record's PS1_GPU_FLAG_DEPTH_TEST */
#define PS1_PRIM_DEPTH_WRITE (1u << 8) /* record's PS1_GPU_FLAG_DEPTH_WRITE */
```

after `int rw0, rw1, rw2;`:

```c
    /* Absolute reciprocal depths, one per vertex — the record's iz, native
       like every field here. A depth test compares ACROSS primitives, so
       these share one scale where rw0..rw2 are normalised per triangle. */
    int iz0, iz1, iz2;
```

`Rasterizer.metal:6`: `4 * 54`. `PrimBuilder.triangle`, after the `rw` line and after the colour-perspective `if`:

```swift
        (inst.iz0, inst.iz1, inst.iz2) = (verts[0].iz, verts[1].iz, verts[2].iz)
```
```swift
        if cmd.flags & UInt8(PS1_GPU_FLAG_DEPTH_TEST) != 0 { inst.flags |= PS1_PRIM_DEPTH_TEST }
        if cmd.flags & UInt8(PS1_GPU_FLAG_DEPTH_WRITE) != 0 { inst.flags |= PS1_PRIM_DEPTH_WRITE }
```

Swift imports `Ps1GpuVertex` with a memberwise initializer naming EVERY field, so adding `iz` breaks each full-memberwise call (`Ps1GpuVertex(x:y:u:v:_pad:color:px:py:rw:)`). Find them with `git grep -n "rw: " -- ps1-macos` and append `, iz: 0` to each; calls using `Ps1GpuVertex()` or `Ps1GpuVertex(x:y:)` are unaffected.

In `MetalRasterizer.swift`'s record switch (`:334`), add `case PS1_GPU_CLEAR_DEPTH: break  // Task 7 encodes it` beside `PS1_GPU_VRAM_READ_SETUP`. `ShadowVram`'s `default:` already ignores it.

- [ ] **Step 7: Regenerate the committed fixtures and verify nothing moved**

```bash
zig fmt ps1-core/src ps1-golden/src ps1-capi/src
zig build test
zig build fixtures -Doptimize=ReleaseFast
cp zig-out/fixtures/synthetic-movers.p1fx zig-out/fixtures/synthetic-primitives.p1fx ps1-core/tests/goldens/fixtures/
zig build test   # fixture_test compares the committed bytes against a fresh build
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build capi-lib && zig build metallib
pkill -x Substation; ps1-macos/test.sh
```

Expected: all pass; the Swift suite's per-frame VRAM hashes are unchanged (only the headers moved).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(pgxp): the record carries an absolute depth, two depth bits and clear_depth

Vertex 24 -> 28, Command 108 -> 120, Kind count 17 -> 18 with clear_depth
APPENDED, .p1fx version 4, Ps1PrimInstance 51 -> 54. Nothing produces a
non-zero iz, a depth bit or a clear_depth yet, so no pixel moves; the two
committed synthetic fixtures are regenerated for the header alone.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The software depth plane, and every VRAM write resets it

**Files:**
- Modify: `ps1-core/src/gpu/vram.zig`, `ps1-core/src/gpu/sink.zig`, `ps1-core/src/gpu/command.zig` (the `clear_depth` arm)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Kind.clear_depth` (Task 1).
- Produces: `Vram.depth: [1024 * 512]u32`; `Vram.clearDepth(x: i32, y: i32, w: i32, h: i32) void`; `Sink.clearDepth(self, vram, env, x: i32, y: i32, w: i32, h: i32) void`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 5 Task 2: every VRAM write resets the depth under it.
//
// A depth buffer that survives a fill, an upload or a copy tests the next 3D
// polygon against geometry the game has since painted over.

fn depthAt(gpu: *Gpu, x: usize, y: usize) u32 {
    return gpu.vram.depth[y * 1024 + x];
}

test "Phase5: a fill resets the depth under it and nowhere else" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    @memset(&gpu.vram.depth, 7);
    _ = gpu.writeGp0(0x02000000, Value.none); // fill, colour 0
    _ = gpu.writeGp0(xy(16, 8), Value.none);
    _ = gpu.writeGp0(xy(16, 4), Value.none); // 16 wide, 4 tall
    _ = gpu.step(100_000);
    try expectEqual(@as(u32, 0), depthAt(&gpu, 16, 8));
    try expectEqual(@as(u32, 0), depthAt(&gpu, 31, 11));
    try expectEqual(@as(u32, 7), depthAt(&gpu, 32, 8));
    try expectEqual(@as(u32, 7), depthAt(&gpu, 16, 12));
}

test "Phase5: an upload resets depth only where the mask let it write" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    @memset(&gpu.vram.depth, 7);
    gpu.vram.data[10 * 1024 + 11] = 0x8000; // pre-masked pixel
    _ = gpu.writeGp0(0xE6000002, Value.none); // check-mask on
    _ = gpu.writeGp0(0xA0000000, Value.none);
    _ = gpu.writeGp0(xy(10, 10), Value.none);
    _ = gpu.writeGp0(xy(2, 1), Value.none); // 2x1
    _ = gpu.writeGp0(0x12341234, Value.none);
    _ = gpu.step(100_000);
    try expectEqual(@as(u32, 0), depthAt(&gpu, 10, 10));
    try expectEqual(@as(u32, 7), depthAt(&gpu, 11, 10)); // refused: kept
}

test "Phase5: a copy resets depth at its destination, wrapping at the VRAM edge" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    @memset(&gpu.vram.depth, 7);
    _ = gpu.writeGp0(0x80000000, Value.none);
    _ = gpu.writeGp0(xy(0, 0), Value.none); // source
    _ = gpu.writeGp0(xy(1022, 5), Value.none); // destination straddles x = 1023
    _ = gpu.writeGp0(xy(4, 1), Value.none);
    _ = gpu.step(100_000);
    try expectEqual(@as(u32, 0), depthAt(&gpu, 1022, 5));
    try expectEqual(@as(u32, 0), depthAt(&gpu, 1023, 5));
    try expectEqual(@as(u32, 0), depthAt(&gpu, 0, 5));
    try expectEqual(@as(u32, 0), depthAt(&gpu, 1, 5));
    try expectEqual(@as(u32, 7), depthAt(&gpu, 2, 5));
    try expectEqual(@as(u32, 7), depthAt(&gpu, 0, 0)); // the SOURCE keeps its depth
}

test "Phase5: clear_depth resets exactly its rectangle, clamped to VRAM" {
    var gpu = Gpu.init();
    @memset(&gpu.vram.depth, 7);
    ps1_core.gpu.command.execute(.{ .kind = .clear_depth, .x = 1020, .y = 510, .w = 100, .h = 100 }, &.{}, &gpu.vram, &gpu.draw_env);
    try expectEqual(@as(u32, 0), depthAt(&gpu, 1023, 511));
    try expectEqual(@as(u32, 0), depthAt(&gpu, 1020, 510));
    try expectEqual(@as(u32, 7), depthAt(&gpu, 1019, 511));
}
```

`gpu_test.zig` puts a `Gpu` on the stack in 57 tests, and this task adds 2 MB to it (about 3.4 MB per test, one test at a time, inside macOS's 8 MB main stack). If `zig build test` reports a stack overflow, change the failing tests to `const gpu = try std.testing.allocator.create(Gpu); defer std.testing.allocator.destroy(gpu); gpu.* = Gpu.init();` — do not shrink the plane.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `no field named 'depth'`.

- [ ] **Step 3: The plane and its resets in `vram.zig`**

After `data`:

```zig
    /// The PGXP depth buffer: one absolute reciprocal depth per VRAM pixel,
    /// 0 = infinitely far. Read only by a depth-tested triangle, so with the
    /// setting off it is written (by the resets below) and never read, and no
    /// pixel can depend on it. Not hashed by `state_hash.zig`, for the reason
    /// the PGXP shadow tables are not: there is no golden for depth-on output.
    depth: [constants.vram_width * constants.vram_height]u32 = [_]u32{0} ** (constants.vram_width * constants.vram_height),
```

In `maskedWrite`, after the store: `self.depth[idx] = 0;` — and extend its doc comment: "It also resets the depth under the pixel: geometry painted over by a transfer is gone, and a later 3D polygon must not test against it. A pixel the mask refuses keeps its depth, as it keeps its colour."

In `fillRectangle`, after `self.data[idx] = color;`: `self.depth[idx] = 0;`.

Add:

```zig
    /// Resets a rectangle of the depth plane to far, clamped to VRAM. The
    /// `clear_depth` record's effect; `gp0` decides when one is due.
    pub fn clearDepth(self: *Vram, x: i32, y: i32, w: i32, h: i32) void {
        const x0: usize = @intCast(std.math.clamp(x, 0, constants.vram_width));
        const x1: usize = @intCast(std.math.clamp(x + w, 0, constants.vram_width));
        const y0: usize = @intCast(std.math.clamp(y, 0, constants.vram_height));
        const y1: usize = @intCast(std.math.clamp(y + h, 0, constants.vram_height));
        if (x0 >= x1) return;
        var yy = y0;
        while (yy < y1) : (yy += 1) @memset(self.depth[Vram.index(x0, yy)..Vram.index(x1, yy)], 0);
    }
```

- [ ] **Step 4: The record's effect and the sink entry**

`command.zig`, replacing the Task 1 placeholder arm:

```zig
        .clear_depth => vram.clearDepth(cmd.x, cmd.y, cmd.w, cmd.h),
```

`sink.zig`, after `copyRect`:

```zig
    pub fn clearDepth(self: *Sink, vram: *Vram, env: *DrawingEnv, x: i32, y: i32, w: i32, h: i32) void {
        self.submit(vram, env, .{ .kind = .clear_depth, .x = x, .y = y, .w = w, .h = h });
    }
```

- [ ] **Step 5: Verify the mask test can fail**

Temporarily move `self.depth[idx] = 0;` in `maskedWrite` ABOVE the `mask.check` early return. The upload test must FAIL on `(11, 10)`. Restore.

- [ ] **Step 6: Run everything**

```bash
zig fmt ps1-core/src ps1-core/tests
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
```

Expected: all pass; nothing reads the plane, so no golden can move.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(pgxp): the software depth plane, reset under every VRAM write

A u32 per VRAM pixel, 0 = far. Fill, upload and a copy's destination reset
it where they write colour; a pixel the mask refuses keeps both. clear_depth
resets its rectangle. Nothing reads the plane yet.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The software depth test

**Files:**
- Modify: `ps1-core/src/gpu/renderer.zig` (`DepthTest`, `putPixel`, `rasterizeTriangle`, the three triangle entry points), `ps1-core/src/gpu/command.zig` (`execute`)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Vertex.iz`, the two flags (Task 1); `Vram.depth` (Task 2).
- Produces: `Renderer.DepthTest = struct { iz: [3]i32 = .{0,0,0}, check: bool = false, write: bool = false }`; `Renderer.putPixel(...) bool`; `Renderer.drawTriangle/drawShadedTriangle/drawTexturedTriangle(..., depth: DepthTest)` as the LAST parameter.

- [ ] **Step 1: Write the failing tests**

Append to `gpu_test.zig`:

```zig
// --- Phase 5 Task 3: the test.
//
// Two triangles crossing each other: A is near on the left and far on the
// right, B the reverse, so each wins half the overlap. Drawn in either order
// the picture must be the same — which is the whole point of a depth buffer
// and false of painter's order.

const command = ps1_core.gpu.command;

fn depthTri(color: u32, xs: [3]i16, ys: [3]i16, izs: [3]i32, flags: u8, transparent: bool) command.Command {
    var c: command.Command = .{ .kind = .draw_triangle, .value = color, .flags = flags, .transparent = @intFromBool(transparent) };
    for (0..3) |i| c.v[i] = .{ .x = xs[i], .y = ys[i], .px = @as(i32, xs[i]) << 16, .py = @as(i32, ys[i]) << 16, .iz = izs[i] };
    return c;
}

const both = command.flag_depth_test | command.flag_depth_write;
// A: near (large iz) at x=10, far at x=90. B: the mirror image.
const tri_a = depthTri(0x001F, .{ 10, 90, 10 }, .{ 10, 50, 90 }, .{ 4000, 1000, 4000 }, both, false);
const tri_b = depthTri(0x7C00, .{ 90, 10, 90 }, .{ 10, 50, 90 }, .{ 4000, 1000, 4000 }, both, false);

fn drawAll(gpu: *Gpu, cmds: []const command.Command) void {
    for (cmds) |c| command.execute(c, &.{}, &gpu.vram, &gpu.draw_env);
}

test "Phase5: interpenetrating triangles give one picture in either draw order" {
    var one = Gpu.init();
    setupGpu(&one);
    drawAll(&one, &.{ tri_a, tri_b });
    var two = Gpu.init();
    setupGpu(&two);
    drawAll(&two, &.{ tri_b, tri_a });
    try std.testing.expectEqualSlices(u16, &one.vram.data, &two.vram.data);
    // And both colours survive: without the test the second draw wins everywhere.
    try expectEqual(@as(u16, 0x001F), one.vram.data[50 * 1024 + 20]);
    try expectEqual(@as(u16, 0x7C00), one.vram.data[50 * 1024 + 80]);
}

test "Phase5: without the bits the same pair is painter's order" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    var a = tri_a;
    var b = tri_b;
    a.flags = 0;
    b.flags = 0;
    drawAll(&gpu, &.{ a, b });
    try expectEqual(@as(u16, 0x7C00), gpu.vram.data[50 * 1024 + 20]);
}

test "Phase5: a test-only polygon is hidden behind a nearer one and writes nothing" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    const far_only = depthTri(0x03E0, .{ 10, 90, 10 }, .{ 10, 50, 90 }, .{ 100, 100, 200 }, command.flag_depth_test, false);
    drawAll(&gpu, &.{ tri_a, far_only });
    try expectEqual(@as(u16, 0x001F), gpu.vram.data[50 * 1024 + 20]); // hidden
    const before = gpu.vram.depth;
    const near_only = depthTri(0x03E0, .{ 10, 90, 10 }, .{ 10, 50, 90 }, .{ 9000, 9000, 9100 }, command.flag_depth_test, false);
    drawAll(&gpu, &.{near_only});
    try expectEqual(@as(u16, 0x03E0), gpu.vram.data[50 * 1024 + 20]); // passes
    try std.testing.expectEqualSlices(u32, &before, &gpu.vram.depth); // but writes nothing
}

test "Phase5: a mask-refused pixel keeps its depth" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    gpu.vram.data[50 * 1024 + 20] = 0x8000;
    _ = gpu.writeGp0(0xE6000002, Value.none); // check-mask
    _ = gpu.step(1000);
    drawAll(&gpu, &.{tri_a});
    try expectEqual(@as(u32, 0), gpu.vram.depth[50 * 1024 + 20]);
    try std.testing.expect(gpu.vram.depth[50 * 1024 + 21] != 0);
}

test "Phase5: a bit without three depths tests nothing" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    drawAll(&gpu, &.{tri_a});
    var b = tri_b;
    b.v[1].iz = 0; // one vertex without a depth: the bit alone must not act
    drawAll(&gpu, &.{b});
    try expectEqual(@as(u16, 0x7C00), gpu.vram.data[50 * 1024 + 20]);
}
```

A textured-hole case is covered in Metal by Task 7; in software the hole returns before `putPixel`, which is the same code path the mask test pins.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL on the colour assertions — the second triangle wins everywhere.

- [ ] **Step 3: `DepthTest` and `putPixel`'s result**

In `renderer.zig`, inside `Renderer` above `putPixel`:

```zig
    /// A triangle's depth test, decoded from the record by `command.execute`.
    /// The renderer cannot import `command.zig` (it imports this file), so it
    /// never sees the record's encoding — plain values, as with `rw`.
    ///
    /// `check` arrives already ANDed with "all three `iz` non-zero".
    pub const DepthTest = struct {
        iz: [3]i32 = .{ 0, 0, 0 },
        check: bool = false,
        write: bool = false,
    };
```

`putPixel` returns `bool`: `return false;` at the clip and the two bounds returns and at the check-mask return, `return true;` after the store. Doc comment: "Returns whether the pixel was written — the depth plane is written only where colour is." Every other caller discards it with `_ =` (`drawRectangle`, `drawLine`, `drawShadedLine`, `drawTexturedRectangle`).

- [ ] **Step 4: The test in `rasterizeTriangle`**

Add `depth: DepthTest` as the last parameter. Replace the pixel body:

```zig
                if ((w0 | w1 | w2) >= 0 and
                    (w0 >= q_bias_scale or w1 >= q_bias_scale or w2 >= q_bias_scale))
                {
                    const px16: i16 = @intCast(px);
                    const py16: i16 = @intCast(py);
                    // The bias is a coverage device only -- attributes, the
                    // depth included, are interpolated from the true
                    // barycentric numerators.
                    const u0 = w0 - bias0;
                    const u1 = w1 - bias1;
                    const u2 = w2 - bias2;
                    const out = Shader.shade(shader_ctx, u0, u1, u2, area, px16, py16, allow_transparency);
                    if (out.draw) {
                        // 1/W is affine in screen space, so the affine
                        // interpolant IS the per-pixel reciprocal depth — the
                        // same expression `ps1_interp` evaluates in Metal.
                        // `px`/`py` are inside VRAM here: the walk box is
                        // clamped to it, so the index is valid.
                        const idx = Vram.index(@intCast(px), @intCast(py));
                        const iz: u32 = if (depth.check) @intCast(interp(u0, u1, u2, area, depth.iz[0], depth.iz[1], depth.iz[2])) else 0;
                        if (!depth.check or iz >= vram.depth[idx]) {
                            if (putPixel(vram, env, px16, py16, out.color, out.is_transparent) and depth.check and depth.write) {
                                vram.depth[idx] = iz;
                            }
                        }
                    }
                }
```

Each of `drawTriangle`, `drawShadedTriangle`, `drawTexturedTriangle` gains `depth: DepthTest` last and passes it through.

- [ ] **Step 5: Decode it in `execute`**

In `command.zig`:

```zig
/// The record's depth half, in the shape the renderer takes. `check` is the
/// bit ANDed with "all three `iz` non-zero" — never the bit alone.
fn depthOf(cmd: Command) Renderer.DepthTest {
    const all = cmd.v[0].iz != 0 and cmd.v[1].iz != 0 and cmd.v[2].iz != 0;
    return .{
        .iz = .{ cmd.v[0].iz, cmd.v[1].iz, cmd.v[2].iz },
        .check = all and (cmd.flags & flag_depth_test) != 0,
        .write = (cmd.flags & flag_depth_write) != 0,
    };
}
```

and pass `depthOf(cmd)` as the last argument of the three triangle arms. Fix every direct `Renderer.draw*Triangle` call in `ps1-core/tests/gpu_test.zig` by appending `, .{}` (`grep -n "Renderer.draw.*Triangle(" ps1-core/tests`).

- [ ] **Step 6: Verify the guard can fail**

Change `.check = all and …` to `.check = (cmd.flags & flag_depth_test) != 0`: "a bit without three depths tests nothing" must FAIL. Restore.

- [ ] **Step 7: Run everything**

```bash
zig fmt ps1-core/src ps1-core/tests
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(pgxp): the software depth test

iz is interpolated with the existing exact interp -- 1/W is affine in
screen space -- and tested iz >= stored. The depth is written only where
putPixel wrote colour, so a clipped, mask-refused or hole pixel leaves it.
The bit is ANDed with all three iz present, never used alone.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The three settings, and a toggle that resets through the stream

**Files:**
- Modify: `ps1-core/src/memory.zig`, `ps1-core/src/gpu/gp0.zig` (mirrors, `depth_state`, `resetDepth`), `ps1-capi/src/root.zig`, `ps1-capi/include/ps1.h`
- Create: `ps1-core/src/gpu/depth.zig` (only `State` in this task; Task 5 adds the rest)
- Modify: `ps1-core/src/gpu/gpu.zig` (`pub const depth = @import("depth.zig");`)
- Test: `ps1-capi/src/capi_test.zig`, `ps1-core/tests/gpu_stream_test.zig`

**Interfaces:**
- Consumes: `Sink.clearDepth` (Task 2).
- Produces: `Bus.pgxp_depth_buffer/pgxp_transparent_depth/pgxp_disable_2d: bool`; `Bus.pgxpDepthBuffer()/pgxpTransparentDepth()/pgxpDisable2d() bool`; `Bus.setPgxpDepthBuffer/setPgxpTransparentDepth/setPgxpDisable2d(bool)`; `Gp0Engine.pgxp_depth_buffer/pgxp_transparent_depth/pgxp_disable_2d: bool`, `Gp0Engine.depth_state: depth.State`, `Gp0Engine.resetDepth(sink, vram, env)`; `depth.State{ last_w: f32 = far_w, dirty: bool = false }` with `jump(avg: f32) bool` and `cleared()`, `depth.far_w = 65535`, `depth.clear_threshold = 4096`; C `ps1_set_pgxp_depth_buffer`, `ps1_set_pgxp_transparent_depth`, `ps1_set_pgxp_disable_2d`, `ps1_copy_depth(const Ps1*, uint32_t*)`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig`, following the colour-correction test at `:895`:

```zig
test "Phase5: the three depth settings default off and fold in the master flag" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expect(!h.cpu.bus.pgxp_depth_buffer);
    try std.testing.expect(!h.cpu.bus.pgxp_transparent_depth);
    try std.testing.expect(!h.cpu.bus.pgxp_disable_2d);

    capi.ps1_set_pgxp_depth_buffer(h, 1);
    capi.ps1_set_pgxp_transparent_depth(h, 1);
    capi.ps1_set_pgxp_disable_2d(h, 1);
    try std.testing.expect(!h.cpu.bus.pgxpDepthBuffer()); // PGXP itself is off
    try std.testing.expect(!h.cpu.bus.gpu.gp0.pgxp_transparent_depth);

    capi.ps1_set_pgxp(h, 1);
    try std.testing.expect(h.cpu.bus.gpu.gp0.pgxp_depth_buffer);
    try std.testing.expect(h.cpu.bus.gpu.gp0.pgxp_transparent_depth);
    try std.testing.expect(h.cpu.bus.gpu.gp0.pgxp_disable_2d);

    // transparent_depth is a SUB-flag: meaningless without the buffer.
    capi.ps1_set_pgxp_depth_buffer(h, 0);
    try std.testing.expect(!h.cpu.bus.gpu.gp0.pgxp_transparent_depth);
}

test "Phase5: ps1_reset keeps the three depth settings" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_set_pgxp_depth_buffer(h, 1);
    capi.ps1_set_pgxp_transparent_depth(h, 1);
    capi.ps1_set_pgxp_disable_2d(h, 1);
    capi.ps1_reset(h);
    try std.testing.expect(h.cpu.bus.pgxp_depth_buffer);
    try std.testing.expect(h.cpu.bus.pgxp_transparent_depth);
    try std.testing.expect(h.cpu.bus.pgxp_disable_2d);
}
```

Append to `gpu_stream_test.zig`, which records:

```zig
// --- Phase 5 Task 4: a toggle resets the plane THROUGH THE STREAM.
//
// A silent @memset would clear the software plane and leave Metal's stale, so
// the next frame's depth tests would disagree between the two rasterizers.

test "Phase5: turning the depth buffer on records a whole-plane clear_depth" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    @memset(&case.gpu.vram.depth, 7);
    case.gpu.gp0.pgxp_depth_buffer = false;
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, false, false);
    const rec = lastRecord(case.gpu, .clear_depth);
    try std.testing.expectEqual(@as(i32, 1024), rec.w);
    try std.testing.expectEqual(@as(i32, 512), rec.h);
    try std.testing.expectEqual(@as(u32, 0), case.gpu.vram.depth[0]);
}

test "Phase5: re-applying the same setting records nothing" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, false, false);
    const before = case.gpu.sink.rec.count;
    // The macOS runner re-applies every setting every frame.
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, false, false);
    try std.testing.expectEqual(before, case.gpu.sink.rec.count);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test 2>&1 | tail -20` — Expected: FAIL, unknown members.

- [ ] **Step 3: `depth.zig`, first half**

```zig
//! The PGXP depth buffer's decisions that are arithmetic: the reciprocal, which
//! polygons test, the average-depth jump that starts a new pass. Nothing here
//! knows GP0; `gp0.zig` asks and records the answers, so a Metal replay only
//! ever follows a record.

const std = @import("std");

/// The far end of the GTE's Z range, and the value "no depth tested since the
/// last clear" is stored as — DuckStation's `m_last_depth_z = 1.0`.
pub const far_w: f32 = 65535;
/// DuckStation's default `gpu_pgxp_depth_clear_threshold`, in W units.
pub const clear_threshold: f32 = 4096;

/// What `gp0` remembers between polygons.
pub const State = struct {
    /// The previous depth-tested polygon's average W.
    last_w: f32 = far_w,
    /// A polygon has tested since the last clear — the only case in which a
    /// drawing-area change has anything to clear.
    dirty: bool = false,

    /// Records a depth-tested polygon's average W; true when it sits at least
    /// `clear_threshold` FURTHER than the previous one. Signed on purpose: a
    /// jump toward the camera is a nearer object, a jump away is a new pass.
    /// `last_w` becomes this polygon's either way, as DuckStation's does.
    pub fn jump(self: *State, avg: f32) bool {
        const due = avg - self.last_w >= clear_threshold;
        self.last_w = avg;
        self.dirty = true;
        return due;
    }

    pub fn cleared(self: *State) void {
        self.* = .{};
    }
};
```

Re-export it in `gpu.zig`: `pub const depth = @import("depth.zig");`.

- [ ] **Step 4: The mirrors and the reset in `gp0.zig`**

After the `pgxp_color_correction` mirror, add the import `const depth = @import("depth.zig");` and:

```zig
    /// Mirrors of `Bus.pgxpDepthBuffer()`, `Bus.pgxpTransparentDepth()` and
    /// `Bus.pgxpDisable2d()` — master flag already folded in, set only by
    /// `setDepthMirrors`. Default FALSE, as on `Bus`.
    pgxp_depth_buffer: bool = false,
    pgxp_transparent_depth: bool = false,
    pgxp_disable_2d: bool = false,

    depth_state: depth.State = .{},

    /// Sets the three mirrors, and resets the plane when the depth buffer's
    /// EFFECTIVE value changes. The reset is a recorded `clear_depth`, not a
    /// silent @memset: Metal keeps its own plane, and only the stream reaches
    /// it. Re-applying an unchanged value records nothing, which matters
    /// because the macOS runner re-applies every setting every frame.
    pub fn setDepthMirrors(self: *Gp0Engine, sink: *Sink, vram: *Vram, env: *Regs.DrawingEnv, buffer: bool, transparent: bool, disable_2d: bool) void {
        const changed = buffer != self.pgxp_depth_buffer;
        self.pgxp_depth_buffer = buffer;
        self.pgxp_transparent_depth = transparent;
        self.pgxp_disable_2d = disable_2d;
        if (changed) self.resetDepth(sink, vram, env);
    }

    fn resetDepth(self: *Gp0Engine, sink: *Sink, vram: *Vram, env: *Regs.DrawingEnv) void {
        self.depth_state.cleared();
        sink.clearDepth(vram, env, 0, 0, constants.vram_width, constants.vram_height);
    }
```

(Import `constants` if `gp0.zig` does not already.)

- [ ] **Step 5: `Bus`**

After `pgxp_color_correction`:

```zig
    /// The PGXP depth buffer and its two sub-settings, all OFF by default —
    /// DuckStation's defaults. Default-OFF, so NOT assigned in `init`.
    pgxp_depth_buffer: bool = false,
    pgxp_transparent_depth: bool = false,
    pgxp_disable_2d: bool = false,
```

After `setPgxpColorCorrection`:

```zig
    pub inline fn pgxpDepthBuffer(self: *const Self) bool {
        return self.pgxp_enabled and self.pgxp_depth_buffer;
    }

    /// A SUB-flag: it has nothing to act on without the depth buffer, so both
    /// fold in here and nowhere else.
    pub inline fn pgxpTransparentDepth(self: *const Self) bool {
        return self.pgxpDepthBuffer() and self.pgxp_transparent_depth;
    }

    pub inline fn pgxpDisable2d(self: *const Self) bool {
        return self.pgxp_enabled and self.pgxp_disable_2d;
    }

    pub fn setPgxpDepthBuffer(self: *Self, enabled: bool) void {
        self.pgxp_depth_buffer = enabled;
        self.mirrorDepth();
    }

    pub fn setPgxpTransparentDepth(self: *Self, enabled: bool) void {
        self.pgxp_transparent_depth = enabled;
        self.mirrorDepth();
    }

    pub fn setPgxpDisable2d(self: *Self, enabled: bool) void {
        self.pgxp_disable_2d = enabled;
        self.mirrorDepth();
    }

    fn mirrorDepth(self: *Self) void {
        self.gpu.gp0.setDepthMirrors(&self.gpu.sink, &self.gpu.vram, &self.gpu.draw_env, self.pgxpDepthBuffer(), self.pgxpTransparentDepth(), self.pgxpDisable2d());
    }
```

In `setPgxp`, after the colour mirror line: `self.mirrorDepth();`.

- [ ] **Step 6: The C ABI**

`root.zig`, after `ps1_set_pgxp_color_correction`:

```zig
/// The PGXP depth buffer. OFF by default, gated on `ps1_set_pgxp`. A change
/// resets the plane through the command stream, so Metal's resets with it.
pub export fn ps1_set_pgxp_depth_buffer(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpDepthBuffer(enabled != 0);
}

/// Transparent polygons test (never write) the depth buffer. OFF by default;
/// acts only while the depth buffer is on.
pub export fn ps1_set_pgxp_transparent_depth(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpTransparentDepth(enabled != 0);
}

/// A primitive whose positions resolved but which lacks depths is drawn at
/// integer positions. OFF by default, gated on `ps1_set_pgxp`.
pub export fn ps1_set_pgxp_disable_2d(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpDisable2d(enabled != 0);
}

/// The software depth plane, 1024x512 u32 — what a Metal resync adopts beside
/// `ps1_copy_vram`, under the same frame.
pub export fn ps1_copy_depth(h: *const Handle, dst: [*]u32) void {
    const src = h.cpu.bus.gpu.vram.depth;
    @memcpy(dst[0..src.len], src[0..]);
}
```

Extend `ps1_reset`'s `pgxp_was` struct with `depth: bool, transparent_depth: bool, disable_2d: bool` from the three raw fields, and restore them before `setPgxp(pgxp_was.on)` as raw field writes (the final `setPgxp` mirrors them). Declare the four functions in `ps1.h` beside `ps1_set_pgxp_color_correction`, each with a one-line comment matching the Zig doc.

- [ ] **Step 7: Verify the "changed" guard can fail**

Replace `if (changed) self.resetDepth(...)` with an unconditional call: "re-applying the same setting records nothing" must FAIL. Restore.

- [ ] **Step 8: Run everything and commit**

```bash
zig fmt ps1-core/src ps1-capi/src ps1-core/tests
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
git add -A
git commit -m "feat(pgxp): pgxp_depth_buffer, transparent_depth, disable_2d -- default off

Each folds in the master flag in one accessor; transparent_depth also folds
in the depth buffer. A change of the effective depth-buffer value resets the
plane with a RECORDED clear_depth, so Metal's plane resets with the
software one; re-applying an unchanged value records nothing, because the
macOS runner re-applies settings every frame. ps1_reset keeps all three.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `gp0` decides — which polygons test, and when to clear

**Files:**
- Modify: `ps1-core/src/gpu/depth.zig` (second half), `ps1-core/src/gpu/gp0.zig` (`depthBits`, every polygon site, the E3/E4 hook, three counters), `ps1-core/src/gpu/sink.zig` (triangle signatures)
- Test: `ps1-core/tests/pgxp_test.zig` (depth.zig arithmetic), `ps1-core/tests/gpu_stream_test.zig` (records)

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: `depth.iz_one: i32 = 1 << 30`; `depth.reciprocal(w: f32) i32`; `depth.Decision{ check: bool, write: bool }`; `depth.decide(ws: []const f32, transparent: bool, enabled: bool, transparent_depth: bool) Decision`; `depth.averageW(ws: []const f32) f32`; `PgxpStats.depth_tested`, `PgxpStats.depth_clears`; `Sink.drawTriangle(..., is_transparent, iz: [3]i32, flags: u8)`; `Sink.drawShadedTriangle(..., rw, flags, iz: [3]i32)`; `Sink.drawTexturedTriangle(..., rw, flags, iz: [3]i32)`.

- [ ] **Step 1: Write the failing arithmetic tests**

Append to `ps1-core/tests/pgxp_test.zig`:

```zig
// --- Phase 5 Task 5: depth.zig.
const depth = @import("ps1_core").gpu.depth;

test "Phase5: reciprocal is 2^30/W, clamped, and 0 without a depth" {
    try std.testing.expectEqual(@as(i32, 1 << 20), depth.reciprocal(1024));
    try std.testing.expectEqual(@as(i32, 16384), depth.reciprocal(65536));
    // Extreme inputs: never out of [1, 2^30], never a trap.
    try std.testing.expectEqual(depth.iz_one, depth.reciprocal(0.25));
    try std.testing.expectEqual(@as(i32, 1), depth.reciprocal(1e30));
    try std.testing.expectEqual(@as(i32, 0), depth.reciprocal(0));
    try std.testing.expectEqual(@as(i32, 0), depth.reciprocal(-5));
    try std.testing.expectEqual(@as(i32, 0), depth.reciprocal(std.math.nan(f32)));
}

test "Phase5: decide — 3D opaque tests and writes, 2D and transparent do not" {
    const on = true;
    try std.testing.expectEqual(depth.Decision{ .check = true, .write = true }, depth.decide(&.{ 100, 200, 300 }, false, on, false));
    try std.testing.expectEqual(depth.Decision{}, depth.decide(&.{ 100, 100, 100 }, false, on, false)); // flat: 2D
    try std.testing.expectEqual(depth.Decision{}, depth.decide(&.{ 100, 0, 300 }, false, on, false)); // a vertex without depth
    try std.testing.expectEqual(depth.Decision{}, depth.decide(&.{ 100, 200, 300 }, true, on, false)); // transparent
    try std.testing.expectEqual(depth.Decision{ .check = true, .write = false }, depth.decide(&.{ 100, 200, 300 }, true, on, true));
    try std.testing.expectEqual(depth.Decision{}, depth.decide(&.{ 100, 200, 300 }, false, false, false)); // setting off
    // A quad whose first three agree and whose fourth differs is 3D.
    try std.testing.expect(depth.decide(&.{ 100, 100, 100, 150 }, false, on, false).check);
}

test "Phase5: the jump clears only moving AWAY by at least 4096" {
    var s: depth.State = .{};
    try std.testing.expect(!s.jump(1000)); // first after a clear: last is far
    try std.testing.expect(!s.jump(5095)); // +4095
    try std.testing.expect(s.jump(9191)); // +4096
    try std.testing.expect(!s.jump(10)); // toward the camera: never
    try std.testing.expectEqual(@as(f32, 65535), depth.averageW(&.{ 70000, 70000, 70000 }));
}
```

- [ ] **Step 2: Write the failing record tests**

Append to `gpu_stream_test.zig`. Helpers first:

```zig
// --- Phase 5 Task 5: what gp0 records.

fn depthCase() !StreamCase {
    var case = try StreamCase.init(std.testing.allocator);
    case.fullArea();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, false, false);
    return case;
}

/// GP0 opcode `op` (a flat triangle, 0x20 opaque or 0x22 transparent) whose
/// three vertices resolve with the given depths.
fn flatTri(c: *StreamCase, op: u8, zs: [3]f32) void {
    const ws = [3]u32{ xy(0x10, 0x10), xy(0x40, 0x10), xy(0x28, 0x40) };
    _ = c.gpu.writeGp0(@as(u32, op) << 24, Value.none);
    for (ws, zs) |w, z| _ = c.gpu.writeGp0(w, subPixelDepth(w, 0.25, 0.25, z));
    c.drain();
}
```

Then:

```zig
test "Phase5: a 3D opaque triangle records both bits and three iz" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 100, 200, 300 });
    const rec = lastRecord(case.gpu, .draw_triangle);
    try std.testing.expectEqual(command.flag_depth_test | command.flag_depth_write, rec.flags);
    try std.testing.expectEqual(ps1_core.gpu.depth.reciprocal(100), rec.v[0].iz);
    try std.testing.expect(rec.v[1].iz != 0 and rec.v[2].iz != 0);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.depth_tested);
}

test "Phase5: equal depths are 2D and record neither bit" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 200, 200, 200 });
    const rec = lastRecord(case.gpu, .draw_triangle);
    try std.testing.expectEqual(@as(u8, 0), rec.flags);
    try std.testing.expectEqual(@as(i32, 0), rec.v[0].iz);
}

test "Phase5: transparent records nothing, then test-only under transparent_depth" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x22, .{ 100, 200, 300 });
    try std.testing.expectEqual(@as(u8, 0), lastRecord(case.gpu, .draw_triangle).flags);
    case.gpu.gp0.setDepthMirrors(&case.gpu.sink, &case.gpu.vram, &case.gpu.draw_env, true, true, false);
    flatTri(&case, 0x22, .{ 100, 200, 300 });
    try std.testing.expectEqual(command.flag_depth_test, lastRecord(case.gpu, .draw_triangle).flags);
}

test "Phase5: both halves of a quad record the same bits" {
    var case = try depthCase();
    defer case.deinit();
    // GP0 0x28: vertices 0..2 at one depth, vertex 3 different. Judged per
    // HALF, the first half would be 2D; judged as the quad, both are 3D.
    const ws = [4]u32{ xy(0x10, 0x10), xy(0x40, 0x10), xy(0x10, 0x40), xy(0x40, 0x40) };
    const zs = [4]f32{ 100, 100, 100, 300 };
    _ = case.gpu.writeGp0(0x28000000, Value.none);
    for (ws, zs) |w, z| _ = case.gpu.writeGp0(w, subPixelDepth(w, 0.25, 0.25, z));
    case.drain();
    const records = case.gpu.sink.rec.records[0..case.gpu.sink.rec.count];
    var n: usize = 0;
    for (records) |r| if (r.kind == .draw_triangle) {
        try std.testing.expectEqual(command.flag_depth_test | command.flag_depth_write, r.flags);
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "Phase5: a drawing-area CHANGE after a depth write records a whole-plane clear" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 100, 200, 300 });
    const before = case.gpu.sink.rec.count;
    case.gp0(0xE3000000 | (10 << 10)); // top-left moves
    case.drain();
    const rec = lastRecord(case.gpu, .clear_depth);
    try std.testing.expectEqual(@as(i32, 1024), rec.w);
    try std.testing.expect(case.gpu.sink.rec.count > before);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.depth_clears);
}

test "Phase5: re-writing E3 with its CURRENT value records no clear" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 100, 200, 300 });
    const clears = case.gpu.gp0.pgxp.depth_clears;
    case.gp0(0xE3000000 | (case.gpu.draw_env.area_top_left & 0xFFFFF));
    case.drain();
    try std.testing.expectEqual(clears, case.gpu.gp0.pgxp.depth_clears);
}

test "Phase5: a jump of 4096 AWAY clears the drawing area; toward does not" {
    var case = try depthCase();
    defer case.deinit();
    flatTri(&case, 0x20, .{ 100, 200, 300 }); // avg 200
    flatTri(&case, 0x20, .{ 4296, 4296, 4297 }); // avg ~4296: +4096
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.depth_clears);
    const rec = lastRecord(case.gpu, .clear_depth);
    try std.testing.expectEqual(@as(i32, 1024), rec.w); // fullArea's drawing area
    flatTri(&case, 0x20, .{ 10, 20, 30 });
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.depth_clears);
}

test "Phase5: with the setting off nothing is recorded" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.fullArea();
    case.gpu.gp0.pgxp_enabled = true;
    flatTri(&case, 0x20, .{ 100, 200, 300 });
    try std.testing.expectEqual(@as(u8, 0), lastRecord(case.gpu, .draw_triangle).flags);
    case.gp0(0xE3000000 | (10 << 10));
    case.drain();
    for (case.gpu.sink.rec.records[0..case.gpu.sink.rec.count]) |r| try std.testing.expect(r.kind != .clear_depth);
}
```

`case.fullArea()` exists (the Phase 4 tests use it).

- [ ] **Step 3: Run to verify they fail**

Run: `zig build test 2>&1 | tail -20` — Expected: FAIL.

- [ ] **Step 4: `depth.zig`, second half**

```zig
/// One absolute reciprocal-depth unit: `reciprocal(1) == iz_one`. 2^30 keeps
/// `interp`'s numerator under 3 * 2^29 * 2^30 < 2^61, inside i64/long at every
/// internal resolution, and resolves the far end (W = 65535) to 1 part in 16k.
pub const iz_one: i32 = 1 << 30;

/// `round(2^30 / w)`, clamped to `[1, 2^30]`; 0 when `w` carries no depth
/// (not > 0, which also catches NaN). f64 because this is computed once per
/// vertex on the CPU and a quantisation step saved here costs nothing.
pub fn reciprocal(w: f32) i32 {
    if (!(w > 0)) return 0;
    const q = @round(@as(f64, iz_one) / @as(f64, w));
    return std.math.clamp(std.math.lossyCast(i32, q), 1, iz_one);
}

pub const Decision = struct { check: bool = false, write: bool = false };

/// DuckStation's rule, over one POLYGON's vertices (four for a quad, so both
/// halves agree): it tests only if every vertex carries a depth and the depths
/// are not all equal — a polygon at one depth is a 2D overlay drawn with a
/// projected position — and it is opaque or `transparent_depth` is on. A
/// transparent polygon never writes. Compared on W, not on the quantised iz.
pub fn decide(ws: []const f32, transparent: bool, enabled: bool, transparent_depth: bool) Decision {
    if (!enabled) return .{};
    for (ws) |w| if (!(w > 0)) return .{};
    const flat = for (ws[1..]) |w| {
        if (w != ws[0]) break false;
    } else true;
    if (flat) return .{};
    if (transparent and !transparent_depth) return .{};
    return .{ .check = true, .write = !transparent };
}

/// The polygon's mean W, capped at the far end as DuckStation's is.
pub fn averageW(ws: []const f32) f32 {
    var sum: f32 = 0;
    for (ws) |w| sum += w;
    return @min(sum / @as(f32, @floatFromInt(ws.len)), far_w);
}
```

- [ ] **Step 5: Sink signatures**

`drawTriangle` gains `iz: [3]i32, flags: u8` after `is_transparent`, writes `.flags = flags` and each vertex's `.iz`. `drawShadedTriangle` and `drawTexturedTriangle` gain `iz: [3]i32` after `flags` and write each vertex's `.iz`. Doc line on each: "`iz` and the depth bits in `flags` — see `Gp0Engine.depthBits`. All-zero `iz` tests nothing."

- [ ] **Step 6: `depthBits` and the polygon sites in `gp0.zig`**

Add three counters to `PgxpStats`: `depth_tested: u64 = 0` ("polygons that took the depth test"), `depth_clears: u64 = 0` ("`clear_depth` records `gp0` decided: area changes and depth jumps; setting toggles are not counted"). Then:

```zig
    /// One POLYGON's depth half: the four-vertex answer for a quad, so its two
    /// halves always agree. Emits the depth-jump clear itself, before the
    /// polygon it precedes, because the record order IS the effect order.
    const DepthBits = struct { iz: [4]i32 = .{ 0, 0, 0, 0 }, flags: u8 = 0 };

    fn depthBits(self: *Gp0Engine, sink: *Sink, vram: *Vram, env: *Regs.DrawingEnv, pts: []const Primitive.Point, transparent: bool) DepthBits {
        var ws: [4]f32 = undefined;
        for (pts, 0..) |p, i| ws[i] = p.w;
        const d = depth.decide(ws[0..pts.len], transparent, self.pgxp_depth_buffer, self.pgxp_transparent_depth);
        if (!d.check) return .{};
        self.pgxp.depth_tested += 1;
        if (self.depth_state.jump(depth.averageW(ws[0..pts.len]))) {
            self.pgxp.depth_clears += 1;
            const r = drawingArea(env);
            sink.clearDepth(vram, env, r.x, r.y, r.w, r.h);
        }
        var out: DepthBits = .{ .flags = command.flag_depth_test | if (d.write) command.flag_depth_write else 0 };
        for (pts, 0..) |p, i| out.iz[i] = depth.reciprocal(p.w);
        return out;
    }

    fn depthBitsTextured(self: *Gp0Engine, sink: *Sink, vram: *Vram, env: *Regs.DrawingEnv, vs: []const Primitive.TexturedPoint, transparent: bool) DepthBits {
        var pts: [4]Primitive.Point = undefined;
        for (vs, 0..) |v, i| pts[i] = v.point;
        return self.depthBits(sink, vram, env, pts[0..vs.len], transparent);
    }

    /// GP0(E3)/(E4)'s drawing area as a rectangle, INCLUSIVE bounds made
    /// exclusive — the region DuckStation's `only_drawing_area` clear covers.
    fn drawingArea(env: *const Regs.DrawingEnv) struct { x: i32, y: i32, w: i32, h: i32 } {
        const x0: i32 = @intCast(env.area_top_left & 0x3FF);
        const y0: i32 = @intCast((env.area_top_left >> 10) & 0x3FF);
        const x1: i32 = @intCast(env.area_bot_right & 0x3FF);
        const y1: i32 = @intCast((env.area_bot_right >> 10) & 0x3FF);
        return .{ .x = x0, .y = y0, .w = x1 - x0 + 1, .h = y1 - y0 + 1 };
    }
```

At every polygon site, AFTER `unify`/`unifyTextured` (so a snapped primitive has `w = 0` and tests nothing), compute `const z = self.depthBits(sink, vram, draw_env, &pts, is_transp);` (or `depthBitsTextured(..., &vs, is_transp)`) ONCE per polygon, and pass the per-triangle slice. For the two quad halves `iz` is `.{ z.iz[0], z.iz[1], z.iz[2] }` and `.{ z.iz[1], z.iz[2], z.iz[3] }`. The flags are ORed: `d.flags | z.flags` on the shaded/textured sites, `z.flags` on the flat ones. The flat triangle site becomes:

```zig
        const z = self.depthBits(sink, vram, draw_env, &pts, is_transp);
        sink.drawTriangle(vram, draw_env, pts[0], pts[1], pts[2], color, is_transp, .{ z.iz[0], z.iz[1], z.iz[2] }, z.flags);
```

Sites: `drawFlatTriangle`, `drawFlatQuad`, `drawShadedTriangle`, `drawShadedQuad`, `drawTexturedTriangleCommand`, `drawTexturedQuadCommand`, `drawShadedTexturedTriangle`, `drawShadedTexturedQuad` — eight.

- [ ] **Step 7: The drawing-area clear**

In `execute`, replace the `0xE1...0xE6` arm:

```zig
            0xE1...0xE6 => {
                if (opcode == 0xE3 or opcode == 0xE4) self.clearOnAreaChange(opcode, sink, vram, draw_env);
                sink.setDrawEnv(vram, draw_env, opcode, self.cmd_buffer[0]);
            },
```

and add:

```zig
    /// DuckStation clears the WHOLE plane when the drawing area changes and
    /// something has tested since the last clear — in practice once a frame,
    /// at the buffer flip. "Changes" is decided by applying the word to a copy
    /// of the env, so the comparison uses exactly the masking the env does: a
    /// game that re-writes E3/E4 with the same value every frame clears nothing.
    fn clearOnAreaChange(self: *Gp0Engine, opcode: u8, sink: *Sink, vram: *Vram, env: *Regs.DrawingEnv) void {
        if (!self.pgxp_depth_buffer or !self.depth_state.dirty) return;
        var next = env.*;
        next.update(opcode, self.cmd_buffer[0]);
        if (next.area_top_left == env.area_top_left and next.area_bot_right == env.area_bot_right) return;
        self.pgxp.depth_clears += 1;
        self.depth_state.cleared();
        sink.clearDepth(vram, env, 0, 0, constants.vram_width, constants.vram_height);
    }
```

- [ ] **Step 8: Fix callers and verify guards can fail**

Update the direct `Sink.draw*Triangle` callers in `ps1-golden/src/*.zig` and tests (`grep -rn "sink.drawTriangle\|drawShadedTriangle(\|drawTexturedTriangle(" ps1-golden ps1-core/tests`), passing `.{0,0,0}`/`0` for the new arguments.

Mutations, each must FAIL a named test, then restore: (a) drop the `next.area_* ==` early return → "re-writing E3 with its CURRENT value"; (b) decide per HALF instead of per quad → "both halves of a quad"; (c) `>=` → `>` in `jump` → the +4096 case.

- [ ] **Step 9: Run everything and commit**

```bash
zig fmt ps1-core/src ps1-core/tests ps1-golden/src
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
git add -A
git commit -m "feat(pgxp): gp0 decides which polygons test depth, and when to clear

DuckStation's rules: a polygon tests if every vertex carries a depth and
they differ (is_3d), and it is opaque or transparent_depth is on; a
transparent one never writes. A quad is judged across all four vertices.
Clears: the whole plane on a drawing-area CHANGE after a test, the drawing
area on an average-W jump of >= 4096 away. Arithmetic in depth.zig; gp0
records the answers. PGXP off or depth off: no bit, no record.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `disable_2d`, and one snap helper instead of three copies

**Files:**
- Modify: `ps1-core/src/gpu/gp0.zig` (`unifySpace`, `unifyTexturedSpace`, `PgxpStats.flat_2d_primitives`)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Gp0Engine.pgxp_disable_2d` (Task 4).
- Produces: `PgxpStats.flat_2d_primitives: u64`; `fn snapToIntegers(pt: *Primitive.Point, keep_depth: bool) void`.

- [ ] **Step 1: Write the failing test**

Append to `gpu_test.zig`, beside `"PGXP: unify clears the depth term on a mixed primitive"`:

```zig
// DuckStation's `valid_w == false` path: a primitive whose positions resolved
// but which lacks a depth is 2D, and under disable_2d is drawn at integers.
// `unify` already snaps a primitive with an UNRESOLVED vertex; this is the one
// new case — resolved everywhere, depth missing somewhere.
test "Phase5: disable_2d snaps a resolved primitive that lacks depths" {
    var gpu = Gpu.init();
    gpu.gp0.pgxp_enabled = true;
    var pts = [_]Primitive.Point{ pt(10, 10), pt(60, 12), pt(14, 58) };
    for (&pts) |*p| {
        p.resolved = true;
        p.px += 0x4000;
    }
    pts[0].w = 8.0; // one depth, two missing
    gpu.gp0.unifyForTest(&pts);
    try expectEqual(@as(i32, 10 << 16) + 0x4000, pts[0].px); // off: untouched

    gpu.gp0.pgxp_disable_2d = true;
    gpu.gp0.unifyForTest(&pts);
    for (pts) |p| {
        try expectEqual(@as(i32, p.x) << 16, p.px);
        try expectEqual(@as(f32, 0), p.w);
    }
    try expectEqual(@as(u64, 1), gpu.gp0.pgxp.flat_2d_primitives);

    var full = [_]Primitive.Point{ pt(10, 10), pt(60, 12), pt(14, 58) };
    for (&full) |*p| {
        p.resolved = true;
        p.w = 8.0;
    }
    gpu.gp0.unifyForTest(&full);
    try std.testing.expect(full[0].resolved); // every depth present: 3D, kept
}
```

Add a textured twin through `unifyTexturedForTest` with the same shape.

- [ ] **Step 2: Run to verify it fails** — `zig build test`; FAIL, no `flat_2d_primitives`.

- [ ] **Step 3: Implement**

`PgxpStats`: `flat_2d_primitives: u64 = 0` ("resolved primitives lacking a depth, drawn at integers by `disable_2d`").

```zig
    /// Puts one vertex back on the integer grid. `keep_depth` is the thin
    /// rule's case: a depth cannot move a pixel, so a thin primitive keeps
    /// its own. Every other snap has a vertex without one and clears them all.
    fn snapToIntegers(pt: *Primitive.Point, keep_depth: bool) void {
        pt.px = @as(i32, pt.x) << 16;
        pt.py = @as(i32, pt.y) << 16;
        pt.resolved = false;
        if (!keep_depth) pt.w = 0;
    }
```

Rewrite `unifySpace`:

```zig
    fn unifySpace(self: *Gp0Engine, pts: []Primitive.Point) void {
        var any = false;
        var all = true;
        var all_depth = true;
        for (pts) |pt| {
            if (pt.resolved) any = true else all = false;
            if (!(pt.w > 0)) all_depth = false;
        }
        if (any and thinPrimitive(pts)) {
            self.pgxp.thin_primitives += 1;
            // Only the POSITION is snapped — unless it is also mixed, when one
            // vertex has no depth and the mixed rule's reasoning applies.
            for (pts) |*pt| snapToIntegers(pt, all);
            return;
        }
        if (all and !all_depth and self.pgxp_disable_2d) {
            self.pgxp.flat_2d_primitives += 1;
            for (pts) |*pt| snapToIntegers(pt, false);
            return;
        }
        if (!any or all) return;
        self.pgxp.mixed_primitives += 1;
        for (pts) |*pt| snapToIntegers(pt, false);
    }
```

`unifyTexturedSpace` becomes the same shape over `&v.point`, keeping its existing `pts` copy for `thinPrimitive`. The inline comments from `01066de` in both functions are replaced by the helper's doc comment.

- [ ] **Step 4: Verify it can fail** — drop `!all_depth and` from the condition: the "every depth present: 3D, kept" assertion must FAIL. Restore.

- [ ] **Step 5: Run and commit**

```bash
zig fmt ps1-core/src ps1-core/tests
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
git add -A
git commit -m "feat(pgxp): disable_2d, and one snapToIntegers instead of six copies

A primitive whose positions resolved but which lacks a depth is drawn at
integers while disable_2d is on -- DuckStation's valid_w == false path. The
thin, mixed and flat-2D snaps now share one helper; only the thin rule keeps
depths.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The same test in Metal

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal`, `ps1-macos/Sources/PS1/{MetalVram,MetalRasterizer,PrimEncoders,LiveRenderer}.swift`
- Test: `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift`

**Interfaces:**
- Consumes: Task 1's instance fields and bits.
- Produces: `MetalVram.init?(device:queue:scale:depthBuffer: Bool = false)`, `MetalVram.depth: MTLTexture`, `MetalVram.depthPersists: Bool`, `MetalVram.attachDepth(to: MTLRenderPassDescriptor, clearing: Bool)`; `MetalRasterizer.DrawKind.depthClear`; `LiveRenderer.init(device:queue:scale:depthBuffer: Bool = false)`.

- [ ] **Step 1: Write the failing test**

Append to `MetalRasterizerTests.swift`, reusing its harness for replaying hand-built records (the pattern around `:291`, `MetalVram` + `MetalRasterizer` + a readback):

```swift
/// Task 3's interpenetrating pair, replayed through Metal with the depth plane
/// persisting: either draw order must give the same VRAM, and it must be the
/// software rasterizer's VRAM. The pair is built by hand because nothing in
/// the fixture corpus carries a depth bit until Task 8.
@Test func interpenetratingTrianglesGiveOnePictureInEitherOrderInMetal() throws {
    let a = depthTestedTriangle(color: 0x001F, xs: [10, 90, 10], izs: [4000, 1000, 4000])
    let b = depthTestedTriangle(color: 0x7C00, xs: [90, 10, 90], izs: [4000, 1000, 4000])
    guard let ab = try replayWithDepth([a, b]), let ba = try replayWithDepth([b, a]) else { return }
    #expect(ab == ba)
    #expect(ab[50 * 1024 + 20] == 0x001F)
    #expect(ab[50 * 1024 + 80] == 0x7C00)
}

/// Replays hand-built records through a fresh depth-persisting `MetalVram`,
/// the same shape as `aSubPixelVertexMovesCoverage`'s `draw`.
private func replayWithDepth(_ cmds: [Ps1GpuCommand]) throws -> [UInt16]? {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, depthBuffer: true) else { return nil }
    let renderer = try MetalRasterizer(vram: vram)
    renderer.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    renderer.apply(fullDrawingAreaCommand())
    for c in cmds { renderer.apply(c) }
    renderer.endFrame()
    return vram.readback()
}
```

and, in `ps1-macos/Tests/PS1Tests/Ps1GpuVertexTestSupport.swift` (shared with Task 10):

```swift
/// A flat triangle whose three vertices sit at `xs` on rows 10/50/90 with the
/// given absolute depths, carrying both depth bits.
func depthTestedTriangle(color: UInt32, xs: [Int16], izs: [Int32]) -> Ps1GpuCommand {
    var c = Ps1GpuCommand()
    c.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
    c.value = color
    c.flags = UInt8(PS1_GPU_FLAG_DEPTH_TEST | PS1_GPU_FLAG_DEPTH_WRITE)
    let ys: [Int16] = [10, 50, 90]
    var v = [Ps1GpuVertex](repeating: Ps1GpuVertex(), count: 3)
    for i in 0..<3 {
        v[i].x = xs[i]; v[i].y = ys[i]
        v[i].px = Int32(xs[i]) << 16; v[i].py = Int32(ys[i]) << 16
        v[i].iz = izs[i]
    }
    c.v = (v[0], v[1], v[2])
    return c
}

/// GP0(E4) = (1023, 511): with E3's default of (0, 0), the whole of VRAM.
func fullDrawingAreaCommand() -> Ps1GpuCommand {
    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023
    return area
}
```

- [ ] **Step 2: Run to verify it fails**

`zig build capi-lib && zig build metallib && pkill -x Substation; ps1-macos/test.sh` — FAIL: `depthBuffer:` is not a parameter.

- [ ] **Step 3: The shader**

`Rasterizer.metal`. The output struct and its three constructors:

```metal
/// color(2) is the PGXP depth plane: one absolute reciprocal depth per
/// subtexel, 0 = far. MEMORYLESS while the setting is off — tile memory only,
/// no RAM — which is why every fragment writes it unconditionally rather than
/// the pipelines forking on a function constant.
struct Ps1FragOut {
    ushort  vram  [[color(0)]];
    ushort4 side  [[color(1)]];
    uint    depth [[color(2)]];
};

inline Ps1FragOut ps1_out(ushort v, ushort3 rgb8, uint depth) {
    return Ps1FragOut{ v, ushort4(rgb8, 255), depth };
}

/// Upload only: absent sidecar, and far depth — the transfer painted over
/// whatever geometry was here.
inline Ps1FragOut ps1_out_absent(ushort v) {
    return Ps1FragOut{ v, ushort4(0, 0, 0, 0), 0u };
}

inline Ps1FragOut ps1_discarded() { return Ps1FragOut{ 0, ushort4(0), 0u }; }
```

`ps1_fill_fragment` returns `ps1_out(v, ps1_expand(v), 0u)`. `ps1_copy_fragment` returns `Ps1FragOut{ v, side_scratch.read(src), 0u }` — one pass, all three attachments, as the copy rule requires.

A helper beside `ps1_triangle_coverage`:

```metal
/// `renderer.zig`'s depth test, transcribed: the affine interpolant of the
/// three reciprocals IS the per-pixel 1/W, and the test is iz >= stored.
/// Returns false when the fragment must be discarded. `check` is the record's
/// bit ANDed with all three depths present — never the bit alone.
inline bool ps1_depth_passes(const device Ps1PrimInstance& p, int w0, int w1, int w2, int area,
                             uint stored, thread uint& iz) {
    bool check = (p.flags & PS1_PRIM_DEPTH_TEST) != 0 && p.iz0 != 0 && p.iz1 != 0 && p.iz2 != 0;
    if (!check) return true;
    iz = uint(ps1_interp(w0, w1, w2, area, p.iz0, p.iz1, p.iz2));
    return iz >= stored;
}
```

In `ps1_prim_fragment`, add `uint dst_depth [[color(2)]],` after `dst_side`, declare `uint iz = 0u;` beside `src`/`src8`, and in each of the three triangle branches immediately after the coverage line:

```metal
        if (!ps1_depth_passes(p, w0, w1, w2, area, dst_depth, iz)) { discard_fragment(); return ps1_discarded(); }
```

At the end, replacing `return ps1_out(out, out8);`:

```metal
    // Written only where colour is: every earlier discard leaves both alone,
    // which is `putPixel`'s "returns whether it wrote" in fragment form.
    bool depth_write = (p.flags & PS1_PRIM_DEPTH_WRITE) != 0 && (p.flags & PS1_PRIM_DEPTH_TEST) != 0
        && p.iz0 != 0 && p.iz1 != 0 && p.iz2 != 0;
    return ps1_out(out, out8, depth_write ? iz : dst_depth);
```

The new fragment:

```metal
/// A `clear_depth` record: resets the depth plane over its box and nothing
/// else. Colour and sidecar are written back from tile memory unchanged, so
/// no draw that samples VRAM can observe it and HazardTracker has nothing to
/// order.
fragment Ps1FragOut ps1_depth_clear_fragment(PrimVertexOut in [[stage_in]],
                                             ushort dst [[color(0)]],
                                             ushort4 dst_side [[color(1)]]) {
    return Ps1FragOut{ dst, dst_side, 0u };
}
```

- [ ] **Step 4: `MetalVram`'s plane**

```swift
    /// The PGXP depth plane: `.r32Uint`, scaled like `texture`. `.private` and
    /// persisting while the depth buffer is on; `.memoryless` while it is off,
    /// which costs no RAM on an Apple GPU — the attachment has to exist for
    /// every pipeline to share one set of formats, but with nothing depth-
    /// tested its contents never need to leave tile memory.
    let depth: MTLTexture
    let depthPersists: Bool
    /// Staging for `uploadNativeDepth`, allocated on first use.
    private var depthStaging: MTLBuffer?
```

`init?(device:queue:scale:depthBuffer: Bool = false)`, after the sidecar:

```swift
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Uint, width: w, height: h, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = depthBuffer ? .private : .memoryless
        guard let depth = device.makeTexture(descriptor: depthDesc) else { return nil }
```

assigning `self.depth = depth; self.depthPersists = depthBuffer`. Then:

```swift
    /// Attachment 2, as every pass that draws into VRAM needs it. A memoryless
    /// texture cannot load or store, so off means clear-and-discard; on means
    /// load-and-store unless this pass is the one clearing it.
    func attachDepth(to pass: MTLRenderPassDescriptor, clearing: Bool) {
        let a = pass.colorAttachments[2]!
        a.texture = depth
        a.loadAction = (depthPersists && !clearing) ? .load : .clear
        a.clearColor = MTLClearColorMake(0, 0, 0, 0)
        a.storeAction = depthPersists ? .store : .dontCare
    }
```

`clear()` calls `attachDepth(to: pass, clearing: true)`; `clearSidecar()` calls `attachDepth(to: pass, clearing: false)`.

- [ ] **Step 5: `MetalRasterizer` and the encoder**

`makePipeline`: `desc.colorAttachments[2].pixelFormat = .r32Uint` beside attachment 1, with the comment's "All four pipelines" updated to five. `DrawKind` gains `depthClear`, mapped to `"ps1_depth_clear_fragment"` wherever the other four map to their fragment names. `openPass`: `vram.attachDepth(to: pass, clearing: false)` after attachment 1. The record switch: `case PS1_GPU_CLEAR_DEPTH: encodeDepthClear(cmd)`. In `PrimEncoders.swift`, after `encodeFill`:

```swift
    /// `clear_depth`: one box, depth only. No pass break either side — it
    /// writes colour back unchanged, so nothing sampling VRAM can observe it,
    /// and tile-memory order is submission order at every pixel.
    func encodeDepthClear(_ cmd: Ps1GpuCommand) {
        let x = Int(cmd.x), y = Int(cmd.y), w = Int(cmd.w), h = Int(cmd.h)
        guard w > 0, h > 0,
              let box = clampBox(x0: x, y0: y, x1: x + w - 1, y1: y + h - 1) else { return }
        var inst = Ps1PrimInstance()
        inst.kind = Int32(PS1_PRIM_DEPTH_CLEAR)
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(box.0), Int32(box.1), Int32(box.2), Int32(box.3))
        let first = instances.count
        instances.append(inst)
        steps.append(.draw(kind: .depthClear, range: first..<instances.count))
    }
```

`LiveRenderer.init` gains `depthBuffer: Bool = false` and passes it to `MetalVram`.

- [ ] **Step 6: Verify the test can fail**

Make `ps1_depth_passes` always return true: the Metal test must FAIL on `ab[50 * 1024 + 20]`. Restore.

- [ ] **Step 7: Run and commit**

```bash
zig build capi-lib && zig build metallib
pkill -x Substation; ps1-macos/test.sh
git add -A
git commit -m "feat(pgxp): the depth test in Metal

A third .r32Uint attachment at color(2): memoryless while the setting is
off (no RAM, and one set of formats for every pipeline), private and
load/store while on. The same integer test as renderer.zig; the depth is
written only where colour is. Fill, upload and copy write far in the same
pass as their colour; clear_depth is its own fragment and needs no pass
break.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The gate ladder gets a rung, and the parity fixture carries depth

**Files:**
- Modify: `ps1-golden/src/synthetic_prims.zig` (append frame 8), `ps1-golden/src/fixture_test.zig` (frame count), `ps1-golden/src/main.zig` (`--pgxp-on` and the sweep force all three)
- Regenerate: `ps1-core/tests/goldens/fixtures/synthetic-primitives.p1fx`
- Test: `ps1-macos/Tests/PS1Tests/{FixtureBridgeTests,MetalRasterizerTests,MetalScaleTests,PgxpParityTests}.swift`

**Interfaces:**
- Consumes: Tasks 1-7.

- [ ] **Step 1: Write the failing tests**

`fixture_test.zig`: `"fixture: the primitives fixture has nine frames in the documented order"`, `expectEqual(@as(usize, 9), …)`. `FixtureBridgeTests.swift:440`: `== 9`. Append to `MetalRasterizerTests.swift`:

```swift
/// Frame 8, the depth rung: interpenetrating opaque triangles drawn in the
/// "wrong" order, a transparent one under transparent_depth, a fill across
/// part of it, and a clear_depth. The only frame in the ladder that can gate
/// the depth test.
@Test func frameEightMatchesTheSoftwareRasterizerWithDepth() throws {
    guard let r = try MetalFixtureHarness.replay("synthetic-primitives", upTo: 9, depthBuffer: true) else { return }
    try r.expectMatches()
}
```

Use the exact assertion call the neighbouring `upTo: 6` test uses. `MetalFixtureHarness.replay` gains `depthBuffer: Bool = false`, passed to `MetalVram`. Append to `MetalScaleTests.swift`, beside `:344`, the same downsample-invariance comparison over `upTo: 9` at N in {2, 3, 4, 8} with `depthBuffer: true` (add the parameter to `MetalScaleHarness.compare` the same way).

- [ ] **Step 2: Run to verify they fail** — `zig build test` (eight frames, not nine).

- [ ] **Step 3: Append frame 8**

In `synthetic_prims.zig`, add to `Case`:

```zig
    /// A vertex word whose PGXP shadow resolves with depth `z` — how frame 8
    /// gets real depths through real GP0 decode.
    fn gp0z(self: *Case, word: u32, z: f32) void {
        const half = struct {
            fn f(w: u32) f32 {
                return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(w)))));
            }
        }.f;
        _ = self.gpu.writeGp0(word, .{ .x = half(word), .y = half(word >> 16), .z = z, .word = word, .flags = Value.valid_xyz });
    }
```

After frame 7:

```zig
    // ---- Frame 8: the depth buffer ----------------------------------------
    // PGXP on with every depth setting, on a bare Gpu: the mirrors are set
    // directly, as `Bus` would. Lands at x 0..255, y 256..511 — left of the
    // 16bpp page at (256,256) that frames 6 and 7 sample — and samples no
    // texture itself, so it cannot contain the self-feedback shape.
    gpu.gp0.pgxp_enabled = true;
    gpu.gp0.setDepthMirrors(&gpu.sink, &gpu.vram, &gpu.draw_env, true, true, false);
    c.clip(0, 256, 255, 511);
    c.offset(0, 0);
    c.gp0(0xE1000000);

    // A near on the left, far on the right; B the mirror — drawn B first, so
    // painter's order would let A cover all of B.
    c.gp0(0x207C0000);
    c.gp0z(Case.xy(190, 270), 400);
    c.gp0z(Case.xy(20, 330), 4000);
    c.gp0z(Case.xy(190, 390), 400);
    c.gp0(0x20001F00);
    c.gp0z(Case.xy(20, 270), 400);
    c.gp0z(Case.xy(190, 330), 4000);
    c.gp0z(Case.xy(20, 390), 400);

    // Transparent under transparent_depth: tests, never writes.
    c.gp0(0x2200FF00);
    c.gp0z(Case.xy(60, 300), 300);
    c.gp0z(Case.xy(150, 310), 5000);
    c.gp0z(Case.xy(90, 380), 300);

    // A fill across part of it resets depth there; the triangle after it
    // then draws over the filled strip wherever it covers it.
    c.gp0(0x02404040);
    c.gp0(Case.xy(0, 400));
    c.gp0(Case.xy(256, 16));
    c.gp0(0x20FFFFFF);
    c.gp0z(Case.xy(10, 395), 9000);
    c.gp0z(Case.xy(240, 400), 9100);
    c.gp0z(Case.xy(120, 440), 9000);

    // A drawing-area change after all that records the whole-plane clear.
    c.clip(0, 256, 254, 511);
    try c.endFrame();
    gpu.gp0.setDepthMirrors(&gpu.sink, &gpu.vram, &gpu.draw_env, false, false, false);
```

Update the file header's frame table line and the fixture_test comment.

- [ ] **Step 4: Force all three in `ps1-golden/src/main.zig`**

In `runPgxp` beside `setPgxpColorCorrection(true)` and in the stream-capture path beside `setPgxpColorCorrection(opts.pgxp_on)`:

```zig
    bus.setPgxpDepthBuffer(true);          // (opts.pgxp_on in the capture path)
    bus.setPgxpTransparentDepth(true);
    bus.setPgxpDisable2d(true);
```

and extend each block's comment to say `--pgxp-on` and the sweep turn on EVERY correction sub-setting, depth included, because they are coverage and parity instruments rather than pictures of the defaults. Update the `--pgxp-on` usage line at `:51`.

- [ ] **Step 5: Regenerate and run**

```bash
zig fmt ps1-golden/src
zig build fixtures -Doptimize=ReleaseFast
cp zig-out/fixtures/synthetic-primitives.p1fx ps1-core/tests/goldens/fixtures/
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build capi-lib && zig build metallib
pkill -x Substation; ps1-macos/test.sh
```

Expected: all pass, `PgxpParityTests` included — `tr1-usa-v1-1-pgxp.p1fx` now carries depth bits and `clear_depth` records, and Metal must still replay it bit-exactly. Check it actually does: add to `PgxpParityTests.swift` beside `thePgxpParityFixtureActuallyCarriesPerspectiveTriangles`:

```swift
/// The depth half of the same guard: a fixture captured before `--pgxp-on`
/// forced the depth settings would pass the strict-equality gate trivially.
@Test(.enabled(if: generatedFixtureExists("tr1-usa-v1-1-pgxp")))
func thePgxpParityFixtureActuallyCarriesDepthTestedTriangles() throws {
    let file = try FixtureFile(contentsOf: FixtureFile.url(named: "tr1-usa-v1-1-pgxp"))
    var tested = 0, clears = 0
    withExtendedLifetime(file) {
        for i in 0..<file.frames.count {
            for cmd in file.records(for: i) {
                if cmd.flags & UInt8(PS1_GPU_FLAG_DEPTH_TEST) != 0 { tested += 1 }
                if cmd.kind == UInt8(PS1_GPU_CLEAR_DEPTH.rawValue) { clears += 1 }
            }
        }
    }
    #expect(tested > 1000, Comment(rawValue: "only \(tested) depth-tested triangles — was the capture really --pgxp-on?"))
    #expect(clears > 0)
}
```

Copy the `.enabled(if:)` trait from the perspective test above it if its spelling differs.

- [ ] **Step 6: Verify frame 8 can fail** — revert Task 7's `ps1_depth_passes` to always-true: frame 8's Metal test must FAIL while frames 0-7 still pass. Restore.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "test(pgxp): a depth rung on the gate ladder, and depth in the parity fixture

synthetic-primitives frame 8 (appended): interpenetrating triangles drawn
in the wrong order, a transparent one under transparent_depth, a fill, and
a drawing-area change. --pgxp-on and the sweep now force all three depth
settings on, so the tr1 PGXP-on fixture carries depth bits and clear_depth
records and the Metal parity gate covers them.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The sweep counts depth, and ratchets it

**Files:**
- Modify: `ps1-golden/src/pgxp_sweep.zig`, `ps1-golden/src/main.zig` (`runPgxp`'s report, `readFloors`)
- Modify: `ps1-core/tests/goldens/pgxp/floors.txt`

**Interfaces:**
- Consumes: `PgxpStats.depth_tested`, `depth_clears`, `flat_2d_primitives`.
- Produces: `Report.depth_tested/depth_clears/flat_2d_primitives: u64`; `Ratchets.depth: []const KeyedCount`, `Ratchets.depth_clears: []const KeyedCount`; `parseDepthFloors`, `parseDepthClearFloors`.

- [ ] **Step 1: Write the failing parser test**

Append to the test block at the foot of `pgxp_sweep.zig`, modelled on the colour one at `:458`:

```zig
test "Phase5: depth and depth_clears floors parse, and no other parser takes them" {
    const a = std.testing.allocator;
    const text =
        \\croc 90.0
        \\depth croc 1000
        \\depth_clears croc 50
        \\color croc 12300
    ;
    const floors = try parseFloors(a, text);
    defer a.free(floors);
    try std.testing.expectEqual(@as(usize, 1), floors.len);
    const d = try parseDepthFloors(a, text);
    defer a.free(d);
    try std.testing.expectEqual(@as(usize, 1), d.len);
    try std.testing.expectEqual(@as(u64, 1000), d[0].count);
    const c = try parseDepthClearFloors(a, text);
    defer a.free(c);
    try std.testing.expectEqual(@as(u64, 50), c[0].count);
}
```

- [ ] **Step 2: Run to verify it fails** — `zig build test`.

- [ ] **Step 3: Implement**

Prefixes: `const depth_prefix = "depth ";` and `const depth_clears_prefix = "depth_clears ";` ("depth_clears x" does not start with "depth " — the underscore — so the two cannot take each other's lines). `parseFloors` skips both. Add the two parsers and `KeyedCount` aliases (`DepthFloor`, `DepthClearFloor`), two `Ratchets` fields, the three `Report` fields, the three copies in `runPgxp`'s return literal, and the two `parse…` calls in `main.zig`'s `readFloors`. In `report`, after the `color` block:

```zig
    if (countFor(ratchets.depth, key)) |df| {
        const ok = r.depth_tested >= df;
        if (!ok) failed = true;
        std.debug.print("  depth             {s} polygons tested   floor {s}  {s}\n", .{
            commas(&b3, r.depth_tested), commas(&b4, df), if (ok) "OK" else "BELOW FLOOR",
        });
    } else {
        std.debug.print("  depth             {s} polygons tested   no floor  WARN\n", .{commas(&b3, r.depth_tested)});
    }
    if (countFor(ratchets.depth_clears, key)) |cf| {
        const ok = r.depth_clears >= cf;
        if (!ok) failed = true;
        std.debug.print("  depth_clears      {s}   floor {s}  {s}\n", .{
            commas(&b3, r.depth_clears), commas(&b4, cf), if (ok) "OK" else "BELOW FLOOR",
        });
    } else {
        std.debug.print("  depth_clears      {s}   no floor  WARN\n", .{commas(&b3, r.depth_clears)});
    }
    std.debug.print("  flat_2d           {s}   (resolved, no depth: drawn at integers by disable_2d)\n", .{commas(&b3, r.flat_2d_primitives)});
```

Extend `report`'s doc comment with the sixth and seventh checks: both FLOORS — `depth_tested` because fewer tested polygons means the feature reaches less geometry, `depth_clears` because a clear count that collapses means the clear rules stopped firing and the plane is accumulating.

- [ ] **Step 4: Measure and pin**

```bash
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- pgxp 2>&1 | tee /tmp/pgxp-phase5.txt | grep -E "^\S|depth|flat_2d|FAIL|BELOW"
```

For each workload, add `depth <key> N` and `depth_clears <key> N` to `floors.txt`, N = the measured count truncated to 3 significant figures (the file's existing convention). A header block above them states: what each counts, that both are floors and why, that the sweep forces all three settings on, and the measured table (key, tested, clears, flat_2d). A zero is kept as a record of the measurement, not a ratchet — say which workloads are zero and why (2D-only reach, as for `perspective`), chased rather than inferred.

- [ ] **Step 5: Re-run the sweep; it must pass every floor. Commit.**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
git add -A
git commit -m "test(pgxp): the sweep counts depth-tested polygons and clears, and floors both

<paste the measured table here>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: The app — settings, rebuild on toggle, and an exact resync

**Files:**
- Modify: `ps1-macos/Sources/PS1/{Ps1Core,EmulatorRunner,LiveRenderer,MetalVram,MetalDisplayView,ContentView,PgxpSetting,EmulatorViewModel}.swift`, `ps1-macos/Sources/PS1App/VideoCommands.swift`
- Test: `ps1-macos/Tests/PS1Tests/{PgxpSettingTests,LiveRendererScaleTests}.swift`

**Interfaces:**
- Consumes: C `ps1_set_pgxp_depth_buffer/transparent_depth/disable_2d`, `ps1_copy_depth` (Task 4); `MetalVram(depthBuffer:)`, `LiveRenderer(depthBuffer:)` (Task 7).
- Produces: `PgxpSetting.depthBuffer/transparentDepth/disable2d` with setters; `EmulatorViewModel.pgxpDepthBuffer/pgxpTransparentDepth/pgxpDisable2d`; `MetalVram.uploadNativeDepth(_ plane: [UInt32])`; `LiveRenderer.drain(from:shadow:)` with `shadow: () -> ([UInt16], [UInt32]?, UInt64)`.

- [ ] **Step 1: Write the failing tests**

`PgxpSettingTests.swift`, beside `colorCorrectionDefaultsOffForAFreshInstall`:

```swift
@Test func theDepthSettingsDefaultOffAndPersist() {
    let d = scratchDefaults("pgxp.depth")
    var s = PgxpSetting(key: "pgxpEnabled", defaults: d)
    #expect(!s.depthBuffer && !s.transparentDepth && !s.disable2d)
    s.setDepthBuffer(true); s.setTransparentDepth(true); s.setDisable2d(true)
    let r = PgxpSetting(key: "pgxpEnabled", defaults: d)
    #expect(r.depthBuffer && r.transparentDepth && r.disable2d)
}
```

Extend `theSubSettingsKeepTheirOwnKeys` with the three new keys. `LiveRendererScaleTests.swift`:

```swift
/// A resync while depth is on adopts the shadow's depth plane too. Without it
/// the next frame depth-tests against a blank plane and a far polygon covers
/// a near one the software rasterizer kept hidden.
@Test func aResyncAdoptsTheDepthPlane() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let live = try? LiveRenderer(device: device, queue: queue, scale: 1, depthBuffer: true) else { return }
    let q = StreamQueue()
    var plane = [UInt32](repeating: 0, count: 1024 * 512)
    for y in 0..<100 { for x in 0..<100 { plane[y * 1024 + x] = 1_000_000 } } // near
    // A FAR depth-tested triangle over that region, published as frame 2. The
    // queue is fresh, so the drain adopts the shadow at seq 1 first and then
    // executes seq 2 against the adopted plane.
    let far = depthTestedTriangle(color: 0x7FFF, xs: [10, 90, 10], izs: [1000, 1000, 1001])
    let recs = [fullDrawingAreaCommand(), far]
    recs.withUnsafeBufferPointer {
        q.publish(seq: 2, records: $0.baseAddress!, recordCount: $0.count,
                  payload: nil, payloadCount: 0, complete: true)
    }
    live.drain(from: q) { ([UInt16](repeating: 0, count: 1024 * 512), plane, 1) }
    #expect(live.vram.readbackNative()[50 * 1024 + 20] == 0) // hidden: the plane came across
}
```

- [ ] **Step 2: Run to verify they fail** — the Swift suite; FAIL, unknown members.

- [ ] **Step 3: Settings, end to end**

`PgxpSetting`: three stored properties read with `object(forKey:)` (default false) under `key + ".depthBuffer"`, `".transparentDepth"`, `".disable2d"`, three `mutating func set…` writing them — the same shape as `colorCorrection`. `Ps1Core`: `setPgxpDepthBuffer/setPgxpTransparentDepth/setPgxpDisable2d(_:)` calling the C setters, and:

```swift
    func copyDepth(into dst: UnsafeMutablePointer<UInt32>) { ps1_copy_depth(handle, dst) }
```

`EmulatorRunner`: three `Atomic<Bool>(false)` and setters, re-applied per frame beside `setPgxpColorCorrection` (safe: Task 4's setter records nothing when the value is unchanged). `EmulatorViewModel`: three properties mirroring `pgxpColorCorrection`'s shape, and the three `runner.set…` calls beside `:563`. `VideoCommands`: after "PGXP Colour Correction":

```swift
                Toggle("PGXP Depth Buffer", isOn: $model.pgxpDepthBuffer)
                Toggle("PGXP Transparent Depth", isOn: $model.pgxpTransparentDepth)
                    .disabled(!model.pgxpDepthBuffer)
                Toggle("PGXP Disable on 2D", isOn: $model.pgxpDisable2d)
```

inside the existing greyed group. `ContentView`: `DisplayIdentity` gains `depthBuffer: Bool` from `model.pgxpDepthBuffer && model.pgxpEnabled` (the EFFECTIVE value: it decides whether the plane persists), passed as `MetalDisplayView(runner:scale:depthBuffer:…)` into `Coordinator.init` and on to `LiveRenderer(…, depthBuffer:)`.

- [ ] **Step 4: Publish the plane beside VRAM, under the same seq**

`EmulatorRunner`: three `UnsafeMutablePointer<UInt32>` depth slots allocated beside the VRAM slots (3 x 2 MB) and a `depthValid: [Bool]` guarded by `displayLock`. After `core.copyVRAM(into: slots[next])`:

```swift
            // The depth plane is part of the shadow a resync adopts, so it is
            // published under the SAME seq as VRAM — never sampled separately.
            let withDepth = pgxpDepthBuffer.load(ordering: .acquiring)
            if withDepth { core.copyDepth(into: depthSlots[next]) }
```

and `depthValid[next] = withDepth` inside the lock beside `seqs[next]`. `withNewestFrame`'s body gains a fourth argument, `UnsafePointer<UInt32>?` — the slot's depth when valid, else nil — and its callers are updated.

`LiveRenderer.drain(from:shadow:)`: the closure returns `([UInt16], [UInt32]?, UInt64)`; after `vram.uploadNative(pixels)`, `if let d = depth { vram.uploadNativeDepth(d) }`. Update the existing test call sites (`grep -n "drain(from" ps1-macos/Tests`) to return `nil` for the depth. `MetalVram`:

```swift
    /// A NATIVE depth plane, replicated N x N like `uploadNative`'s pixels.
    /// A no-op while the plane is memoryless: there is nothing to persist.
    func uploadNativeDepth(_ plane: [UInt32]) {
        guard depthPersists else { return }
        precondition(plane.count == Self.nativePixelCount)
        if depthStaging == nil {
            depthStaging = device.makeBuffer(length: pixelCount * 4, options: .storageModeShared)
        }
        guard let staging = depthStaging else { preconditionFailure("MetalVram.uploadNativeDepth: makeBuffer returned nil") }
        let dst = staging.contents().bindMemory(to: UInt32.self, capacity: pixelCount)
        for y in 0..<height {
            for x in 0..<width { dst[y * width + x] = plane[(y / scale) * Self.nativeWidth + x / scale] }
        }
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else {
            preconditionFailure("MetalVram.uploadNativeDepth: command encoding failed")
        }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: width * 4,
                  sourceBytesPerImage: pixelCount * 4,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: depth, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }
```

A blit destination needs no usage flag beyond `.renderTarget`, so `depthDesc.usage` is unchanged.

In `MetalDisplayView`'s drain closure, build the depth array from the pointer (`Array(UnsafeBufferPointer(start: p, count: 1024 * 512))`) only when it is non-nil.

- [ ] **Step 5: Verify the resync test can fail** — skip the `uploadNativeDepth` call: it must FAIL. Restore.

- [ ] **Step 6: Run, build the app, commit**

```bash
zig build capi-lib && zig build metallib
pkill -x Substation; ps1-macos/test.sh
zig build macos
git add -A
git commit -m "feat(macos): the depth settings, a rebuild on toggle, and an exact resync

Three Video menu items, greyed with PGXP off; Transparent Depth also greyed
with the depth buffer off. The effective depth setting joins the display's
.id(), so a toggle rebuilds MetalVram with a persisting or memoryless
plane. The software plane is published under the same seq as VRAM and a
resync adopts both.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: The `depth` knob, and the A/B on the user's Crash scene

**Files:**
- Modify: `ps1-trace/src/main.zig`

- [ ] **Step 1: Add the knob**

Beside `noperspective`:

```zig
    // "depth" turns the PGXP depth buffer on, and like `noperspective` it is a
    // LOCKSTEP knob: only gp0 consumes it and no game reads the depth plane, so
    // an on/off A/B runs the identical instruction stream. Confirm with the
    // `vertices=` line: it must match between the two runs.
    const depth_on = for (argv.items) |arg| {
        if (std.mem.eql(u8, arg, "depth")) break true;
    } else false;
```

after `bus.setPgxpTextureCorrection(!no_perspective);`: `bus.setPgxpDepthBuffer(depth_on);`. Add `[depth]` to the usage string, and `depth_tested`/`depth_clears` to the `[probe] pgxp=` line.

- [ ] **Step 2: Build and run the A/B**

```bash
zig build -Doptimize=ReleaseFast
C="games/Crash Bandicoot (Europe) (EDC)/Crash Bandicoot (Europe) (EDC).cue"
mkdir -p /tmp/c1-nodepth /tmp/c1-depth
./zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin "$C" 1260000000 /tmp/c1-nodepth explore lean pgxp | grep "\[probe\] pgxp"
./zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin "$C" 1260000000 /tmp/c1-depth explore lean pgxp depth | grep "\[probe\] pgxp"
```

Expected: identical `vertices=` (lockstep), and `depth_tested` > 0 on the second.

- [ ] **Step 3: Classify what changed**

For frames 800, 850, 1050, 1250 (N. Sanity Beach): `magick compare -metric AE` each pair and an overlay (`-compose src -highlight-color red`). Look at every changed region and classify it: **a polygon now hidden or revealed** (a whole-surface change bounded by another surface's silhouette) versus **anything else**. Also repeat with `explore` on two sweep workloads that reach 3D (spyro, silent-hill) to see whether the depth buffer changes anything the user would call a fix or a regression.

- [ ] **Step 4: Report, and commit the knob**

The report to the user states, with the frame montages: whether the N. Sanity Beach scene changed with depth on, and where; whether any change is a sort fix; whether any is a regression (geometry vanishing because a clear never came). **If nothing in the user's scene changes, say so plainly: the glitch they see is not a sort problem, and the depth buffer shipped for DuckStation parity, not as its fix.**

```bash
git add ps1-trace/src/main.zig
git commit -m "feat(trace): a lockstep 'depth' knob for depth-buffer A/Bs

<one paragraph: what the Crash N. Sanity Beach A/B showed>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: The rules the next reader needs

**Files:**
- Modify: `CLAUDE.md`, `.claude/skills/ps1-pgxp/SKILL.md`, `.claude/skills/ps1-gpu-metal/SKILL.md`

- [ ] **Step 1: `CLAUDE.md`, the PGXP rules block**

"Each of the six sub-settings" becomes nine, naming `Bus.pgxpDepthBuffer`, `pgxpTransparentDepth` (which also folds in the depth buffer) and `pgxpDisable2d`; the default-OFF rule names all four default-OFF flags. Add:

- **The depth is ABSOLUTE `iz = round(2^30/W)`, not `rw`.** A test compares across primitives, where `rw`'s per-primitive normalisation does not cancel. 1/W is affine in screen space, so the plain `interp` produces it per pixel — no divide, and one expression in both rasterizers.
- **A depth is written only where colour is**, in both rasterizers; a clip, a mask refusal or a texel hole leaves it.
- **A depth-setting change resets the plane with a RECORDED `clear_depth`**, never a silent @memset — Metal keeps its own plane and only the stream reaches it — and re-applying an unchanged value records nothing, because the macOS runner re-applies every setting every frame.
- **The Metal depth attachment is memoryless while the setting is off.** Every pipeline shares one set of formats; toggling rebuilds `MetalVram` through the display's `.id()`.

In the Metal rules, add: **every VRAM write resets depth where it writes colour**, fill/upload/copy in the same pass as their colour.

- [ ] **Step 2: The pgxp skill**

Append "## Phase 5: the depth buffer (2026-09-25)": the representation and its bound; DuckStation's rules as implemented (`is_3d` on W, quads judged whole, transparent tests but never writes, the two clears and the same-value E3/E4 carve-out); `disable_2d` and why it is only the "resolved, no depth" case; the three deliberate differences (no lines, no per-game table, exact far on reset); the sweep's table from Task 9; and Task 11's finding on Crash, stated as measured.

- [ ] **Step 3: The gpu-metal skill**

A paragraph on the third attachment: why memoryless when off (formats shared by every pipeline, no RAM), why no function constant, why `clear_depth` needs no pass break, and why the copy resets depth in the same pass.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md .claude/skills
git commit -m "docs(pgxp): the Phase 5 rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Self-review against the spec

- **Record (`iz`, two bits, `clear_depth`, 120 bytes, version 4):** Task 1.
- **`gp0` decisions (is_3d on W, quads whole, transparent, both clears, disable_2d):** Tasks 5, 6.
- **Software plane, test, write-only-where-colour, resets:** Tasks 2, 3.
- **Metal attachment, same test, resets, memoryless-when-off, 54-word instance:** Tasks 1, 7.
- **Resync exactness (`ps1_copy_depth`, same seq):** Tasks 4, 10.
- **Settings (default off, not in `Bus.init`, one accessor each, sub-flag folding, ABI, menu, greying):** Tasks 4, 10.
- **Gates (verify/stream-verify unmoved, `--pgxp-on` and sweep force all three, synthetic rung appended, parity fixture carries depth, `depth_tested`/`depth_clears` floors):** Tasks 1-9 run the gates; 8, 9 add the new ones.
- **Crash A/B and honest report:** Task 11.
- **Review Focus:** toggle reset through the stream → Task 4; same-value E3/E4 → Task 5; extreme W → Task 5; `ps1_reset` → Task 4; resync adopts depth → Task 10.
- **Deliberate differences from DuckStation** (lines, per-game table, exact far): recorded in Task 12.
