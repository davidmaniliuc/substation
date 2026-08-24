# Metal Renderer Phase 0 — Integer Rasterizer Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert `ps1-core/src/gpu/`'s software rasterizer from a scanline span search with `f32` interpolation to integer edge-function rasterization with exact integer interpolation, so that a GPU backend can later evaluate the *same* formulas and reach byte-identical output at 1×.

**Architecture:** Triangle coverage becomes three integer edge functions plus a top-left fill rule, transcribed from Avocado's `render_triangle.cpp`. Attribute interpolation becomes `floor((w0·a0 + w1·a1 + w2·a2) / area)` evaluated in `i64` — exact, and *position-evaluable*, which is the property a fragment shader needs. `color.zig`'s `modulate` and the shaded-line gradient lose their `f32` paths the same way. Nothing else in the GPU changes: `putPixel`, the drawing-area clip, the mask/STP bits and the oversized-primitive drop rule are all untouched.

**Tech Stack:** Zig 0.16.0, `ps1-core` unit tests (`ps1-core/tests/gpu_test.zig`), the PeterLemon ratchet (`zig build test-roms-pl`), the trace-equivalence harness (`zig build trace-golden`), and `ps1-trace` for visual A/B.

**Spec:** `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md` — see § The 1× gate and § Phases → Phase 0.

## Global Constraints

- **Zig 0.16.0 only.** `std.Io.Dir.cwd()`, `std.ArrayList(...).empty`, `addRunArtifact`. Run `zig fmt` before every commit.
- **This is the only phase permitted to change rendered output.** Phases A–D run against the baseline this phase recaptures. Do not smuggle an output change into any later phase.
- **`zig build trace-golden -- verify` and `zig build test-roms-pl` are EXPECTED TO BE RED from Task 2 through Task 7.** They are recaptured once, in Task 8. Do not recapture mid-phase, and do not treat their redness during Tasks 2–7 as a failure.
- **`zig build test` (the 11 unit-test binaries) must stay green at every commit.** That gate is not suspended.
- **No file in `ps1-core/src` over ~600 lines.** `renderer.zig` is 536 today; the conversion must not push it past ~600. If it would, split the triangle path into `gpu/triangle.zig` — but only if the line count actually forces it.
- **`putPixel` must not change.** It is the model for the Phase B fragment shader (spec § The seam). Its drawing-area clip, mask check, blend dispatch and `set_mask` OR stay exactly as they are.
- **The oversized-primitive drop rule must not change**, at any of its five sites: `renderer.zig:77-78` (triangle), `:265` (rectangle), `:291` (line), `:321` (shaded line), `:491` (textured rectangle). Four existing tests in `gpu_test.zig` pin it.
- **`i64` for interpolation numerators is a deliberate Phase B constraint.** The closed form `floor((w0·a0 + w1·a1 + w2·a2) / area)` overflows `i32` for the constant term. Metal Shading Language 2.2+ has `long`, which Phase B will use. Do not "optimise" the software side into an incremental fixed-point DDA — that is not position-evaluable and a fragment shader cannot reproduce it.
- **`-D` options go BEFORE `--`.** `zig build trace-golden -Doptimize=ReleaseFast -- verify`. Anything after `--` is an argument to `ps1-golden`, so `-- verify -Doptimize=ReleaseFast` silently runs a Debug build and passes a junk flag to the program.
- **Commit style:** one commit per task, directly on `master`, ending with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  ```

## Reference: the conversion in one page

The formulas every task below implements. Transcribed from `avocado_ref/src/device/gpu/render/render_triangle.cpp` and `avocado_ref/src/device/gpu/primitive.h`.

**Signed area / edge function.** With screen-space vertices `v0, v1, v2` (drawing offset already applied):

```
orient2d(a, b, c) = (b.x - a.x)·(c.y - a.y) - (b.y - a.y)·(c.x - a.x)

area = orient2d(v0, v1, v2)
w0(p) = orient2d(v1, v2, p)     w1(p) = orient2d(v2, v0, p)     w2(p) = orient2d(v0, v1, p)
w0 + w1 + w2 = area             (identity — useful as an assertion)
```

**Winding normalization without permuting attributes.** Avocado swaps `v[1]`/`v[2]` when the area is negative (`primitive.h:53-55`). We cannot: the shader indexes attributes by original vertex number. Instead multiply everything by `s = sign(area)`. Proof that this is the same thing: for the swapped triangle `(v0, v2, v1)`, the barycentric numerator of original vertex `i` works out to `-w_i`, and the area to `-area`. So `s·w_i` over `s·area` is the positive-area configuration with the original indexing intact.

**Per-pixel steps** (all pre-multiplied by `s`):

```
dw0/dx = s·(v1.y - v2.y)    dw0/dy = s·(v2.x - v1.x)
dw1/dx = s·(v2.y - v0.y)    dw1/dy = s·(v0.x - v2.x)
dw2/dx = s·(v0.y - v1.y)    dw2/dy = s·(v1.x - v0.x)
```

**Top-left fill rule.** For barycentric `i` the associated edge runs `v_{i+1} → v_{i+2}` in the normalized winding, i.e. direction `s·(v_{i+2} - v_{i+1})`:

```
isTopLeft(dx, dy) = dy > 0 or (dy == 0 and dx < 0)
bias_i = if isTopLeft(edge_i) then -1 else 0
inside(p) = ((w0 + bias0) | (w1 + bias1) | (w2 + bias2)) > 0
```

The `|`-then-`> 0` test is Avocado's, verbatim (`render_triangle.cpp:250`): any negative term sets the sign bit of the OR, so it means "all three non-negative, and not all three zero". Transcribe it as-is rather than rewriting it as three comparisons — the all-zero case is a real (if vanishing) behavioural difference.

**Attribute interpolation.** Exact, position-evaluable, `i64`:

```
a(p) = floor( (w0(p)·a0 + w1(p)·a1 + w2(p)·a2) / area )
```

with `w_i` the **un-biased** values (the bias is a coverage device and must not perturb attributes) and `area > 0` after normalization. Inside the triangle every `w_i ≥ 0` and every `a_i ≥ 0`, so `@divFloor` and `@divTrunc` agree; use `@divFloor` because it is defined for the boundary cases the fill rule admits.

Avocado's own fixed-point path is `#ifdef USE_FIXED_POINT` and **disabled**, with the comment "Fixed point has some rounding issue, need more investigation" (`render_triangle.cpp:30-31`). It runs `float` deltas instead. **Do not port that.** The exact `i64` closed form has no rounding issue and costs the same as today's code: three multiplies and one divide per attribute, versus today's nine multiplies and three divides shared across three attributes.

**How much output actually moves — measured, not assumed.** Each rule below was simulated against the current implementation before this plan was written. The spec's § The 1× gate implies the coverage change is the big one; it is not.

| Change | Divergence from today |
|---|---|
| Edge-function coverage (Task 2) | **Rare.** 5 triangles in 3,000 random ones over a 64×64 box; 0 in 3,000 over the full VRAM box. Always the same direction — the span search paints one extra pixel on a near-degenerate sliver, never leaves a gap. Its bias expression and today's are algebraically equivalent. |
| Gouraud interpolation (Task 3) | Sparse but systematic. ~1 pixel in 35,000 covered, and every constant-colour triangle is a potential case: today's `f32` path renders a flat colour non-flat. |
| Texcoord interpolation (Task 4) | **The big one.** ~30-50 wrong texels per 300 random triangles — texcoords are used at full 8-bit precision, where the Gouraud path's `>> 3` absorbs most sub-unit error. |
| `modulate` (Task 5) | None. Division by 16.0 is exact in `f32`. |
| `modulate` dither scale (Task 6) | Every dithered modulated texel, by up to four 5-bit levels. |
| Shaded-line gradient (Task 7) | Whenever `(c1-c0)/steps` is not representable in `f32`; typically the far endpoint plus one or two interior steps. |

So the honest claim for Task 2 is **not** "this fixes visible pixels". It is: the coverage rule is now one a fragment shader can evaluate, which is the whole point of Phase 0. Do not go looking for a rendering improvement there — expect a wash, and treat anything more than a wash as a bug.

**Dither.** Add the `dither_table` offset to the **8-bit** channel value, clamp to `[0, 255]`, then `>> 3`. This is what Avocado's `ditherLUT[y&3][x&3][color]` does. Today's shaded-triangle path is already equivalent (`clamp(r_f/8.0, 0, 31)` after adding the offset to an 8-bit value); today's `modulate` is *not* — see Task 6.

---

## File Structure

- `build.zig` — modified once, Task 1: add `-Dtest-filter` so a task can run one test instead of eleven binaries.
- `ps1-core/src/gpu/gpu.zig` — modified once, Task 1: re-export `Renderer` and `Color` so tests can drive the rasterizer directly instead of hand-encoding GP0 words.
- `ps1-core/src/gpu/renderer.zig` — the bulk of the work. Tasks 2, 3, 4, 7. Gains `orient2d`, `isTopLeft`, `interp` and a named `ShadeResult`; loses the span search and every `f32`.
- `ps1-core/src/gpu/color.zig` — Tasks 5 and 6: `modulate` goes integer, then its dither scale is corrected.
- `ps1-core/tests/gpu_test.zig` — new tests appended in every task. Existing 24 tests are not edited.
- `ps1-core/tests/goldens/trace/*.txt` — regenerated once, Task 8.
- `test-roms/peterlemon/*/floor.txt` — re-pinned once, Task 8.

Nothing outside `ps1-core/src/gpu/` changes. `ps1-golden`'s `state_hash.zig` needs no edit: the renderer is stateless and holds no fields.

---

## Task 1: Test scaffolding and characterization lock

Before changing coverage, pin the behaviours the conversion must *not* alter, and make it possible to run one test in a second instead of the whole suite.

**Files:**
- Modify: `build.zig:97-121`
- Modify: `ps1-core/src/gpu/gpu.zig:2-4`
- Test: `ps1-core/tests/gpu_test.zig` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `zig build test -Dtest-filter=<substring>` — runs only matching tests in every unit-test binary.
  - `ps1_core.gpu.Renderer` — the `Renderer` namespace, so tests call `Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, ...)` directly.
  - `ps1_core.gpu.Color` — the `color.zig` namespace, for `Color.modulate`, `Color.blend`, `Color.dither_table`.
  - Test helper `fn envFullArea(gpu: *Gpu) void` in `gpu_test.zig` — sets drawing area to full VRAM, offset 0, all other `DrawingEnv` fields zero.

- [ ] **Step 1: Add the test filter option to `build.zig`**

In `build.zig`, immediately after `const test_step = b.step("test", ...);` (line 97), add:

```zig
    // A single substring filter across every unit-test binary. `zig build test`
    // builds and runs eleven of them; when iterating on one behaviour that is
    // eleven process launches for one assertion.
    const test_filter = b.option([]const u8, "test-filter", "Only run unit tests whose name contains this substring");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
```

Then add `.filters = test_filters,` to each of the three `b.addTest(.{ ... })` calls that feed `test_step` — the one in the `unit_test_files` loop (line 112), `golden_test` (line 125) and `capi_test` (line 138). For example the loop body becomes:

```zig
    for (unit_test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        t.root_module.addImport("ps1_core", core_mod);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
```

Do **not** add `.filters` to the two ROM-suite `addTest` calls further down (lines ~292 and ~306) — they already have `-Drom-filter`.

- [ ] **Step 2: Verify the filter works**

Run: `zig build test -Dtest-filter="GPU drops an oversized rectangle"`
Expected: PASS, and visibly fast (a couple of seconds) — it compiles eleven binaries but runs one test.

Run: `zig build test`
Expected: PASS, all tests, unchanged from before.

- [ ] **Step 3: Export `Renderer` and `Color` from `gpu.zig`**

`ps1-core/src/gpu/gpu.zig` lines 2-4 currently read:

```zig
pub const Vram = @import("vram.zig").Vram;
pub const Regs = @import("registers.zig");
pub const Gp0Engine = @import("gp0.zig").Gp0Engine;
```

Add two lines after them:

```zig
pub const Renderer = @import("renderer.zig").Renderer;
pub const Color = @import("color.zig");
```

Both are already reachable through `gp0.zig`; this only makes them addressable from a test. `root.zig` re-exports `gpu.zig` wholesale, so `ps1_core.gpu.Renderer` resolves with no further change.

- [ ] **Step 4: Write the characterization tests**

Append to `ps1-core/tests/gpu_test.zig`. These are expected to pass **now and after every later task** — they pin what the conversion must not touch. Add the imports at the top of the file if not present (`const Renderer = ps1_core.gpu.Renderer;`, `const Color = ps1_core.gpu.Color;`).

```zig
// --- Phase 0 characterization: behaviours the integer conversion must preserve.

fn envFullArea(gpu: *Gpu) void {
    gpu.draw_env = .{};
    gpu.draw_env.area_bot_right = 1023 | (511 << 10);
}

test "Phase0: triangle honours the drawing area on every side" {
    var gpu = Gpu.init();
    envFullArea(&gpu);
    // Drawing area (10,10)-(20,20); the triangle covers (0,0)-(40,40).
    gpu.draw_env.area_top_left = 10 | (10 << 10);
    gpu.draw_env.area_bot_right = 20 | (20 << 10);

    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 40, 0, 0, 40, 0x7FFF, false);

    // Inside the area: painted. Outside on each side: untouched.
    try std.testing.expect(gpu.vram.data[15 * 1024 + 12] != 0);
    try expectEqual(@as(u16, 0), gpu.vram.data[9 * 1024 + 12]); // above
    try expectEqual(@as(u16, 0), gpu.vram.data[21 * 1024 + 12]); // below
    try expectEqual(@as(u16, 0), gpu.vram.data[15 * 1024 + 9]); // left
    try expectEqual(@as(u16, 0), gpu.vram.data[15 * 1024 + 21]); // right
}

test "Phase0: triangle check-mask skips pixels whose bit15 is set" {
    var gpu = Gpu.init();
    envFullArea(&gpu);
    gpu.draw_env.mask_bit = 2; // check only

    gpu.vram.data[5 * 1024 + 5] = 0x8000; // masked destination
    gpu.vram.data[6 * 1024 + 5] = 0x0000; // unmasked destination

    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 40, 0, 0, 40, 0x1234, false);

    try expectEqual(@as(u16, 0x8000), gpu.vram.data[5 * 1024 + 5]);
    try expectEqual(@as(u16, 0x1234), gpu.vram.data[6 * 1024 + 5]);
}

test "Phase0: triangle set-mask ORs bit15 into every pixel written" {
    var gpu = Gpu.init();
    envFullArea(&gpu);
    gpu.draw_env.mask_bit = 1; // set only

    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 40, 0, 0, 40, 0x1234, false);

    try expectEqual(@as(u16, 0x9234), gpu.vram.data[6 * 1024 + 5]);
}

test "Phase0: triangle semi-transparency uses the four integer blend modes" {
    // Back = 20/20/20 in 5-bit, front = 10/10/10. The expected values come
    // straight from Color.blend, which is the shared back end putPixel calls;
    // this pins that the rasterizer keeps routing through it.
    const back: u16 = 20 | (20 << 5) | (20 << 10);
    const front: u16 = 10 | (10 << 5) | (10 << 10);

    var mode: u2 = 0;
    while (true) {
        var gpu = Gpu.init();
        envFullArea(&gpu);
        gpu.draw_env.draw_mode = @as(u32, mode) << 5;
        gpu.vram.data[6 * 1024 + 5] = back;

        Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 40, 0, 0, 40, front, true);

        try expectEqual(Color.blend(back, front, mode), gpu.vram.data[6 * 1024 + 5]);
        if (mode == 3) break;
        mode += 1;
    }
}

test "Phase0: a fully transparent texel is skipped, not drawn as black" {
    var gpu = Gpu.init();
    envFullArea(&gpu);
    // 16bpp texture page at VRAM (256, 256), left all-zero so every texel
    // reads 0x0000, which hardware treats as "do not draw". The page must NOT
    // be at (0,0): the triangle draws into rows 0-40 there, so it would be
    // sampling the pixels it is writing and the test would pass for the wrong
    // reason.
    const tpage: u16 = (2 << 7) | (1 << 4) | 4; // 16bpp, page x = 4*64 = 256, page y = 256
    gpu.vram.data[6 * 1024 + 5] = 0xABCD;

    Renderer.drawTexturedTriangle(
        &gpu.vram,
        &gpu.draw_env,
        0, 0, 0, 0,
        40, 0, 40, 0,
        0, 40, 0, 40,
        0x7FFF,
        0,
        tpage,
        false,
        0x25, // textured, raw (bit0 set -> no modulation)
    );

    try expectEqual(@as(u16, 0xABCD), gpu.vram.data[6 * 1024 + 5]);
}
```

Note the `envFullArea` call in the drawing-area test is immediately overwritten — that is deliberate, so every test starts from a known-zero `DrawingEnv` before setting what it cares about.

- [ ] **Step 5: Run the new tests**

Run: `zig build test -Dtest-filter=Phase0`
Expected: PASS — all five. These characterize *current* behaviour; if any fails, the test is wrong, not the renderer. Fix the test before continuing.

- [ ] **Step 6: Run the full unit suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
zig fmt build.zig ps1-core/src/gpu/gpu.zig ps1-core/tests/gpu_test.zig
git add build.zig ps1-core/src/gpu/gpu.zig ps1-core/tests/gpu_test.zig
git commit -m "test(gpu): pin rasterizer invariants before the integer conversion

Adds -Dtest-filter, exports Renderer/Color from gpu.zig, and characterizes
the drawing-area clip, both mask bits, the four blend modes and the
transparent-texel skip. Phase 0 of the Metal renderer design is allowed to
change rendered output; these five behaviours are what it may NOT change.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: Integer edge-function coverage

Replace the scanline span search with three integer edge functions and a top-left fill rule. Interpolation stays `f32` for now — this task changes *which pixels* are covered, nothing else.

**Files:**
- Modify: `ps1-core/src/gpu/renderer.zig:48-176` (`rasterizeTriangle`)
- Test: `ps1-core/tests/gpu_test.zig` (append)

**Interfaces:**
- Consumes: `Renderer`, `Color`, `envFullArea` from Task 1.
- Produces:
  - `fn orient2d(ax: i32, ay: i32, bx: i32, by: i32, cx: i32, cy: i32) i32` — file-private in `renderer.zig`.
  - `fn isTopLeft(dx: i32, dy: i32) bool` — file-private in `renderer.zig`.
  - `Shader.shade` keeps its signature: `fn shade(ctx, w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult`. **Contract change:** `area` is now always **positive**, and `w0/w1/w2` are the un-biased weights in the positive-area normalization, so every one is `>= 0` for a covered pixel. Tasks 3 and 4 depend on both facts.
  - `pub const ShadeResult = struct { color: u16, is_transparent: bool, draw: bool };` in `renderer.zig`, replacing the anonymous struct repeated in all four shaders.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 0 Task 2: integer edge-function coverage.

/// The coverage rule this rasterizer is required to implement, written out
/// independently of the implementation: integer edge functions in the
/// positive-area normalization, biased by the top-left fill rule, ANDed with
/// the drawing area. Used to differential-test rasterizeTriangle.
fn refCovers(
    vx: [3]i32,
    vy: [3]i32,
    px: i32,
    py: i32,
) bool {
    const o2d = struct {
        fn f(ax: i32, ay: i32, bx: i32, by: i32, cx: i32, cy: i32) i32 {
            return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        }
    }.f;
    const topleft = struct {
        fn f(dx: i32, dy: i32) bool {
            return dy > 0 or (dy == 0 and dx < 0);
        }
    }.f;

    const area_signed = o2d(vx[0], vy[0], vx[1], vy[1], vx[2], vy[2]);
    if (area_signed == 0) return false;
    const s: i32 = if (area_signed < 0) -1 else 1;

    var w: [3]i32 = undefined;
    w[0] = s * o2d(vx[1], vy[1], vx[2], vy[2], px, py);
    w[1] = s * o2d(vx[2], vy[2], vx[0], vy[0], px, py);
    w[2] = s * o2d(vx[0], vy[0], vx[1], vy[1], px, py);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const a = (i + 1) % 3;
        const b = (i + 2) % 3;
        const bias: i32 = if (topleft(s * (vx[b] - vx[a]), s * (vy[b] - vy[a]))) -1 else 0;
        w[i] += bias;
    }
    return (w[0] | w[1] | w[2]) > 0;
}

test "Phase0: a sub-pixel sliver triangle covers no pixel centre" {
    // THE RED TEST for this task. Both triangles have |2*area| == 1, i.e. an
    // area of half a pixel, and neither contains a pixel centre under the
    // top-left rule -- so neither may paint anything. The scanline span search
    // paints exactly one pixel for each: it intersects the edges with the
    // scanline using @divTrunc and then applies the edge test, and the span's
    // own endpoint survives.
    //
    // One case per winding (2*area is -1 and +1 respectively), because the
    // sign normalization is the part of this rewrite most likely to be wrong.
    const cases = [2][6]i16{
        .{ 18, 24, 13, 25, 54, 17 },
        .{ 0, 0, 1, 0, 260, 1 },
    };
    for (cases, 0..) |c, i| {
        var gpu = Gpu.init();
        envFullArea(&gpu);
        Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, c[0], c[1], c[2], c[3], c[4], c[5], 0x7FFF, false);

        for (gpu.vram.data, 0..) |px, idx| {
            if (px != 0) {
                std.debug.print("\nsliver {d} painted ({d},{d}) = {x:0>4}\n", .{ i, idx % 1024, idx / 1024, px });
                return error.SliverPainted;
            }
        }
    }
}

test "Phase0: triangle coverage matches the edge-function rule exactly" {
    // A LOCK, not a red test: the two coverage rules agree on ordinary
    // triangles (5 in 3,000 random ones over this box differ, all slivers), so
    // this passes before and after. It is here to stop a later phase drifting
    // the rule, which is the thing Phase B's shader has to match.
    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = rng.random();

    var t: usize = 0;
    while (t < 200) : (t += 1) {
        var gpu = Gpu.init();
        envFullArea(&gpu);

        var vx: [3]i32 = undefined;
        var vy: [3]i32 = undefined;
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            vx[k] = rand.intRangeAtMost(i32, 0, 63);
            vy[k] = rand.intRangeAtMost(i32, 0, 63);
        }

        Renderer.drawTriangle(
            &gpu.vram,
            &gpu.draw_env,
            @intCast(vx[0]), @intCast(vy[0]),
            @intCast(vx[1]), @intCast(vy[1]),
            @intCast(vx[2]), @intCast(vy[2]),
            0x7FFF,
            false,
        );

        var y: i32 = 0;
        while (y < 64) : (y += 1) {
            var x: i32 = 0;
            while (x < 64) : (x += 1) {
                const drawn = gpu.vram.data[@intCast(y * 1024 + x)] != 0;
                const want = refCovers(vx, vy, x, y);
                if (drawn != want) {
                    std.debug.print(
                        "\ntriangle {d} ({d},{d})-({d},{d})-({d},{d}) pixel ({d},{d}): drawn={} want={}\n",
                        .{ t, vx[0], vy[0], vx[1], vy[1], vx[2], vy[2], x, y, drawn, want },
                    );
                    return error.CoverageMismatch;
                }
            }
        }
    }
}

test "Phase0: two triangles sharing an edge paint every pixel exactly once" {
    // Also a LOCK: today's span search already tiles this correctly. It is the
    // human-readable statement of what the fill rule is FOR, and it is the
    // first thing to break if someone "simplifies" the bias or the (w0|w1|w2)
    // test later.
    //
    // Additive semi-transparency (mode 1) over a black background: a pixel
    // painted once reads 8, a pixel painted twice reads 16, a gap reads 0.
    // Quad (0,0)-(31,0)-(31,31)-(0,31) split on the 0-2 diagonal, which is
    // exactly what gp0.zig does to every quad it decodes.
    var gpu = Gpu.init();
    envFullArea(&gpu);
    gpu.draw_env.draw_mode = 1 << 5; // blend mode 1: B + F
    const c: u16 = 8 | (8 << 5) | (8 << 10);

    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 31, 0, 31, 31, c, true);
    Renderer.drawTriangle(&gpu.vram, &gpu.draw_env, 0, 0, 31, 31, 0, 31, c, true);

    var y: usize = 1;
    while (y < 31) : (y += 1) {
        var x: usize = 1;
        while (x < 31) : (x += 1) {
            const px = gpu.vram.data[y * 1024 + x];
            const r = px & 0x1F;
            if (r != 8) {
                std.debug.print("\npixel ({d},{d}) red={d}, want 8 ({s})\n", .{
                    x, y, r,
                    if (r == 0) "gap" else "double-painted",
                });
                return error.SharedEdgeMismatch;
            }
        }
    }
}
```

- [ ] **Step 2: Run them and confirm the expected before-state**

Run: `zig build test -Dtest-filter="Phase0: a sub-pixel sliver"`
Expected: **FAIL** with `error.SliverPainted` reporting `sliver 0 painted (18,24)`. This is the red test.

Run: `zig build test -Dtest-filter="Phase0: triangle coverage"`
Expected: **PASS**. If it fails, `refCovers` is wrong — the two rules agree on the 200 triangles this seed generates, so a failure here is a bug in the test, not in the renderer. Fix it before Step 3, otherwise it cannot lock anything afterwards.

Run: `zig build test -Dtest-filter="Phase0: two triangles sharing"`
Expected: **PASS**, for the same reason.

- [ ] **Step 3: Rewrite `rasterizeTriangle`**

Replace `ps1-core/src/gpu/renderer.zig` lines 48-176 in full. Keep everything above line 48 (`putPixel`) untouched.

```zig
    /// Twice the signed area of (a, b, c). Positive for one winding, negative
    /// for the other; zero for a degenerate triangle.
    fn orient2d(ax: i32, ay: i32, bx: i32, by: i32, cx: i32, cy: i32) i32 {
        return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    }

    /// Top-left fill rule. `dx`/`dy` is the edge's direction vector in the
    /// positive-area winding. An edge that fails this test drops the pixels
    /// landing exactly on it, so two triangles sharing an edge paint each
    /// pixel exactly once instead of leaving a seam or double-blending it.
    fn isTopLeft(dx: i32, dy: i32) bool {
        return dy > 0 or (dy == 0 and dx < 0);
    }

    pub const ShadeResult = struct { color: u16, is_transparent: bool, draw: bool };

    fn rasterizeTriangle(
        vram: *Vram,
        env: *const DrawingEnv,
        x0: i16,
        y0: i16,
        x1: i16,
        y1: i16,
        x2: i16,
        y2: i16,
        allow_transparency: bool,
        comptime Shader: type,
        shader_ctx: anytype,
    ) void {
        const ox: i32 = env.getOffsetX();
        const oy: i32 = env.getOffsetY();

        const vx0: i32 = @as(i32, x0) + ox;
        const vy0: i32 = @as(i32, y0) + oy;
        const vx1: i32 = @as(i32, x1) + ox;
        const vy1: i32 = @as(i32, y1) + oy;
        const vx2: i32 = @as(i32, x2) + ox;
        const vy2: i32 = @as(i32, y2) + oy;

        // Hardware refuses any primitive whose vertices span 1024 or more
        // horizontally, or 512 or more vertically -- it is not clipped, it is
        // dropped outright. Games lean on that: geometry that crosses the near
        // plane projects to enormous saturated screen coordinates, and the
        // drop is what keeps it off the screen. Drawing it instead paints
        // scenery across the camera (Silent Hill's roadside foliage).
        if (@max(vx0, @max(vx1, vx2)) - @min(vx0, @min(vx1, vx2)) >= 1024) return;
        if (@max(vy0, @max(vy1, vy2)) - @min(vy0, @min(vy1, vy2)) >= 512) return;

        const draw_x0: i32 = @intCast(env.area_top_left & 0x3FF);
        const draw_y0: i32 = @intCast((env.area_top_left >> 10) & 0x3FF);
        const draw_x1: i32 = @intCast(env.area_bot_right & 0x3FF);
        const draw_y1: i32 = @intCast((env.area_bot_right >> 10) & 0x3FF);

        const min_x = @max(draw_x0, @max(0, @min(vx0, @min(vx1, vx2))));
        const max_x = @min(draw_x1, @min(constants.vram_width - 1, @max(vx0, @max(vx1, vx2))));
        const min_y = @max(draw_y0, @max(0, @min(vy0, @min(vy1, vy2))));
        const max_y = @min(draw_y1, @min(constants.vram_height - 1, @max(vy0, @max(vy1, vy2))));

        if (min_x > max_x or min_y > max_y) return;

        const area_signed = orient2d(vx0, vy0, vx1, vy1, vx2, vy2);
        if (area_signed == 0) return;

        // Normalize to a positive area by flipping the sign of every edge
        // function rather than by swapping two vertices. Avocado swaps
        // (primitive.h assureCcw), but a swap would permute the attributes the
        // shader indexes by vertex number; the sign flip leaves w_i paired
        // with vertex i, and w_i/area is unchanged because both are negated.
        const s: i32 = if (area_signed < 0) -1 else 1;
        const area: i32 = area_signed * s;

        const dw0dx = s * (vy1 - vy2);
        const dw0dy = s * (vx2 - vx1);
        const dw1dx = s * (vy2 - vy0);
        const dw1dy = s * (vx0 - vx2);
        const dw2dx = s * (vy0 - vy1);
        const dw2dy = s * (vx1 - vx0);

        // The edge for barycentric i runs v[i+1] -> v[i+2] in the normalized
        // winding, so its direction picks up the same sign flip.
        const bias0: i32 = if (isTopLeft(s * (vx2 - vx1), s * (vy2 - vy1))) -1 else 0;
        const bias1: i32 = if (isTopLeft(s * (vx0 - vx2), s * (vy0 - vy2))) -1 else 0;
        const bias2: i32 = if (isTopLeft(s * (vx1 - vx0), s * (vy1 - vy0))) -1 else 0;

        var row0 = s * orient2d(vx1, vy1, vx2, vy2, min_x, min_y) + bias0;
        var row1 = s * orient2d(vx2, vy2, vx0, vy0, min_x, min_y) + bias1;
        var row2 = s * orient2d(vx0, vy0, vx1, vy1, min_x, min_y) + bias2;

        var py = min_y;
        while (py <= max_y) : (py += 1) {
            var w0 = row0;
            var w1 = row1;
            var w2 = row2;

            var px = min_x;
            while (px <= max_x) : (px += 1) {
                // Avocado's coverage test verbatim: a negative term sets the
                // sign bit of the OR, so this means "all three non-negative,
                // and not all three zero".
                if ((w0 | w1 | w2) > 0) {
                    const px16: i16 = @intCast(px);
                    const py16: i16 = @intCast(py);
                    // The bias is a coverage device only -- attributes must be
                    // interpolated from the true barycentric numerators.
                    const out = Shader.shade(shader_ctx, w0 - bias0, w1 - bias1, w2 - bias2, area, px16, py16, allow_transparency);
                    if (out.draw) {
                        putPixel(vram, env, px16, py16, out.color, out.is_transparent);
                    }
                }
                w0 += dw0dx;
                w1 += dw1dx;
                w2 += dw2dx;
            }

            row0 += dw0dy;
            row1 += dw1dy;
            row2 += dw2dy;
        }
    }
```

- [ ] **Step 4: Switch the four shaders to the named `ShadeResult`**

The three existing shader structs (`MonoShader` at `:190`, `ShadedShader` at `:213`, `TexturedShader` at `:405`) each declare their return type as an anonymous `struct { color: u16, is_transparent: bool, draw: bool }`. Replace each occurrence with `ShadeResult`. For example `MonoShader` becomes:

```zig
        const MonoShader = struct {
            color: u16,
            pub fn shade(ctx: @This(), _: i32, _: i32, _: i32, _: i32, _: i16, _: i16, is_transp: bool) ShadeResult {
                return .{ .color = ctx.color, .is_transparent = is_transp, .draw = true };
            }
        };
```

Do the same to `ShadedShader.shade` and `TexturedShader.shade`. Their bodies are unchanged in this task — they still use `f32`; Tasks 3 and 4 convert them.

- [ ] **Step 5: Run the new tests**

Run: `zig build test -Dtest-filter=Phase0`
Expected: PASS — all eight Phase0 tests (five from Task 1, three from this task). The sliver test is the one that flipped.

- [ ] **Step 6: Run the full unit suite**

Run: `zig build test`
Expected: PASS. In particular the four oversized-drop tests and `"GPU triangle rasterizer handles clipped signed coordinates without overflow"` must still pass; they exercise paths this rewrite touches.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-core/src/gpu/renderer.zig ps1-core/tests/gpu_test.zig
git add ps1-core/src/gpu/renderer.zig ps1-core/tests/gpu_test.zig
git commit -m "refactor(gpu): rasterize triangles by integer edge functions

Replaces the scanline span search with three integer edge functions and
Avocado's top-left fill rule. The span search intersected each edge with the
scanline using @divTrunc and clamped the result, which is not a coverage set
any GPU triangle setup can reproduce -- Phase B needs both sides evaluating
the same integer formulas.

Visible effect is small and one-directional: the two rules agree on ordinary
geometry (5 of 3,000 random triangles differ, none over the full VRAM box),
and where they differ the span search painted one extra pixel of a half-pixel
sliver. It never left a gap. The point is expressibility, not pixels.

Winding is normalized by flipping the sign of every edge function rather than
by swapping two vertices, so w_i stays paired with vertex i and the shaders
need no attribute permutation.

Output changes. trace-golden and the PL floors are recaptured once at the end
of Phase 0, not here.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: Exact integer Gouraud interpolation

**Files:**
- Modify: `ps1-core/src/gpu/renderer.zig` (`drawShadedTriangle`'s `ShadedShader`, currently `:213-258`)
- Test: `ps1-core/tests/gpu_test.zig` (append)

**Interfaces:**
- Consumes: `ShadeResult` and the positive-area/non-negative-weight contract from Task 2.
- Produces: `fn interp(w0: i32, w1: i32, w2: i32, area: i32, a0: i32, a1: i32, a2: i32) i32` — file-private in `renderer.zig`, used by this task and Task 4.

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 0 Task 3: exact integer Gouraud interpolation.

/// The interpolation rule this rasterizer is required to implement, written
/// out independently: floor((w0*a0 + w1*a1 + w2*a2) / area) in i64, with the
/// un-biased weights and a positive area.
fn refInterp(vx: [3]i32, vy: [3]i32, px: i32, py: i32, a: [3]i32) i32 {
    const o2d = struct {
        fn f(ax: i32, ay: i32, bx: i32, by: i32, cx: i32, cy: i32) i32 {
            return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        }
    }.f;
    const area_signed = o2d(vx[0], vy[0], vx[1], vy[1], vx[2], vy[2]);
    const s: i32 = if (area_signed < 0) -1 else 1;
    const area = @as(i64, area_signed * s);
    const w0 = @as(i64, s * o2d(vx[1], vy[1], vx[2], vy[2], px, py));
    const w1 = @as(i64, s * o2d(vx[2], vy[2], vx[0], vy[0], px, py));
    const w2 = @as(i64, s * o2d(vx[0], vy[0], vx[1], vy[1], px, py));
    const num = w0 * @as(i64, a[0]) + w1 * @as(i64, a[1]) + w2 * @as(i64, a[2]);
    return @intCast(@divFloor(num, area));
}

test "Phase0: a flat-coloured Gouraud triangle is flat" {
    // THE RED TEST for this task, and it needs no reference implementation:
    // if all three vertex colours are equal, every covered pixel must be that
    // colour. The exact rule gives it for free -- sum(w_i)*a / area == a by the
    // barycentric identity -- while the f32 path divides three weights by the
    // area, multiplies each by the colour and sums, and lands a hair low.
    //
    // This triangle (2*area == 222) has six such pixels at colour 0x808080.
    var gpu = Gpu.init();
    envFullArea(&gpu);

    const c: u32 = 0x00808080; // r = g = b = 128 -> 5-bit 16 each
    const want: u16 = 16 | (16 << 5) | (16 << 10); // 0x4210

    Renderer.drawShadedTriangle(&gpu.vram, &gpu.draw_env, 15, 25, c, 26, 11, c, 23, 35, c, false);

    var painted: usize = 0;
    for (gpu.vram.data, 0..) |px, idx| {
        if (px == 0) continue;
        painted += 1;
        if (px != want) {
            std.debug.print("\npixel ({d},{d}) = {x:0>4}, want {x:0>4}\n", .{ idx % 1024, idx / 1024, px, want });
            return error.FlatTriangleNotFlat;
        }
    }
    try std.testing.expect(painted > 0);
}

test "Phase0: Gouraud shading is the exact integer interpolant" {
    var rng = std.Random.DefaultPrng.init(0x5EED);
    const rand = rng.random();

    var t: usize = 0;
    while (t < 100) : (t += 1) {
        var gpu = Gpu.init();
        envFullArea(&gpu);
        // draw_mode stays 0: dithering off, so the only thing under test is
        // the interpolation.

        var vx: [3]i32 = undefined;
        var vy: [3]i32 = undefined;
        var r: [3]i32 = undefined;
        var g: [3]i32 = undefined;
        var b: [3]i32 = undefined;
        var c: [3]u32 = undefined;
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            vx[k] = rand.intRangeAtMost(i32, 0, 63);
            vy[k] = rand.intRangeAtMost(i32, 0, 63);
            r[k] = rand.intRangeAtMost(i32, 0, 255);
            g[k] = rand.intRangeAtMost(i32, 0, 255);
            b[k] = rand.intRangeAtMost(i32, 0, 255);
            c[k] = @as(u32, @intCast(r[k])) |
                (@as(u32, @intCast(g[k])) << 8) |
                (@as(u32, @intCast(b[k])) << 16);
        }

        Renderer.drawShadedTriangle(
            &gpu.vram,
            &gpu.draw_env,
            @intCast(vx[0]), @intCast(vy[0]), c[0],
            @intCast(vx[1]), @intCast(vy[1]), c[1],
            @intCast(vx[2]), @intCast(vy[2]), c[2],
            false,
        );

        var y: i32 = 0;
        while (y < 64) : (y += 1) {
            var x: i32 = 0;
            while (x < 64) : (x += 1) {
                if (!refCovers(vx, vy, x, y)) continue;
                const px = gpu.vram.data[@intCast(y * 1024 + x)];
                const want_r: u16 = @intCast(std.math.clamp(refInterp(vx, vy, x, y, r), 0, 255) >> 3);
                const want_g: u16 = @intCast(std.math.clamp(refInterp(vx, vy, x, y, g), 0, 255) >> 3);
                const want_b: u16 = @intCast(std.math.clamp(refInterp(vx, vy, x, y, b), 0, 255) >> 3);
                const want = want_r | (want_g << 5) | (want_b << 10);
                if (px != want) {
                    std.debug.print(
                        "\ntriangle {d} pixel ({d},{d}): got {x:0>4} want {x:0>4}\n",
                        .{ t, x, y, px, want },
                    );
                    return error.ShadeMismatch;
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run them to confirm the expected before-state**

Run: `zig build test -Dtest-filter="Phase0: a flat-coloured"`
Expected: **FAIL** with `error.FlatTriangleNotFlat`, reporting `3def` (5-bit 15 in every channel) where `4210` is wanted. Six pixels of this triangle are affected; the test reports the first.

Run: `zig build test -Dtest-filter="Phase0: Gouraud shading"`
Expected: **FAIL** with `error.ShadeMismatch`. Note this sweep is *thin* — the `>> 3` down to 5 bits absorbs most sub-unit `f32` error, so only about one covered pixel in 35,000 diverges and 100 triangles yields roughly one hit. **If it passes, that is fine**: the flat-triangle test above is the gate, and this one is a lock for later phases. Do not chase it.

- [ ] **Step 3: Add `interp` and rewrite `ShadedShader`**

Add `interp` to `renderer.zig`, next to `orient2d` and `isTopLeft`:

```zig
    /// Exact barycentric interpolation of one integer attribute.
    ///
    /// Position-evaluable by construction: a Metal fragment shader gets (px,
    /// py), recomputes the three weights from the plane equations and
    /// evaluates this same expression, with no incremental state to carry.
    /// That is why this is NOT the fixed-point delta stepping Avocado
    /// implements and then disables ("Fixed point has some rounding issue",
    /// render_triangle.cpp) -- stepping accumulates error along a span and
    /// cannot be reproduced per-pixel.
    ///
    /// i64 is load-bearing: the constant term of the expanded plane equation
    /// exceeds i32 for a triangle at the far end of VRAM.
    fn interp(w0: i32, w1: i32, w2: i32, area: i32, a0: i32, a1: i32, a2: i32) i32 {
        const num = @as(i64, w0) * @as(i64, a0) +
            @as(i64, w1) * @as(i64, a1) +
            @as(i64, w2) * @as(i64, a2);
        // area > 0 and, inside the triangle, every w_i >= 0 and every a_i >= 0,
        // so @divFloor and @divTrunc agree; @divFloor is used because it stays
        // defined on the boundary pixels the fill rule admits.
        return @intCast(@divFloor(num, @as(i64, area)));
    }
```

Replace `ShadedShader` (`renderer.zig:213-258`) and its instantiation:

```zig
        const ShadedShader = struct {
            r: [3]i32,
            g: [3]i32,
            b: [3]i32,
            dither_enabled: bool,
            pub fn shade(ctx: @This(), w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult {
                var r = interp(w0, w1, w2, area, ctx.r[0], ctx.r[1], ctx.r[2]);
                var g = interp(w0, w1, w2, area, ctx.g[0], ctx.g[1], ctx.g[2]);
                var b = interp(w0, w1, w2, area, ctx.b[0], ctx.b[1], ctx.b[2]);

                if (ctx.dither_enabled) {
                    const offset: i32 = Color.dither_table[@intCast(@mod(py, 4))][@intCast(@mod(px, 4))];
                    r += offset;
                    g += offset;
                    b += offset;
                }

                // Dither is an 8-bit-scale offset, so it is added before the
                // shift to 5 bits, and the clamp is at 8-bit range.
                const r5: u16 = @intCast(std.math.clamp(r, 0, 255) >> 3);
                const g5: u16 = @intCast(std.math.clamp(g, 0, 255) >> 3);
                const b5: u16 = @intCast(std.math.clamp(b, 0, 255) >> 3);

                return .{ .color = (b5 << 10) | (g5 << 5) | r5, .is_transparent = is_transp, .draw = true };
            }
        };
        rasterizeTriangle(vram, env, x0, y0, x1, y1, x2, y2, is_transparent, ShadedShader, ShadedShader{
            .r = .{ @intCast(c0 & 0xFF), @intCast(c1 & 0xFF), @intCast(c2 & 0xFF) },
            .g = .{ @intCast((c0 >> 8) & 0xFF), @intCast((c1 >> 8) & 0xFF), @intCast((c2 >> 8) & 0xFF) },
            .b = .{ @intCast((c0 >> 16) & 0xFF), @intCast((c1 >> 16) & 0xFF), @intCast((c2 >> 16) & 0xFF) },
            .dither_enabled = (env.draw_mode & (1 << 9)) != 0,
        });
```

- [ ] **Step 4: Run the tests**

Run: `zig build test -Dtest-filter="Phase0: a flat-coloured"`
Expected: PASS.

Run: `zig build test -Dtest-filter="Phase0: Gouraud shading"`
Expected: PASS.

- [ ] **Step 5: Run the full unit suite**

Run: `zig build test`
Expected: PASS. `"GPU Shaded Line (0x50)"` and `"GPU Shaded Polyline (0x58)"` go through `drawShadedLine`, not this path, so they are unaffected — if they fail, something in this task leaked.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/gpu/renderer.zig ps1-core/tests/gpu_test.zig
git add ps1-core/src/gpu/renderer.zig ps1-core/tests/gpu_test.zig
git commit -m "refactor(gpu): interpolate Gouraud colours in exact integers

Replaces the f32 barycentrics with floor((w0*a0 + w1*a1 + w2*a2) / area) in
i64. The expression is position-evaluable, which is what a fragment shader
needs; Avocado's fixed-point stepping is not, and is disabled in Avocado for
its rounding error besides.

Dither is now added at 8-bit scale and clamped to 0..255 before the shift to
5 bits, matching Avocado's ditherLUT. That is what the f32 path already did
in effect.

Output changes. Recapture happens at the end of Phase 0.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: Exact integer texcoord interpolation

**Files:**
- Modify: `ps1-core/src/gpu/renderer.zig` (`drawTexturedTriangle`'s `TexturedShader`, currently `:405-470`)
- Test: `ps1-core/tests/gpu_test.zig` (append)

**Interfaces:**
- Consumes: `interp` (Task 3), `refInterp`/`refCovers` (Tasks 2-3).
- Produces: no new symbols.

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 0 Task 4: exact integer texcoord interpolation.

test "Phase0: textured triangle samples the exact integer texel coordinate" {
    // Unlike the Gouraud sweep this one is reliably red: texcoords are used at
    // full 8-bit precision, with no >> 3 to absorb the f32 error. Expect
    // roughly seven diverging pixels at this seed and sweep size.
    var rng = std.Random.DefaultPrng.init(0x7E77);
    const rand = rng.random();

    var t: usize = 0;
    while (t < 200) : (t += 1) {
        var gpu = Gpu.init();
        envFullArea(&gpu);

        // A 16bpp texture page at VRAM (256, 256): every texel encodes its own
        // (u, v) so a wrong coordinate is visible rather than plausible.
        // Bit15 stays clear (no STP) and the value is never 0x0000, which
        // would be read as "skip this texel".
        var v: usize = 0;
        while (v < 256) : (v += 1) {
            var u: usize = 0;
            while (u < 256) : (u += 1) {
                gpu.vram.data[(256 + v) * 1024 + 256 + u] =
                    @intCast(1 + ((u * 7 + v * 131) & 0x7FFE));
            }
        }
        const tpage: u16 = (2 << 7) | (1 << 4) | 4; // 16bpp, page x = 4*64 = 256, page y = 256

        var vx: [3]i32 = undefined;
        var vy: [3]i32 = undefined;
        var tu: [3]i32 = undefined;
        var tv: [3]i32 = undefined;
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            // 0..127, not 0..63: bigger triangles have bigger areas, and the
            // f32 reciprocal 1/area is where the error comes from.
            vx[k] = rand.intRangeAtMost(i32, 0, 127);
            vy[k] = rand.intRangeAtMost(i32, 0, 127);
            tu[k] = rand.intRangeAtMost(i32, 0, 255);
            tv[k] = rand.intRangeAtMost(i32, 0, 255);
        }

        Renderer.drawTexturedTriangle(
            &gpu.vram,
            &gpu.draw_env,
            @intCast(vx[0]), @intCast(vy[0]), @intCast(tu[0]), @intCast(tv[0]),
            @intCast(vx[1]), @intCast(vy[1]), @intCast(tu[1]), @intCast(tv[1]),
            @intCast(vx[2]), @intCast(vy[2]), @intCast(tu[2]), @intCast(tv[2]),
            0x7FFF,
            0,
            tpage,
            false,
            0x25, // raw texture (opcode bit0 set): no modulation, no dither
        );

        var y: i32 = 0;
        while (y < 128) : (y += 1) {
            var x: i32 = 0;
            while (x < 128) : (x += 1) {
                if (!refCovers(vx, vy, x, y)) continue;
                const u: usize = @intCast(std.math.clamp(refInterp(vx, vy, x, y, tu), 0, 255));
                const uv: usize = @intCast(std.math.clamp(refInterp(vx, vy, x, y, tv), 0, 255));
                const want = gpu.vram.data[(256 + uv) * 1024 + 256 + u];
                const got = gpu.vram.data[@intCast(y * 1024 + x)];
                if (got != want) {
                    std.debug.print(
                        "\ntriangle {d} pixel ({d},{d}): got {x:0>4} want {x:0>4} (u={d} v={d})\n",
                        .{ t, x, y, got, want, u, uv },
                    );
                    return error.TexcoordMismatch;
                }
            }
        }
    }
}
```

Note the triangles now reach x/y = 127 while the texture page sits at VRAM (256, 256), so the drawn region and the sampled region still do not overlap.

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test -Dtest-filter="Phase0: textured triangle samples"`
Expected: FAIL with `error.TexcoordMismatch` — `@intFromFloat(@abs(f0*tu0 + f1*tu1 + f2*tu2))` truncates a float toward zero where the exact rule floors an integer quotient, and the texture page encodes the difference as a visibly wrong texel.

**If it passes unexpectedly:** raise the sweep to 600 triangles. Simulation of this exact seed and sweep size found seven diverging pixels out of ~270,000 covered, so a pass more likely means the test is not reproducing the real shader path — check that dithering is off and that the opcode really is raw before widening the sweep.

- [ ] **Step 3: Rewrite `TexturedShader`**

Replace `renderer.zig:405-470` (the `TexturedShader` struct and the `rasterizeTriangle` call that instantiates it):

```zig
        const TexturedShader = struct {
            vram: *Vram,
            color: u16,
            tu: [3]i32,
            tv: [3]i32,
            tex_depth: u32,
            tpage_x: u16,
            tpage_y: u16,
            clut_x: u16,
            clut_y: u16,
            opcode: u8,
            tex_window: u32,
            dither_enabled: bool,

            pub fn shade(ctx: @This(), w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult {
                // u/v are 8-bit fields on the wire, and the interpolant of
                // three in-range values is in range; the clamp only bounds the
                // boundary pixels the fill rule admits.
                const u: u32 = @intCast(std.math.clamp(interp(w0, w1, w2, area, ctx.tu[0], ctx.tu[1], ctx.tu[2]), 0, 255));
                const v: u32 = @intCast(std.math.clamp(interp(w0, w1, w2, area, ctx.tv[0], ctx.tv[1], ctx.tv[2]), 0, 255));

                // T-Window masking
                const mask_x = (ctx.tex_window & 0x1F) * 8;
                const mask_y = ((ctx.tex_window >> 5) & 0x1F) * 8;
                const offset_x = ((ctx.tex_window >> 10) & 0x1F) * 8;
                const offset_y = ((ctx.tex_window >> 15) & 0x1F) * 8;

                const final_u = (u & ~mask_x) | (offset_x & mask_x);
                const final_v = (v & ~mask_y) | (offset_y & mask_y);

                const texel = Color.fetchTexel(ctx.vram, ctx.tex_depth, ctx.tpage_x, ctx.tpage_y, ctx.clut_x, ctx.clut_y, final_u, final_v);

                if (texel == 0) return .{ .color = 0, .is_transparent = false, .draw = false };

                var final_texel = texel;
                if ((ctx.opcode & 1) == 0) { // Modulation
                    final_texel = Color.modulate(texel, ctx.color, @as(i32, px), @as(i32, py), ctx.dither_enabled);
                }

                return .{ .color = final_texel, .is_transparent = is_transp and ((final_texel & 0x8000) != 0), .draw = true };
            }
        };

        rasterizeTriangle(vram, env, x0, y0, x1, y1, x2, y2, allow_transparency, TexturedShader, TexturedShader{
            .vram = vram,
            .color = color,
            .tu = .{ tu0, tu1, tu2 },
            .tv = .{ tv0, tv1, tv2 },
            .tex_depth = (tpage >> 7) & 3,
            .tpage_x = (tpage & 0xF) * 64,
            .tpage_y = if ((tpage & 0x10) != 0) @as(u16, 256) else 0,
            .clut_x = (clut & 0x3F) * 16,
            .clut_y = (clut >> 6) & 0x1FF,
            .opcode = opcode,
            .tex_window = env.tex_window,
            .dither_enabled = (env.draw_mode & (1 << 9)) != 0,
        });
```

`tu0..tv2` are `u8` parameters and `.tu = .{ tu0, tu1, tu2 }` coerces them to `[3]i32` implicitly; no `@intCast` is needed on that line.

- [ ] **Step 4: Run the test**

Run: `zig build test -Dtest-filter="Phase0: textured triangle samples"`
Expected: PASS.

- [ ] **Step 5: Run the full unit suite**

Run: `zig build test`
Expected: PASS. `"GPU textured rectangle uses direct blitter without triangle seam"` and `"GPU textured polygon latches its texpage into GPUSTAT"` both exercise nearby code; they must stay green.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/gpu/renderer.zig ps1-core/tests/gpu_test.zig
git add ps1-core/src/gpu/renderer.zig ps1-core/tests/gpu_test.zig
git commit -m "refactor(gpu): interpolate texcoords in exact integers

Drops the last f32 in the triangle path: @intFromFloat(@abs(f0*tu0 + ...))
becomes the same exact i64 interpolant the Gouraud path now uses, clamped to
the 8-bit u/v range before the texture window mask.

Output changes. Recapture happens at the end of Phase 0.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: Integer `modulate` (no output change)

`color.zig`'s `modulate` divides by 16.0 in `f32`. Because 16 is a power of two the float division is exact and the result already matches integer floor division for every 5-bit input — so this task is a pure conversion, and the test proves it by pinning the whole input domain.

**Files:**
- Modify: `ps1-core/src/gpu/color.zig:99-122`
- Test: `ps1-core/tests/gpu_test.zig` (append)

**Interfaces:**
- Consumes: `Color` export from Task 1.
- Produces: `Color.modulate` keeps its exact signature `fn modulate(texel: u16, color: u16, px: i32, py: i32, dither_enabled: bool) u16`.

- [ ] **Step 1: Write the test (expected to pass before AND after)**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 0 Task 5: modulate goes integer without changing its output.

test "Phase0: modulate is exhaustively unchanged by the integer conversion" {
    // The full domain: every 5-bit texel channel against every 5-bit colour
    // channel, dither off. The expected value is written out here as the rule
    // rather than referring to the implementation, so this pins the table
    // across the conversion in Task 5 and detects the deliberate change in
    // Task 6.
    var t: u16 = 0;
    while (t < 32) : (t += 1) {
        var c: u16 = 0;
        while (c < 32) : (c += 1) {
            const texel: u16 = t | (t << 5) | (t << 10);
            const color: u16 = c | (c << 5) | (c << 10);
            const want5: u16 = @min(@divFloor(t * c, 16), 31);
            const want: u16 = want5 | (want5 << 5) | (want5 << 10);
            try expectEqual(want, Color.modulate(texel, color, 0, 0, false));
        }
    }
}

test "Phase0: modulate keeps the texel's STP bit" {
    try expectEqual(@as(u16, 0x8000), Color.modulate(0x8000, 0x0000, 0, 0, false) & 0x8000);
    try expectEqual(@as(u16, 0x0000), Color.modulate(0x0001, 0x7FFF, 0, 0, false) & 0x8000);
}
```

- [ ] **Step 2: Run to confirm it passes against the current f32 code**

Run: `zig build test -Dtest-filter="Phase0: modulate"`
Expected: PASS. This is the characterization step — it establishes the table the conversion must reproduce. If it fails, the rule above is wrong; correct the *test* from the current implementation's actual output before continuing.

- [ ] **Step 3: Convert `modulate` to integers**

Replace `ps1-core/src/gpu/color.zig:99-122`:

```zig
pub fn modulate(texel: u16, color: u16, px: i32, py: i32, dither_enabled: bool) u16 {
    const tr: i32 = texel & 0x1F;
    const tg: i32 = (texel >> 5) & 0x1F;
    const tb: i32 = (texel >> 10) & 0x1F;
    const cr: i32 = color & 0x1F;
    const cg: i32 = (color >> 5) & 0x1F;
    const cb: i32 = (color >> 10) & 0x1F;

    var r = @divFloor(tr * cr, 16);
    var g = @divFloor(tg * cg, 16);
    var b = @divFloor(tb * cb, 16);

    if (dither_enabled) {
        const offset: i32 = dither_table[@intCast(@mod(py, 4))][@intCast(@mod(px, 4))];
        r += offset;
        g += offset;
        b += offset;
    }

    const r5: u16 = @intCast(std.math.clamp(r, 0, 31));
    const g5: u16 = @intCast(std.math.clamp(g, 0, 31));
    const b5: u16 = @intCast(std.math.clamp(b, 0, 31));
    return r5 | (g5 << 5) | (b5 << 10) | (texel & 0x8000);
}
```

The doc comment above the function stays as it is.

- [ ] **Step 4: Run the tests**

Run: `zig build test -Dtest-filter="Phase0: modulate"`
Expected: PASS — the same table, now computed in integers.

- [ ] **Step 5: Run the full unit suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Confirm the conversion really is output-neutral**

Run: `zig build test-roms-pl -Doptimize=ReleaseFast`
Expected: The `[PL] ...` match counts for the five GPU/hello-world tests are **identical** to the run at the end of Task 4. Record both sets of numbers in the commit message. Tasks 2-4 moved them; this task must not.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-core/src/gpu/color.zig ps1-core/tests/gpu_test.zig
git add ps1-core/src/gpu/color.zig ps1-core/tests/gpu_test.zig
git commit -m "refactor(gpu): compute texture modulation in integers

Division by 16.0 in f32 is exact for a power of two, so this reproduces the
existing table bit for bit -- pinned exhaustively over all 32x32 5-bit input
pairs. The point is Phase B: a Metal fragment shader must not have to
reproduce an f32 expression to stay byte-identical at 1x.

PL match counts unchanged by this commit.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 6: Correct `modulate`'s dither scale

**Independently rejectable.** Everything before this is required by the spec; this fixes a bug found while doing it. If the Task 8 A/B shows a regression attributable to dithered modulated textures, revert this one commit and leave the rest of Phase 0 standing.

The bug: `dither_table` holds offsets in `-4..+3`, which are **8-bit** channel units. `drawShadedTriangle` adds them to an 8-bit value and then shifts to 5 bits — correct. `modulate` adds them to a value already reduced to 5 bits, making the dither eight times too strong. Avocado's `ditherLUT[y&3][x&3][color]` is indexed by an 8-bit channel and returns an 8-bit channel, so the 8-bit scale is the reference behaviour.

**Files:**
- Modify: `ps1-core/src/gpu/color.zig` (`modulate`, as rewritten in Task 5)
- Test: `ps1-core/tests/gpu_test.zig` (append)

**Interfaces:**
- Consumes: `Color.modulate` from Task 5. Signature unchanged.
- Produces: nothing new. The dither-off behaviour pinned by Task 5's exhaustive test is unchanged — only the dither-on path moves.

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 0 Task 6: modulate's dither offset is an 8-bit-scale offset.

test "Phase0: modulate dithers at 8-bit scale like the Gouraud path" {
    // texel channel 16, colour channel 16 -> product 256, i.e. 8-bit value 128
    // and 5-bit value 16. The dither offsets are 8-bit units, so the strongest
    // one (-4) may move the 5-bit result by at most one step, and usually by
    // none at all. Applied at 5-bit scale it moves it by four.
    const texel: u16 = 16 | (16 << 5) | (16 << 10);
    const color: u16 = 16 | (16 << 5) | (16 << 10);

    // dither_table[0][0] == -4: 128 - 4 = 124, >> 3 == 15.
    try expectEqual(@as(u16, 15), Color.modulate(texel, color, 0, 0, true) & 0x1F);
    // dither_table[1][2] == 3: 128 + 3 = 131, >> 3 == 16.
    try expectEqual(@as(u16, 16), Color.modulate(texel, color, 2, 1, true) & 0x1F);
}

test "Phase0: modulate dither cannot push a channel out of range" {
    const white: u16 = 0x7FFF;
    // Full texel * unity colour (16) is 8-bit 248; +3 dither stays inside 255.
    try expectEqual(@as(u16, 31), Color.modulate(white, 16 | (16 << 5) | (16 << 10), 2, 1, true) & 0x1F);
    // Black texel with the most negative dither must clamp at 0, not wrap.
    try expectEqual(@as(u16, 0), Color.modulate(0x0000, white, 0, 0, true) & 0x1F);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test -Dtest-filter="Phase0: modulate dither"`
Expected: FAIL — the first assertion gets `12` (16 - 4 at 5-bit scale) where 15 is expected.

- [ ] **Step 3: Move the dither to 8-bit scale**

In `ps1-core/src/gpu/color.zig`, change `modulate`'s three product lines and its clamp:

```zig
    // The product of two 5-bit channels at 8-bit scale: (t<<3)*(c<<3) >> 7 is
    // (t*c) >> 1. Working here rather than at 5-bit scale is what makes the
    // dither offsets -- which are 8-bit channel units, the same ones the
    // Gouraud path uses -- mean what they say.
    var r = (tr * cr) >> 1;
    var g = (tg * cg) >> 1;
    var b = (tb * cb) >> 1;

    if (dither_enabled) {
        const offset: i32 = dither_table[@intCast(@mod(py, 4))][@intCast(@mod(px, 4))];
        r += offset;
        g += offset;
        b += offset;
    }

    const r5: u16 = @intCast(std.math.clamp(r, 0, 255) >> 3);
    const g5: u16 = @intCast(std.math.clamp(g, 0, 255) >> 3);
    const b5: u16 = @intCast(std.math.clamp(b, 0, 255) >> 3);
    return r5 | (g5 << 5) | (b5 << 10) | (texel & 0x8000);
```

Note `(t*c) >> 1` then `>> 3` is `(t*c) >> 4`, which is `@divFloor(t*c, 16)` — so the dither-**off** result is unchanged and Task 5's exhaustive test still holds. That is the check that this change is confined to the dithered path.

- [ ] **Step 4: Run the tests**

Run: `zig build test -Dtest-filter="Phase0: modulate"`
Expected: PASS — all four modulate tests, including Task 5's exhaustive dither-off table.

- [ ] **Step 5: Run the full unit suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src/gpu/color.zig ps1-core/tests/gpu_test.zig
git add ps1-core/src/gpu/color.zig ps1-core/tests/gpu_test.zig
git commit -m "fix(gpu): dither modulated texels at 8-bit scale

dither_table holds 8-bit channel offsets (-4..+3). drawShadedTriangle adds
them to an 8-bit value and then shifts to 5 bits; modulate was adding them to
a value already reduced to 5 bits, making its dither eight times too strong.
Avocado's ditherLUT is indexed by and returns an 8-bit channel.

The dither-off table is bit-identical, which the exhaustive 32x32 test pins.
This commit is independently revertible if the Phase 0 A/B blames it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 7: Integer shaded-line gradient

The last `f32` in `renderer.zig`. Not named in the spec's § The 1× gate — that section lists the triangle paths and `modulate` — but `drawShadedLine` is one of the seven `Renderer` entry points the Phase A stream carries and Phase B must reproduce on the GPU, and it interpolates in `f32` by accumulation, which is neither exact nor position-evaluable. Converting it here keeps Phase 0 as the single output-changing phase.

**Files:**
- Modify: `ps1-core/src/gpu/renderer.zig:310-382` (`drawShadedLine`)
- Test: `ps1-core/tests/gpu_test.zig` (append)

**Interfaces:**
- Consumes: nothing from earlier tasks beyond `Renderer`.
- Produces: no new symbols. `drawShadedLine` keeps its signature.

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 0 Task 7: exact integer gradient along a shaded line.

test "Phase0: shaded line gradient is the exact integer interpolant" {
    // Horizontal line from (0,0) to (20,0), red 0 -> 112. Bresenham takes one
    // x step per pixel, so pixel k is step k of 20 and the exact channel value
    // is r0 + floor((r1 - r0) * k / steps).
    //
    // The endpoints matter: 112/20 = 5.6 is not representable in f32, so the
    // running sum drifts low and lands one 5-bit level short at k = 10 (6
    // instead of 7) and again at k = 20 (13 instead of 14) -- the FAR ENDPOINT
    // of the line does not get the far vertex's colour. A gradient whose step
    // is exact in f32, such as 255 over 30 steps (8.5), does not diverge at
    // all; do not "simplify" these numbers.
    var gpu = Gpu.init();
    envFullArea(&gpu);

    const c0: u32 = 0x00000000; // r = 0
    const c1: u32 = 0x00000070; // r = 112

    Renderer.drawShadedLine(&gpu.vram, &gpu.draw_env, 0, 0, c0, 20, 0, c1, false);

    var k: i32 = 0;
    while (k <= 20) : (k += 1) {
        const exact = @divFloor(112 * k, 20);
        const want: u16 = @intCast(std.math.clamp(exact, 0, 255) >> 3);
        const got = gpu.vram.data[@intCast(k)] & 0x1F;
        if (got != want) {
            std.debug.print("\nstep {d}: got r={d} want r={d}\n", .{ k, got, want });
            return error.LineGradientMismatch;
        }
    }
}

test "Phase0: a zero-length shaded line paints the first endpoint's colour" {
    var gpu = Gpu.init();
    envFullArea(&gpu);
    const c0: u32 = 0x000000F8; // r = 248 -> 5-bit 31
    Renderer.drawShadedLine(&gpu.vram, &gpu.draw_env, 7, 7, c0, 7, 7, 0x00000000, false);
    try expectEqual(@as(u16, 31), gpu.vram.data[7 * 1024 + 7] & 0x1F);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test -Dtest-filter="Phase0: shaded line"`
Expected: FAIL with `error.LineGradientMismatch` reporting `step 10: got r=6 want r=7`.

**If it passes unexpectedly:** the Bresenham walk is not taking one step per pixel for this line, so `k` and the pixel index have desynchronised. Check that before touching the endpoints — the divergence at k = 10 and k = 20 was verified by simulating both gradients in `f32`.

- [ ] **Step 3: Rewrite `drawShadedLine`**

Replace `ps1-core/src/gpu/renderer.zig:310-382` in full:

```zig
    pub fn drawShadedLine(vram: *Vram, env: *const DrawingEnv, x0: i16, y0: i16, c0: u32, x1: i16, y1: i16, c1: u32, is_transparent: bool) void {
        const ox = env.getOffsetX();
        const oy = env.getOffsetY();
        var cx = x0 + ox;
        var cy = y0 + oy;
        const target_x = x1 + ox;
        const target_y = y1 + oy;
        const dx = @abs(target_x - cx);
        const dy = @abs(target_y - cy);
        // Same 1023x511 refusal the triangle rasterizer applies -- hardware
        // drops an oversized line rather than clipping it.
        if (dx >= 1024 or dy >= 512) return;
        const sx: i16 = if (cx < target_x) 1 else -1;
        const sy: i16 = if (cy < target_y) 1 else -1;
        var err = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));

        const r0: i32 = @intCast(c0 & 0xFF);
        const g0: i32 = @intCast((c0 >> 8) & 0xFF);
        const b0: i32 = @intCast((c0 >> 16) & 0xFF);
        const r1: i32 = @intCast(c1 & 0xFF);
        const g1: i32 = @intCast((c1 >> 8) & 0xFF);
        const b1: i32 = @intCast((c1 >> 16) & 0xFF);

        const steps: i32 = @intCast(@max(dx, dy));
        const dither_enabled = (env.draw_mode & (1 << 9)) != 0;

        // The channel at step k is r0 + floor((r1 - r0) * k / steps): exact,
        // and evaluable from k alone rather than from an accumulator, which is
        // what a Phase B shader would need. The old code accumulated an f32
        // (r1 - r0) / steps and drifted below the true value along the span.
        var k: i32 = 0;
        while (true) {
            var r = r0;
            var g = g0;
            var b = b0;
            if (steps != 0) {
                r += @divFloor((r1 - r0) * k, steps);
                g += @divFloor((g1 - g0) * k, steps);
                b += @divFloor((b1 - b0) * k, steps);
            }

            if (dither_enabled) {
                const offset: i32 = Color.dither_table[@intCast(@mod(cy, 4))][@intCast(@mod(cx, 4))];
                r += offset;
                g += offset;
                b += offset;
            }

            const r5: u16 = @intCast(std.math.clamp(r, 0, 255) >> 3);
            const g5: u16 = @intCast(std.math.clamp(g, 0, 255) >> 3);
            const b5: u16 = @intCast(std.math.clamp(b, 0, 255) >> 3);

            putPixel(vram, env, cx, cy, (b5 << 10) | (g5 << 5) | r5, is_transparent);
            if (cx == target_x and cy == target_y) break;
            const e2 = 2 * err;
            if (e2 > -@as(i32, @intCast(dy))) {
                err -= @as(i32, @intCast(dy));
                cx += sx;
            }
            if (e2 < @as(i32, @intCast(dx))) {
                err += @as(i32, @intCast(dx));
                cy += sy;
            }
            k += 1;
        }
    }
```

This also folds the old `steps == 0` early-return (`:334-340`) into the loop: with `steps == 0` the gradient term is skipped and the single pixel gets `c0`, which is what the early return did — except it also skipped dithering, and now does not. That is a deliberate simplification; the second test above pins the single-pixel colour.

- [ ] **Step 4: Run the tests**

Run: `zig build test -Dtest-filter="Phase0: shaded line"`
Expected: PASS.

Run: `zig build test -Dtest-filter="GPU Shaded"`
Expected: PASS — `"GPU Shaded Line (0x50)"` and `"GPU Shaded Polyline (0x58)"`, the pre-existing coverage of this path.

- [ ] **Step 5: Run the full unit suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Verify no `f32` remains in the rasterizer**

Run: `grep -n "f32\|floatFromInt\|intFromFloat" ps1-core/src/gpu/renderer.zig ps1-core/src/gpu/color.zig`
Expected: no output. If anything matches, it was missed by Tasks 3-7 and must be converted before this commit.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-core/src/gpu/renderer.zig ps1-core/tests/gpu_test.zig
git add ps1-core/src/gpu/renderer.zig ps1-core/tests/gpu_test.zig
git commit -m "refactor(gpu): interpolate the shaded-line gradient in exact integers

The last f32 in the rasterizer. drawShadedLine accumulated (c1-c0)/steps as a
float, which drifts below the true value along a span and is not evaluable
from the step index alone. Replaced with c0 + floor((c1-c0)*k / steps).

The zero-length early return folds into the loop, which means a single-pixel
shaded line now dithers like every other pixel.

renderer.zig and color.zig now contain no floating point at all.

Output changes. Recapture is the next commit.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 8: The Phase 0 gate — A/B review and baseline recapture

The one recapture Phase 0 is allowed. Everything downstream runs against what this task produces, so the review comes **before** the recapture, not after.

**Files:**
- Modify: `ps1-core/tests/goldens/trace/*.txt` (10 files, regenerated)
- Modify: `test-roms/peterlemon/*/floor.txt` (6 files, regenerated)

**Interfaces:**
- Consumes: the finished renderer from Tasks 2-7.
- Produces: the frozen baseline Phases A-D verify against.

- [ ] **Step 1: Build a pre-Phase-0 reference binary**

Find the commit before Task 1 (`b9ef598` at the time this plan was written — confirm with `git log --oneline`), and build it in a throwaway worktree so both binaries exist at once:

```bash
git worktree add /tmp/ps1-phase0-base b9ef598
cd /tmp/ps1-phase0-base && zig build -Doptimize=ReleaseFast && cd -
```

The reference `ps1-trace` is then `/tmp/ps1-phase0-base/zig-out/bin/ps1-trace`. Build the current tree too:

```bash
zig build -Doptimize=ReleaseFast
```

- [ ] **Step 2: Capture before/after frames for the four gate games**

Run from the repo root — `ps1-trace` takes absolute BIOS and disc paths but writes snapshots relative to CWD, and both binaries must see the same discs.

```bash
mkdir -p /tmp/ab
for side in base head; do
  BIN=$([ $side = base ] && echo /tmp/ps1-phase0-base/zig-out/bin/ps1-trace || echo ./zig-out/bin/ps1-trace)
  mkdir -p /tmp/ab/croc-$side /tmp/ab/spyro-$side /tmp/ab/sh-$side /tmp/ab/crash-$side
  $BIN SCPH-1001_BIOS_1995_US.bin "games/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.cue" 900000000 /tmp/ab/croc-$side explore
  $BIN SCPH-1001_BIOS_1995_US.bin "games/Spyro the Dragon (USA)/Spyro the Dragon (USA).cue" 900000000 /tmp/ab/spyro-$side explore
  $BIN SCPH-1001_BIOS_1995_US.bin "games/Silent Hill (USA)/Silent Hill (USA).cue" 900000000 /tmp/ab/sh-$side explore
  $BIN SCPH-7502_BIOS_1997_EU.bin "games/Crash Bandicoot (Europe) (EDC)/Crash Bandicoot (Europe) (EDC).cue" 900000000 /tmp/ab/crash-$side explore
done
```

`explore` is deterministic (a fixed LCG), so the two sides walk the identical input schedule and the frames are directly comparable. Crash is a PAL rip and needs `SCPH-7502`, per `ps1-golden`'s own BIOS-by-region rule; a US BIOS stops it at the region-lock screen and wastes the run.

- [ ] **Step 3: Review the frames**

```bash
for g in croc spyro sh crash; do
  echo "== $g =="
  for f in /tmp/ab/$g-base/frame_*.ppm; do
    n=$(basename $f)
    cmp -s $f /tmp/ab/$g-head/$n && echo "  $n identical" || echo "  $n DIFFERS"
  done
done
```

Differences are **expected** — the rasterizer changed. The gate is a human look, not `cmp`. Open each differing pair (Preview opens `.ppm` on macOS: `open /tmp/ab/croc-base/frame_300.ppm /tmp/ab/croc-head/frame_300.ppm`) and answer, per game:

- Does the same content appear on both sides — same scene, same geometry, same text?
- Are there new gaps, seams along quad diagonals, or missing polygons?
- Are the colour gradients smoother, the same, or banded?
- Does any run get *further* or *less far* than the other? A run that stops advancing where the other keeps going is a hang, not a rendering difference, and blocks the phase.

Write the verdict into the commit message. An improvement or a wash is expected; a visible regression is a bug and must be traced to a task and fixed before recapturing.

- [ ] **Step 4: Review the PeterLemon deltas**

`test-roms/` is committed, so the baseline worktree has the ROMs and their references. `SCPH-1001_BIOS_1995_US.bin` is **not** — BIOS files are gitignored — and the PL harness loads it relative to the process CWD, so copy it in first or every test in the baseline run fails on a missing file:

```bash
cp SCPH-1001_BIOS_1995_US.bin /tmp/ps1-phase0-base/
(cd /tmp/ps1-phase0-base && zig build test-roms-pl -Doptimize=ReleaseFast 2>&1 | grep '^\[PL\]') > /tmp/ab/pl-base.txt
zig build test-roms-pl -Doptimize=ReleaseFast 2>&1 | grep '^\[PL\]' > /tmp/ab/pl-head.txt
diff -u /tmp/ab/pl-base.txt /tmp/ab/pl-head.txt
```

For each of the six tests, record the before and after pixel-match percentage. The floors today are:

| test | floor |
|---|---|
| `hello-world` | 70895 |
| `cpu/add` | 60679 |
| `gpu/render-line` | 66542 |
| `gpu/render-polygon` | 55182 |
| `gpu/render-rectangle` | 65185 |
| `gpu/render-texture-polygon` | 59947 |

`cpu/add` and `hello-world` render text through the rectangle/texture paths and should barely move. `gpu/render-polygon` and `gpu/render-texture-polygon` are the two that exercise the converted triangle path most directly — an increase is the expected outcome, since the reference images come from hardware and the conversion moves the rasterizer toward it. **A decrease of more than ~1% on any test is a regression**: bisect it across Tasks 2, 3, 4, 6 and 7 (each is one commit) before continuing.

- [ ] **Step 5: Re-pin the PeterLemon floors**

```bash
PS1_UPDATE_GOLDENS=1 zig build test-roms-pl -Doptimize=ReleaseFast
zig build test-roms-pl -Doptimize=ReleaseFast
```

Expected: the second run passes with every match count exactly at its new floor.

- [ ] **Step 6: Recapture the trace goldens**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- capture
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

Expected: `verify` reports OK for every workload that has a golden. Note that `resident-evil-usa` has a golden but its disc may not be present, and a disc in `games/` without a golden makes `verify` exit non-zero — that is a known non-regression, not something this task introduces. Compare `git diff --stat ps1-core/tests/goldens/trace/` against the list of workloads: every one that renders should show movement in its `vram`, `gpu` and `ram` hashes. A workload whose `vram` hash did **not** move despite the rasterizer changing is suspicious — check it did not simply fail to boot.

- [ ] **Step 7: Run everything one last time**

```bash
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build test-roms-ja -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

Expected: unit suite green; PL green at the new floors; JA still **12/17 with the same five failures** (`mdec/4bit`, `mdec/8bit`, `mdec/step-by-step-log`, `cdrom/timing`, `cdrom/getloc`) — none of them is a rasterizer test, so a sixth failure means this phase broke something; `trace-golden -- verify` green.

- [ ] **Step 8: Commit the recapture on its own**

```bash
git add ps1-core/tests/goldens/trace test-roms/peterlemon
git commit -m "chore(gpu): recapture the Phase 0 rasterizer baseline

Phase 0 of the Metal renderer design converted the software rasterizer to
integer edge functions with exact integer interpolation, which is the one
deliberate output change in the project. This commit re-pins everything that
measured the old output, once, so Phases A-D run against a frozen baseline.

PeterLemon pixel-match, before -> after:
  hello-world                 <before> -> <after>
  cpu/add                     <before> -> <after>
  gpu/render-line             <before> -> <after>
  gpu/render-polygon          <before> -> <after>
  gpu/render-rectangle        <before> -> <after>
  gpu/render-texture-polygon  <before> -> <after>

Visual A/B on Croc, Spyro, Silent Hill and Crash Bandicoot at 900M
instructions in explore mode: <verdict per game>.

trace-golden recaptured for all workloads; JaCzekanski unchanged at 12/17.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

Fill in every `<before> -> <after>` and `<verdict>` with the real numbers from Steps 3-4. A recapture commit whose message does not explain the diff is exactly what the project's golden policy forbids.

- [ ] **Step 9: Clean up the reference worktree**

```bash
git worktree remove /tmp/ps1-phase0-base --force
rm -rf /tmp/ab
```

- [ ] **Step 10: Update `CLAUDE.md`'s GPU cheat-sheet**

The **GPU** entry in § Per-subsystem cheat-sheet says "software scanline rasterizer". Replace that phrase with a short note that the triangle path is an integer edge-function rasterizer with a top-left fill rule and exact integer attribute interpolation, and that the formulas are shared with the Phase B Metal backend by design — so nobody "optimises" them back into float or into incremental fixed point. Leave every other claim in that entry (oversized drop, mask bits, GPUSTAT bits, scanout) alone.

```bash
git add CLAUDE.md
git commit -m "docs: record the integer rasterizer in the GPU cheat-sheet

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review notes

**Spec coverage.** Phase 0's spec text names four things: edge functions with a top-left fill rule (Task 2), fixed-point replacing the `f32` barycentric interpolation (Task 3), the `f32` texcoord interpolation (Task 4), and `color.zig`'s modulate (Task 5). The gate — visual A/B on the four named games, a reasoned review of the PL deltas, then `trace-golden -- capture` and `PS1_UPDATE_GOLDENS=1` as their own commit — is Task 8. Task 6 and Task 7 go beyond the letter of the spec and say so in place; both are inside Phase 0's stated remit ("this is the only phase permitted to change output") and both are single revertible commits.

**Deviation from the spec's wording, deliberate.** The spec says "fixed-point interpolation". This plan uses **exact integer** interpolation — `floor(Σ w_i·a_i / area)` in `i64` — rather than a scaled fixed-point representation. It is strictly better for the stated purpose: it has no rounding error to reconcile between the two backends, it costs the same as the `f32` code it replaces, and it is position-evaluable, which a fragment shader requires and Avocado's own (disabled) fixed-point stepping is not. If a reviewer wants the spec updated to match, that is a one-line edit to § The 1× gate.

**Correction to the spec's premise, from simulation.** The spec's § The 1× gate leads with coverage — "the software rasterizer is neither an edge-function rasterizer nor an integer one, so no GPU triangle setup reproduces it" — and treats interpolation as the second problem. Both rules were simulated against the current implementation before this plan was written, and the weight is the other way round: today's fill-rule bias is algebraically equivalent to the top-left rule, and the span search's coverage set differs on about 5 triangles in 3,000 (0 in 3,000 over the full VRAM box), always by one extra pixel on a half-pixel sliver. The interpolation is where the output actually moves, and the texcoord path most of all. The conversion is still required exactly as specified — an `f32` algorithm is not reproducible in a shader whether or not it currently agrees — but nobody should go into Task 2 expecting to see a rendering change, and the § Reference table records the measured numbers so the Task 8 A/B can be read against them.

**Open risk carried into Phase B.** The `i64` numerator forces Metal Shading Language `long` in the Phase B fragment shader. That is available from MSL 2.2 (macOS 10.15), well below this project's floor, but 64-bit integer math is emulated on Apple GPUs. If it measures badly, the fix is to re-express the numerator relative to the triangle's bounding-box corner — every term then fits comfortably in 32 bits except the final sum — **not** to reintroduce floats on either side.
