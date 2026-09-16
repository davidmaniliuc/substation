# PGXP Phase 3 — Perspective-Correct Texturing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A textured triangle whose three vertices carry a depth term is sampled perspective-correctly in both the Zig software rasterizer and the Metal backend, bit-for-bit identically, with every existing gate unchanged and still strict.

**Architecture:** The depth the GTE already records (`pgxp.Value.z`) is carried to the GP0 vertex decode as `Primitive.Point.w`, reduced ONCE per triangle on the CPU to three quantised integer reciprocals `rw_i = round(2^16 * Wmin / W_i)`, and carried in the command record as `command.Vertex.rw`. Both rasterizers then evaluate one shared integer expression per fragment — `a = Σ(w_i·rw_i·a_i) / Σ(w_i·rw_i)` — over identical integer inputs, so they agree by construction rather than by a promise about two compilers' rounding. `rw_i == 0` on any vertex means the triangle takes today's affine `interp`, unchanged.

**Tech Stack:** Zig 0.16.0 (`ps1-core`, `ps1-golden`, `ps1-capi`), Metal Shading Language (`ps1-macos/Shaders`), Swift + swift-testing (`ps1-macos`), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-09-13-pgxp-phase-3-texture-correction-design.md`

---

## Review of the spec before planning

Four things were checked against the code. Three confirm the spec; two are gaps the plan closes.

**1. The spec's one explicit "verify, don't trust" item is SETTLED: `ps1_interp`'s comment is the stale one.** `ps1_triangle_coverage` (`Rasterizer.metal:135-138`) computes `qpx = (px * PS1_Q_UNIT) / s - ox * PS1_Q_UNIT` and reads `p.qx0..p.qy2` straight out of the record, which `PrimInstance.h` documents as native 1/16-px units. So the sample point is REDUCED to native units and **no weight and no area carries a factor of `s` at any internal resolution.** `ps1_interp`'s claim that "at internal resolution s BOTH the weights and the area scale by s^2" describes the pre-Phase-C arrangement and is wrong today; its numeric conclusion ("reaches about 2.13e9 at s = 4… passes it at s = 5") is wrong with it, although `long` is still required for the native case alone (2^29 · 255 ≈ 1.4e11). The spec's overflow bound therefore holds at every scale with ~2^8 of headroom, `2^16` is the right constant, and the fallback to `2^14` is not needed. Task 6 corrects the comment.

**2. `weldPoint` is a gap the spec does not cover, and it is load-bearing.** `gp0.zig:313-341` publishes and adopts `(px, py, resolved)` as an atomic triple, and nothing else. After this phase a welded vertex could be `resolved = true` with `w = 0` (an unresolved vertex adopting a neighbour's sub-pixel position), or `resolved = false` with `w != 0` (a resolved vertex giving its position up). Either way a vertex is drawn at one vertex's position with another's depth — which is the mixed-coordinate-space defect `unify` exists to prevent, one level down. **The plan makes the weld slot carry `w` and adopt it with the position**, so position and depth never come apart. This is Task 1.

**3. `rw` is computed in `gp0.zig`, not in `sink.zig`.** The spec's plumbing table says `gp0.zig` and that is right: `Sink` holds no PGXP state and cannot reach `Bus`, while `Gp0Engine` already carries the mirror pattern (`pgxp_enabled`, `pgxp_tolerance`, `vertex_cache`) that a new sub-setting needs. `Sink.drawTexturedTriangle` gains an `rw: [3]i32` parameter and writes it into the three vertices. A quad's two halves call it twice with independently computed triples, which is safe because the normalisation constant cancels.

**4. Two costs the spec does not state, neither a blocker.** `Command` grows 96 → 108 bytes, so `Recorder` inside `Bus` grows from ~7.08 MB to ~7.87 MB (65,536 records), and the Swift `StreamQueue`'s eight slots grow by ~6 MB in total. And `Ps1PrimInstance` grows 48 → 51 `int`s, which is a further 12 bytes per primitive in the encoder's instance buffer.

One correction to the spec's proposed scaled-path test. It asks for "a steeply-angled textured triangle at 8x must sample a monotonically varying texel sequence across a block, not the same texel repeated". That assertion cannot fail: `qpx = (px·16)/s` already varies by 2 q-units per subtexel at `s = 8`, so even the AFFINE path varies within a block. Task 6 substitutes the assertion that actually catches the blind spot — a perspective render must differ from the affine render at subtexels that are NOT on the native lattice, plus a perspective-signature check on one off-lattice row.

---

## Global Constraints

Exact values, copied from the spec and from `CLAUDE.md`. Every task's requirements implicitly include this section.

- **Zig 0.16.0.** `zig version` must print exactly that.
- **Run every command from the repo root.** The harnesses read the BIOS, `games/` and the test ROMs relative to the process CWD.
- **With PGXP off, every output byte in this phase is unchanged by construction.** No `rw` is ever non-zero, so the affine branch runs. `trace-golden -- verify`, `trace-golden -- stream-verify`, Gate 1 (fixture hashes at 1x) and Gate 2 (`readbackNative` at scale equals 1x) cannot move. **If one moves, it is a bug in the gating, never a behaviour change to recapture** — do NOT run `trace-golden -- capture`, and do NOT re-pin a PL floor, at any point in this plan.
- **No `f32` in the rasterizer inner loop, in either rasterizer.** `f32` appears only in `Primitive.Point.w` and in the once-per-triangle `reciprocalDepths` reduction, both of which run on the CPU before the sink.
- **A record carries every input its effect needs; nothing may be re-derived at replay time**, and records stay in native 1024×512 units at every scale. `rw` is carried; `a_i · rw_i` is an exact integer product of two carried fields and is computed where it is used.
- **The fill-rule bias stays at `-1`** in `renderer.zig` (as `-1`, scaled by nothing) and at `-1` in `Rasterizer.metal`. Nothing in this plan touches coverage.
- **Textured RECTANGLES stay affine, permanently.** A sprite has one position and a size, no per-vertex depth, and is 2D by construction.
- **`pgxp_texture_correction` defaults ON, and a default-ON flag on `Bus` must ALSO be assigned in `Bus.init`** — the `@memset` there does not respect field defaults. `pgxp_culling` and `pgxp_cpu` both shipped broken for a build over exactly this.
- **The sub-setting is ANDed with the master flag in ONE place.** For `Gp0Engine` that place is `Bus.pgxpTextureCorrection()`, mirrored at both setters, exactly as `Bus.pgxpVertexCache()` already is.
- **No file in `ps1-core/src` over ~600 lines.** `renderer.zig` is at 613 today; keep additions tight and do not let it grow past ~650 without splitting.
- **Run `zig fmt` before every commit.** Match the surrounding style: inline field defaults, doc comments that state the reasoning, no thinking-out-loud comments.
- **Casts: Tier A over Tier B.** Let Zig infer the cast target from the result location. Do not extract a helper into `bits.zig` unless an idiom is 3+ operations at 4+ sites.
- **`zig build trace-golden` and `zig build fixtures` must be run `-Doptimize=ReleaseFast`.** A Debug core runs at ~0.45× real time and reads as a hang.
- **`pkill -x Substation` before running `ps1-macos/test.sh`.** A running app shares the bundle id and fails the run in a way that looks like a real failure.
- **The Swift suite intermittently crashes the test process under sustained scale-8 load.** The tell is `Failing tests:` with zero `✘` lines. Re-run before believing it.
- **Never `git push`.** Commit to `master` locally, one commit per task.

---

## File Structure

| File | Responsibility after this phase |
|---|---|
| `ps1-core/src/gpu/primitive.zig` | `Point.w`; `getPointPrecise` accepts a depth; `reciprocalDepths` + `rw_one` — the one place the quantisation is decided |
| `ps1-core/src/gpu/gp0.zig` | `WeldSlot.w`; `unify*` clears `w`; the `pgxp_texture_correction` mirror; the per-triangle `rw` computation at the four textured call sites; `perspective_primitives` |
| `ps1-core/src/gpu/sink.zig` | `drawTexturedTriangle` gains `rw: [3]i32` and writes it into the record |
| `ps1-core/src/gpu/command.zig` | `Vertex.rw`; stride tripwires 20→24 and 96→108 |
| `ps1-core/src/gpu/renderer.zig` | `interpW`; the perspective branch in `drawTexturedTriangle`'s shader |
| `ps1-core/src/memory.zig` | `Bus.pgxp_texture_correction`, `Bus.pgxpTextureCorrection()`, `setPgxpTextureCorrection`, the `Bus.init` assignment |
| `ps1-golden/src/fixture.zig` | `.p1fx` version 2 → 3, stride assertion 96 → 108 |
| `ps1-golden/src/main.zig` | `--pgxp-on` writes `<key>-pgxp.p1fx` |
| `ps1-golden/src/pgxp_sweep.zig` | `perspective_primitives` in the report and its ratchet line |
| `ps1-capi/include/ps1.h` | `Ps1GpuVertex.rw`, `PS1_GPU_COMMAND_STRIDE` 108, `ps1_set_pgxp_texture_correction` |
| `ps1-capi/src/root.zig` | the setter's implementation |
| `ps1-macos/Shaders/PrimInstance.h` | `Ps1PrimInstance.rw0/rw1/rw2` |
| `ps1-macos/Shaders/Ps1Color.h` | `ps1_interp_w`; the corrected `ps1_interp` comment |
| `ps1-macos/Shaders/Rasterizer.metal` | the perspective branch in `PS1_PRIM_TEXTURED_TRI`; the `4 * 51` static assert |
| `ps1-macos/Sources/PS1/PrimBuilder.swift` | copies `rw` from the record into the instance |
| `ps1-macos/Sources/PS1/FixtureFile.swift` | accepts `.p1fx` version 3 only |
| `ps1-macos/Sources/PS1/PgxpSetting.swift` | `textureCorrection`, default TRUE, read with `object(forKey:)` |
| `ps1-macos/Sources/PS1/{Ps1Core,EmulatorRunner,EmulatorViewModel}.swift` | the setting's path to the core |
| `ps1-macos/Sources/PS1App/VideoCommands.swift` | the menu toggle, inside the greyed sub-setting `Group` |
| `ps1-core/tests/{gpu_test,pgxp_test}.zig` | the Zig unit gates |
| `ps1-macos/Tests/PS1Tests/{FixtureBridgeTests,MetalScaleTests,PgxpSettingTests,Ps1GpuVertexTestSupport}.swift` | the Swift gates |
| `ps1-macos/Tests/PS1Tests/PgxpParityTests.swift` | **new** — the PGXP-on parity fixture at strict equality |

---

### Task 1: The depth term reaches the GP0 vertex decode

`Primitive.Point` learns a depth, `getPointPrecise` fills it, and the two rules that de-resolve a vertex (`unify`, `weldPoint`) keep it in lockstep with the position. Nothing downstream reads it yet, so no output byte can move.

**Files:**
- Modify: `ps1-core/src/gpu/primitive.zig` (`Point`, `getPointPrecise`)
- Modify: `ps1-core/src/gpu/gp0.zig` (`WeldSlot`, `weldPoint`, `unifySpace`, `unifyTexturedSpace`)
- Test: `ps1-core/tests/pgxp_test.zig`, `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `pgxp.Value.z`, `pgxp.Value.valid_xyz` (both already exist, `ps1-core/src/pgxp/pgxp.zig:66-77`).
- Produces: `Primitive.Point.w: f32` — the depth term the GTE's float projection computed for this vertex, `0` when the vertex carries none. Task 2 reduces it; nothing else reads it.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/pgxp_test.zig`:

```zig
test "an accepted vertex carries the projection's depth term" {
    const word = packXY(100, 50);
    const v: Value = .{
        .x = 100.25, .y = 50.5, .z = 12.0,
        .word = word, .flags = Value.valid_xyz,
    };
    const pt = Primitive.getPointPrecise(word, v, pgxp.tolerance_disabled);
    try std.testing.expect(pt.resolved);
    try expectEqual(@as(f32, 12.0), pt.w);
}

test "a vertex whose value has no depth resolves with no depth term" {
    const word = packXY(100, 50);
    const v: Value = .{
        .x = 100.25, .y = 50.5, .z = 12.0,
        .word = word, .flags = Value.valid_xy, // no valid_z
    };
    const pt = Primitive.getPointPrecise(word, v, pgxp.tolerance_disabled);
    try std.testing.expect(pt.resolved);
    try expectEqual(@as(f32, 0), pt.w);
}

test "an unresolved vertex carries no depth term" {
    const word = packXY(100, 50);
    const stale: Value = .{
        .x = 100.25, .y = 50.5, .z = 12.0,
        .word = word +% 1, .flags = Value.valid_xyz,
    };
    const pt = Primitive.getPointPrecise(word, stale, pgxp.tolerance_disabled);
    try std.testing.expect(!pt.resolved);
    try expectEqual(@as(f32, 0), pt.w);
}
```

`packXY` already exists in both `pgxp_test.zig:1258` and `gpu_test.zig:1206`; reuse it, do not re-declare.

**`subPixel` takes fractional DISPLACEMENTS, not absolute coordinates** (`ps1-core/tests/pgxp_value.zig`): `subPixel(word, fx, fy)` reads the word's own signed halves and adds `fx`/`fy` to them. It has **29 call sites** across `cpu_test.zig` and `gpu_test.zig`, so do NOT change its arity. Add a sibling beside it in `ps1-core/tests/pgxp_value.zig`:

```zig
/// `subPixel` plus a depth term, for the tests that are about what the depth
/// does. Separate rather than a fourth parameter on `subPixel`: that one has
/// 29 call sites and none of them has anything to say about a depth.
pub fn subPixelDepth(word: u32, fx: f32, fy: f32, z: f32) Value {
    var v = subPixel(word, fx, fy);
    v.z = z;
    v.flags = Value.valid_xyz;
    return v;
}
```

and import it in `gpu_test.zig` beside the existing `subPixel` import:

```zig
const subPixelDepth = @import("pgxp_value.zig").subPixelDepth;
```

Append to `ps1-core/tests/gpu_test.zig`, after the existing `PGXP:` tests:

```zig
/// `unify` snaps a mixed primitive back onto the integer grid. A vertex that
/// loses its sub-pixel must lose its depth with it: a position from the wire
/// paired with a depth from the float projection is a third geometry, exactly
/// as a mixed primitive is.
test "PGXP: unify clears the depth term on a mixed primitive" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    gpu.gp0.pgxp_enabled = true;

    const w0 = packXY(10, 10);
    const w1 = packXY(60, 12);
    const w2 = packXY(14, 58);
    // Two resolved, one not: the mixed rule fires and all three snap back.
    // GP0 0x25 is a raw textured triangle: cmd, v0, t0, v1, t1, v2, t2.
    _ = gpu.writeGp0(0x25000000, Value.none);
    _ = gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 8.0));
    _ = gpu.writeGp0(0x00000000, Value.none);
    _ = gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 16.0));
    _ = gpu.writeGp0(0x00000000, Value.none);
    _ = gpu.writeGp0(w2, Value.none);
    _ = gpu.writeGp0(0x00000000, Value.none);

    try expectEqual(@as(u64, 1), gpu.gp0.pgxp.mixed_primitives);
}

/// The weld publishes a position and adopts one; the depth must travel with
/// it. Otherwise an unresolved vertex adopting a neighbour's sub-pixel is
/// drawn at that position with no depth, and a resolved vertex giving its
/// position up keeps a depth that no longer describes where it is.
test "PGXP: a welded vertex adopts the published depth with the position" {
    var gpu = Gpu.init();
    gpu.gp0.pgxp_enabled = true;

    var resolved = pt(40, 40);
    resolved.px = (40 << 16) | 0x8000;
    resolved.py = (40 << 16) | 0x4000;
    resolved.resolved = true;
    resolved.w = 9.0;

    var bare = pt(40, 40); // same integer position, nothing resolved
    var pts = [_]Primitive.Point{ resolved, bare };
    gpu.gp0.weldForTest(&pts);

    try expectEqual(pts[0].px, pts[1].px);
    try expectEqual(pts[0].py, pts[1].py);
    try std.testing.expect(pts[1].resolved);
    try expectEqual(@as(f32, 9.0), pts[1].w);
    _ = &bare;
}
```

`subPixel` is already imported from `pgxp_value.zig` at the top of `gpu_test.zig`. It currently takes `(word, x, y)`; extend it to `(word, x, y, z)` in `ps1-core/tests/pgxp_value.zig` and update its existing call sites (there are a handful in `gpu_test.zig`; find them with `grep -n subPixel ps1-core/tests/*.zig`). The new body:

```zig
/// A `Value` recorded against `word` at a sub-pixel position and a depth.
pub fn subPixel(word: u32, x: f32, y: f32, z: f32) Value {
    return .{ .x = x, .y = y, .z = z, .word = word, .flags = Value.valid_xyz };
}
```

`weldForTest` does not exist yet; add it to `Gp0Engine` beside `weldPrimitive`:

```zig
/// `weldPrimitive` reachable from a test. The weld is the one PGXP rule with
/// no GP0-level entry point of its own — it runs inside `unify`, which a test
/// can only reach by driving a whole primitive through the FIFO, and that
/// cannot express "two primitives sharing one integer position" in isolation.
pub fn weldForTest(self: *Gp0Engine, pts: []Primitive.Point) void {
    self.weldPrimitive(pts);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -40`
Expected: compile errors — `no field named 'w' in struct 'Point'`, `no member named 'weldForTest'`, and `expected 3 arguments, found 4` at `subPixel`.

- [ ] **Step 3: Add `Point.w` and fill it in `getPointPrecise`**

In `ps1-core/src/gpu/primitive.zig`, add to `Point` after `drift`:

```zig
    /// The depth term the GTE's float projection computed for this vertex —
    /// `pgxp.Value.z`, which is `max(H/2, SZ3)` and so is strictly positive
    /// wherever it is set. Zero means this vertex carries no depth.
    ///
    /// Perspective-correct texturing is its only consumer, and it consumes a
    /// quantised RECIPROCAL of it (`reciprocalDepths`) rather than this value.
    /// The `f32` stops at the sink: the record carries the integer, because a
    /// derived value transcribed twice is exactly the kind of thing that
    /// drifts between two rasterizers.
    ///
    /// Kept in lockstep with `resolved` everywhere it changes — `unify` clears
    /// both, `weldPoint` publishes and adopts both. A position from one source
    /// paired with a depth from another is a third geometry, which is the
    /// defect `unify` exists to prevent, one level down.
    w: f32 = 0,
```

In `getPointPrecise`, inside the accepting branch, after `pt.drift = ...`:

```zig
        if (p.flags & Value.valid_z != 0) pt.w = p.z;
```

- [ ] **Step 4: Clear `w` in both `unify` paths**

In `ps1-core/src/gpu/gp0.zig`, in `unifySpace`, both de-resolving loops become:

```zig
            for (pts) |*pt| {
                pt.px = @as(i32, pt.x) << 16;
                pt.py = @as(i32, pt.y) << 16;
                pt.resolved = false;
                pt.w = 0;
            }
```

and in `unifyTexturedSpace`, both loops become:

```zig
            for (vs) |*v| {
                v.point.px = @as(i32, v.point.x) << 16;
                v.point.py = @as(i32, v.point.y) << 16;
                v.point.resolved = false;
                v.point.w = 0;
            }
```

- [ ] **Step 5: Carry `w` through the weld**

In `ps1-core/src/gpu/gp0.zig`, add `w: f32 = 0` to `WeldSlot` (find it with `grep -n "WeldSlot" ps1-core/src/gpu/gp0.zig`), and in `weldPoint` change the adopt and the publish:

```zig
        if (slot.key == key) {
            if (slot.px != pt.px or slot.py != pt.py) {
                pt.px = slot.px;
                pt.py = slot.py;
                pt.resolved = slot.resolved;
                // The depth travels with the position. A welded vertex is
                // drawn where the slot says, so it must be drawn at the depth
                // the slot was published with — pairing one vertex's position
                // with another's depth is the mixed-space defect `unify`
                // exists to prevent, one level down.
                pt.w = slot.w;
                self.pgxp.welded += 1;
            }
            return;
        }
```

and

```zig
        slot.* = .{ .key = key, .px = pt.px, .py = pt.py, .resolved = pt.resolved, .w = pt.w };
```

Add `weldForTest` from Step 1 beside `weldPrimitive`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig fmt ps1-core && zig build test 2>&1 | tail -20`
Expected: all 16 test binaries pass.

- [ ] **Step 7: Confirm no output byte moved**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify 2>&1 | tail -20`
Expected: no new failures. Note the pre-existing `mgs` orphaned-golden failure is EXPECTED and is not this plan's to fix (see `project-mgs-orphaned-trace-golden`); record the failure count before and after and require them equal.

- [ ] **Step 8: Commit**

```bash
git add ps1-core/src/gpu/primitive.zig ps1-core/src/gpu/gp0.zig ps1-core/tests/pgxp_test.zig ps1-core/tests/gpu_test.zig ps1-core/tests/pgxp_value.zig
git commit -m "$(cat <<'EOF'
feat(pgxp): the projection's depth term reaches the vertex decode

`Point.w` carries `Value.z` from the GTE's float projection to GP0. It is
kept in lockstep with `resolved` at both places that change one: `unify`
clears it when it snaps a mixed or thin primitive back, and `weldPoint`
publishes and adopts it with the position. Pairing one vertex's position with
another's depth is the mixed-coordinate-space defect `unify` exists to
prevent, one level down.

Nothing reads it yet, so no output byte moves.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 2: `reciprocalDepths` — the quantisation, decided in one place

The whole of the `f32` → integer reduction, with the overflow derivation written beside the constant.

**Files:**
- Modify: `ps1-core/src/gpu/primitive.zig`
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Primitive.Point.w` (Task 1).
- Produces:
  - `Primitive.rw_one: i32` = `1 << 16` — the value the nearest vertex gets.
  - `Primitive.reciprocalDepths(w: [3]f32) [3]i32` — all zeros unless all three `w` are strictly positive; otherwise each entry is `clamp(round(rw_one * min(w) / w[i]), 1, rw_one)`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 3 Task 2: the quantised reciprocal depth.

test "Phase3: the nearest vertex normalises to exactly rw_one" {
    const rw = Primitive.reciprocalDepths(.{ 4.0, 1.0, 16.0 });
    try expectEqual(Primitive.rw_one, rw[1]);
    try expectEqual(Primitive.rw_one >> 2, rw[0]);
    try expectEqual(Primitive.rw_one >> 4, rw[2]);
}

/// The cancellation property, asserted rather than assumed: scaling all three
/// depths by a common factor is a no-op, which is what makes per-primitive
/// normalisation safe and lets a quad's two halves normalise independently.
test "Phase3: a common scaling of all three depths leaves rw unchanged" {
    const base = Primitive.reciprocalDepths(.{ 3.0, 7.0, 11.0 });
    for ([_]f32{ 0.125, 2.0, 1000.0 }) |k| {
        const scaled = Primitive.reciprocalDepths(.{ 3.0 * k, 7.0 * k, 11.0 * k });
        try expectEqual(base[0], scaled[0]);
        try expectEqual(base[1], scaled[1]);
        try expectEqual(base[2], scaled[2]);
    }
}

test "Phase3: a vertex with no depth gives the whole triangle no rw" {
    try expectEqual([3]i32{ 0, 0, 0 }, Primitive.reciprocalDepths(.{ 1.0, 0, 4.0 }));
    try expectEqual([3]i32{ 0, 0, 0 }, Primitive.reciprocalDepths(.{ 0, 0, 0 }));
    try expectEqual([3]i32{ 0, 0, 0 }, Primitive.reciprocalDepths(.{ 1.0, -2.0, 4.0 }));
}

/// The clamp is what makes the interpolant's denominator provably positive:
/// coverage guarantees every w_i >= 0 with w0+w1+w2 == area > 0, so the
/// denominator is at least 1 once no rw_i can be zero.
test "Phase3: an extreme depth ratio clamps to one rather than to zero" {
    const rw = Primitive.reciprocalDepths(.{ 1.0, 1.0e12, 1.0 });
    try expectEqual(Primitive.rw_one, rw[0]);
    try expectEqual(@as(i32, 1), rw[1]);
    try expectEqual(Primitive.rw_one, rw[2]);
}

test "Phase3: three equal depths give three equal rw" {
    const rw = Primitive.reciprocalDepths(.{ 7.5, 7.5, 7.5 });
    try expectEqual(Primitive.rw_one, rw[0]);
    try expectEqual(Primitive.rw_one, rw[1]);
    try expectEqual(Primitive.rw_one, rw[2]);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: `root source file struct 'primitive' has no member named 'reciprocalDepths'`.

- [ ] **Step 3: Implement it**

Append to `ps1-core/src/gpu/primitive.zig`, after `toFixed`:

```zig
/// The value the NEAREST of a triangle's three vertices normalises to, and so
/// the ceiling on every `rw`. 16 bits of RELATIVE reciprocal precision: a
/// 100:1 depth ratio resolves its far vertex's 1/W to about 0.15% and a 1000:1
/// ratio to about 1.5%, both far below the whole-texel swim the feature exists
/// to remove.
///
/// The bound that fixes the constant. A primitive spanning >=1024 horizontally
/// or >=512 vertically is DROPPED, so in the box-relative 1/16-px space both
/// rasterizers work in every barycentric weight is under 2^29 (see
/// `renderer.zig`'s `toQ`), and a texcoord is an 8-bit wire field:
///
///     a_i * rw_i          <= 255 * 2^16        < 2^24
///     sum(w_i*rw_i*a_i)   <= 3 * 2^29 * 2^24   < 2^55
///     sum(w_i*rw_i)       <= 3 * 2^29 * 2^16   < 2^47
///
/// Both inside `i64`, with about 2^8 of headroom on the numerator, AT EVERY
/// INTERNAL RESOLUTION: `ps1_triangle_coverage` reduces its sample point to
/// native 1/16-px units rather than scaling the vertices, so no weight carries
/// a factor of the scale. Dropping to 2^14 is a one-line change here if that
/// ever stops being true.
pub const rw_one: i32 = 1 << 16;

/// One triangle's three quantised reciprocal depths — the integers
/// perspective-correct texturing interpolates `u/W` and `1/W` with.
///
/// `rw_i = round(rw_one * Wmin / W_i)`, normalised on the nearest vertex.
/// **The normalisation constant cancels out of the interpolant** — numerator
/// and denominator are both first-order in `rw`, so scaling all three by a
/// common factor leaves the quotient untouched. That is what makes
/// per-primitive normalisation safe, and it is why a quad's two halves may be
/// normalised independently after `unify` has judged all four vertices.
///
/// Returns zeros unless ALL THREE vertices carry a depth. `rw_i == 0` is the
/// signal both rasterizers read to take today's affine `interp` instead, and
/// it is cheap to rely on because `unify` already forces a primitive to be
/// all-resolved or none-resolved before the sink ever sees it.
///
/// The clamp to 1 is not a rounding nicety: it is what makes the interpolant's
/// denominator provably positive. Coverage guarantees every `w_i >= 0` with
/// `w0 + w1 + w2 == area > 0`, so `sum(w_i * rw_i) >= 1` once no `rw_i` can be
/// zero. Without it a pixel sitting exactly on the one vertex whose `rw`
/// rounded to zero would divide by zero. What it gives up is a vertex more
/// than 65536x further away than its nearest neighbour.
///
/// Computed ONCE per triangle, on the CPU, here — never in a shader and never
/// twice. `f64` because the ratio of two `f32` depths is the one place in this
/// reduction where single precision would cost a quantisation step for nothing.
pub fn reciprocalDepths(w: [3]f32) [3]i32 {
    if (!(w[0] > 0) or !(w[1] > 0) or !(w[2] > 0)) return .{ 0, 0, 0 };
    const near: f64 = @min(w[0], @min(w[1], w[2]));
    var out: [3]i32 = undefined;
    for (w, 0..) |wi, i| {
        const q = @round(@as(f64, rw_one) * near / @as(f64, wi));
        out[i] = std.math.clamp(std.math.lossyCast(i32, q), 1, rw_one);
    }
    return out;
}
```

Note the `!(w > 0)` spelling rather than `w <= 0`: it rejects a NaN as well, which `<=` does not.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig fmt ps1-core && zig build test 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src/gpu/primitive.zig ps1-core/tests/gpu_test.zig
git commit -m "$(cat <<'EOF'
feat(pgxp): reciprocalDepths, the quantisation decided in one place

rw_i = round(2^16 * Wmin / W_i), normalised on the nearest vertex and clamped
to at least 1. The normalisation constant CANCELS out of the interpolant, so
this choice decides quantisation only and can never change a sampled texel —
which is what makes per-primitive normalisation safe and lets a quad's two
halves normalise independently. The clamp is what makes the denominator
provably positive.

The overflow derivation is written beside the constant, and it holds at every
internal resolution: ps1_triangle_coverage reduces its SAMPLE POINT to native
units rather than scaling the vertices, so no weight carries a factor of s.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 3: `Vertex.rw` — the record grows, and every stride check with it

`command.Vertex` gains the field and every pin along the chain moves together: the Zig tripwires, the `.p1fx` version, the C header, the Swift bridge. Nothing writes a non-zero `rw` yet, so every gate must stay green — which is exactly what makes this a safe checkpoint.

**Files:**
- Modify: `ps1-core/src/gpu/command.zig`
- Modify: `ps1-golden/src/fixture.zig:41,48`
- Modify: `ps1-capi/include/ps1.h` (`Ps1GpuVertex`, `PS1_GPU_COMMAND_STRIDE`, both `_Static_assert`s)
- Modify: `ps1-macos/Sources/PS1/FixtureFile.swift:63`
- Modify: `ps1-macos/Tests/PS1Tests/Ps1GpuVertexTestSupport.swift`
- Modify: `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift:273`
- Test: `ps1-core/tests/gpu_stream_test.zig`, `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `command.Vertex.rw: i32 = 0` — the quantised reciprocal depth from `Primitive.reciprocalDepths`, `0` when the vertex has none. `@sizeOf(Vertex) == 24`, `@sizeOf(Command) == 108`, `.p1fx` version `3`, `PS1_GPU_COMMAND_STRIDE == 108`, C field `int32_t rw`.

- [ ] **Step 1: Write the failing tests**

In `ps1-macos/Tests/PS1Tests/FixtureBridgeTests.swift`, rename and retarget the stride test:

```swift
@Test func gpuCommandStrideIs108() {
    #expect(MemoryLayout<Ps1GpuCommand>.stride == 108)
    #expect(MemoryLayout<Ps1GpuCommand>.size == 108)
    #expect(MemoryLayout<Ps1GpuVertex>.stride == 24)
}
```

and change the `strideMismatch(64)` expectation at line ~211 only if it hard-codes 96 anywhere; read it first with `sed -n '195,220p'` and keep its shape.

Add to the same file:

Add it beside `rejectsARecordStrideMismatch`, in the same MARK section and in exactly its shape — patch the committed fixture's header bytes in memory rather than constructing a file, since `init(_:)` is the entry point under test either way. The version field is at byte offset 8:

```swift
/// A version-2 file is a DIFFERENT record layout wearing the same extension.
/// It must be refused loudly, not read with a 108-byte stride over 96-byte
/// records — which shears every field of every record after the first.
@Test func rejectsAVersionTwoFixture() throws {
    var bytes = try Data(contentsOf: FixtureFile.url(named: "synthetic-movers"))
    for (i, b) in [UInt8(2), 0, 0, 0].enumerated() { bytes[8 + i] = b }

    #expect(throws: FixtureFile.Error.badVersion(2)) {
        _ = try FixtureFile(bytes)
    }
}
```

In `ps1-core/tests/gpu_stream_test.zig`, add:

```zig
test "a textured triangle's rw survives the record round trip" {
    var cmd: ps1_core.gpu.command.Command = .{ .kind = .draw_textured_triangle };
    cmd.v[0].rw = 65536;
    cmd.v[1].rw = 16384;
    cmd.v[2].rw = 1;
    const bytes = std.mem.asBytes(&cmd);
    var back: ps1_core.gpu.command.Command = undefined;
    @memcpy(std.mem.asBytes(&back), bytes);
    try std.testing.expectEqual(@as(i32, 65536), back.v[0].rw);
    try std.testing.expectEqual(@as(i32, 16384), back.v[1].rw);
    try std.testing.expectEqual(@as(i32, 1), back.v[2].rw);
    try std.testing.expectEqual(@as(usize, 108), @sizeOf(ps1_core.gpu.command.Command));
}
```

Check the existing imports at the top of `gpu_stream_test.zig` and match how it reaches `command` — it may already alias it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: `no field named 'rw'` / the size assertion fails at 96.

- [ ] **Step 3: Add the field and move every Zig pin**

In `ps1-core/src/gpu/command.zig`, add to `Vertex` after `py`:

```zig
    /// Quantised reciprocal depth — `round(2^16 * Wmin / W)` for this
    /// triangle, from `Primitive.reciprocalDepths`. Zero means this vertex
    /// carries no depth, and a triangle takes the perspective path if and only
    /// if all three of its vertices have a non-zero one. Textured triangles
    /// only; every other kind leaves it zero.
    ///
    /// The derived INTEGER rather than the `f32` W it came from, for two
    /// reasons. A record carries every input its effect needs and nothing may
    /// be re-derived at replay time — deriving `rw` on each side is exactly
    /// the second transcription that drifts. And `rw` is what the effect
    /// consumes; the W is an intermediate. A depth buffer would want absolute
    /// W, which per-primitive normalisation discards; it can add that field
    /// when something reads it.
    rw: i32 = 0,
```

Update the comptime block in the same file:

```zig
    if (@sizeOf(Vertex) != 24) @compileError("Vertex layout changed");
    if (@sizeOf(Command) != 108) @compileError("Command layout changed");
```

In `ps1-golden/src/fixture.zig`:

```zig
pub const version: u32 = 3;
```

and

```zig
    if (record_stride != 108) @compileError("Command stride changed; bump .p1fx version");
```

- [ ] **Step 4: Move the C header and the Swift bridge**

In `ps1-capi/include/ps1.h`:

```c
#define PS1_GPU_COMMAND_STRIDE  108
```

add to `Ps1GpuVertex` after `px, py`:

```c
    /* Quantised reciprocal depth, round(2^16 * Wmin / W) for this triangle —
       see command.zig. Zero means no depth; a triangle is sampled
       perspective-correctly if and only if all three are non-zero. Textured
       triangles only. */
    int32_t  rw;
```

and

```c
_Static_assert(sizeof(Ps1GpuVertex) == 24, "Ps1GpuVertex layout changed");
```

In `ps1-macos/Sources/PS1/FixtureFile.swift:63`:

```swift
        guard version == 3 else { throw Error.badVersion(version) }
```

In `ps1-macos/Tests/PS1Tests/Ps1GpuVertexTestSupport.swift`, the convenience init gains `rw: 0`:

```swift
        self.init(x: x, y: y, u: u, v: v, _pad: _pad, color: color,
                  px: Int32(x) << 16, py: Int32(y) << 16, rw: 0)
```

and the one other full memberwise call, `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift:273`, gains `rw: 0` the same way.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig fmt ps1-core ps1-golden && zig build test 2>&1 | tail -20`
Expected: all 16 binaries pass.

- [ ] **Step 6: Regenerate the fixtures and confirm every existing gate is still green**

Run, in order:

```bash
zig build -Doptimize=ReleaseFast
zig build fixtures -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build capi-lib && zig build metallib
pkill -x Substation; ps1-macos/test.sh
```

**The committed `ps1-core/tests/goldens/fixtures/synthetic-movers.p1fx` and `synthetic-primitives.p1fx` are version-2 files and will now be REFUSED** — by `fixture_test` on the Zig side, which `@embedFile`s both (`build.zig:258-262`), and by `FixtureFile` on the Swift side. So `zig build test` goes red BEFORE the Swift suite does; regenerate first:

```bash
zig build fixtures -Doptimize=ReleaseFast
cp zig-out/fixtures/synthetic-movers.p1fx zig-out/fixtures/synthetic-primitives.p1fx \
   ps1-core/tests/goldens/fixtures/
```

Then run the sequence above. **Their per-frame VRAM hashes must be unchanged.** Two independent checks already assert exactly that and neither needs a script: `fixture_test` verifies the committed synthetic-mover hashes against a Zig-side `ShadowVram` replay, and `MetalMoverTests`/`MetalRasterizerTests` verify them against the Metal backend. If either goes red on a HASH (as opposed to on the version), a record field is being written that was not before — that is a bug to find, not a golden to recapture, because nothing in this task writes a non-zero `rw`.

Expected after regeneration: `verify` at the same failure count recorded in Task 1 Step 7; `stream-verify` clean; `zig build test` green; the Swift suite green.

- [ ] **Step 7: Commit**

```bash
git add ps1-core/src/gpu/command.zig ps1-golden/src/fixture.zig ps1-capi/include/ps1.h \
        ps1-macos/Sources/PS1/FixtureFile.swift ps1-macos/Tests/PS1Tests \
        ps1-core/tests/gpu_stream_test.zig ps1-core/tests/goldens/fixtures
git commit -m "$(cat <<'EOF'
feat(gpu): the record carries a per-vertex reciprocal depth

command.Vertex gains `rw`, so the stride goes 20 -> 24 and Command 96 -> 108,
and every pin along the chain moves with it: the two comptime tripwires, the
.p1fx version (2 -> 3), PS1_GPU_COMMAND_STRIDE, the two C static asserts and
the Swift stride test. The committed synthetic fixtures are regenerated at
version 3 with byte-identical per-frame VRAM hashes.

Nothing writes a non-zero rw yet, so every gate is still green — which is the
point of landing the layout change on its own.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 4: The setting, and `gp0` filling `rw`

`Bus.pgxp_texture_correction` (default ON), its mirror on `Gp0Engine`, and the four textured call sites computing the triple. The renderers still ignore `rw`, so output still cannot move.

**Files:**
- Modify: `ps1-core/src/memory.zig` (`Bus` field, `Bus.init`, `setPgxp`, `pgxpTextureCorrection`, `setPgxpTextureCorrection`)
- Modify: `ps1-core/src/gpu/gp0.zig` (mirror, `reciprocalDepths` helper, `perspective_primitives`, four call sites)
- Modify: `ps1-core/src/gpu/sink.zig` (`drawTexturedTriangle` signature)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Primitive.reciprocalDepths` (Task 2), `command.Vertex.rw` (Task 3).
- Produces:
  - `Bus.pgxp_texture_correction: bool = true`; `Bus.pgxpTextureCorrection() bool`; `Bus.setPgxpTextureCorrection(bool) void`.
  - `Gp0Engine.pgxp_texture_correction: bool = false` (the mirror; `Bus` keeps it in step, and the mirror's own default is OFF because `Bus` has not spoken yet).
  - `Gp0Engine.PgxpStats.perspective_primitives: u64`.
  - `Sink.drawTexturedTriangle(..., opcode: u8, rw: [3]i32)` — `rw` appended last.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
test "Phase3: texture correction is on by default and survives Bus.init" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    // The @memset in Bus.init does not respect field defaults; both
    // pgxp_culling and pgxp_cpu shipped broken for a build over exactly this.
    try std.testing.expect(bus.pgxp_texture_correction);
}

test "Phase3: texture correction is ANDed with the master flag" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    try std.testing.expect(!bus.pgxpTextureCorrection());
    bus.setPgxp(true);
    try std.testing.expect(bus.pgxpTextureCorrection());
    try std.testing.expect(bus.gpu.gp0.pgxp_texture_correction);
    bus.setPgxpTextureCorrection(false);
    try std.testing.expect(!bus.pgxpTextureCorrection());
    try std.testing.expect(!bus.gpu.gp0.pgxp_texture_correction);
    bus.setPgxpTextureCorrection(true);
    bus.setPgxp(false);
    try std.testing.expect(!bus.gpu.gp0.pgxp_texture_correction);
}

/// The record is what a Metal replay consumes, so the normalisation has to be
/// visible IN it rather than recomputed on either side.
test "Phase3: a fully resolved textured triangle records three reciprocal depths" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    gpu.gp0.pgxp_enabled = true;
    gpu.gp0.pgxp_texture_correction = true;

    const w0 = packXY(10, 10);
    const w1 = packXY(70, 12);
    const w2 = packXY(14, 68);
    _ = gpu.writeGp0(0x25000000, Value.none);
    _ = gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = gpu.writeGp0(0x00000000, Value.none);
    _ = gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = gpu.writeGp0(0x00000000, Value.none);
    _ = gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = gpu.writeGp0(0x00000000, Value.none);

    try expectEqual(@as(u64, 1), gpu.gp0.pgxp.perspective_primitives);
    try expectEqual(@as(u64, 0), gpu.gp0.pgxp.mixed_primitives);
}

test "Phase3: the setting off means no primitive takes the perspective path" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    gpu.gp0.pgxp_enabled = true;
    gpu.gp0.pgxp_texture_correction = false;

    const w0 = packXY(10, 10);
    const w1 = packXY(70, 12);
    const w2 = packXY(14, 68);
    _ = gpu.writeGp0(0x25000000, Value.none);
    _ = gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = gpu.writeGp0(0x00000000, Value.none);
    _ = gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = gpu.writeGp0(0x00000000, Value.none);
    _ = gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = gpu.writeGp0(0x00000000, Value.none);

    try expectEqual(@as(u64, 0), gpu.gp0.pgxp.perspective_primitives);
}
```

The `0x25000000` command is a raw-textured triangle (GP0 0x24-0x27, bit 0 = raw). Its word layout is `cmd, v0, t0, v1, t1, v2, t2` — seven words; the CLUT rides the high half of `t0` and the tpage the high half of `t1`. The writes above pass `0x00000000` for both texcoord words, which puts the texture page at (0, 0) and is fine for a test that reads only the counter.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: `no field named 'pgxp_texture_correction'` / `no member named 'perspective_primitives'`.

- [ ] **Step 3: Add the setting to `Bus`**

In `ps1-core/src/memory.zig`, add beside `pgxp_culling`:

```zig
    /// Perspective-correct texturing, gated by `pgxp_enabled` above. ON by
    /// default: texture correction and culling correction are the picture,
    /// while the vertex cache and CPU mode are the workarounds — which is also
    /// the reference's own default and its own reading of the four. PGXP
    /// itself still ships off, so this default only reaches a player who
    /// opted in.
    ///
    /// A default-ON flag here must ALSO be assigned in `init`: the `@memset`
    /// there does not respect field defaults, and `pgxp_culling` and
    /// `pgxp_cpu` both shipped broken for one build over exactly this.
    pgxp_texture_correction: bool = true,
```

In `Bus.init`, beside `bus.pgxp_culling = true;`:

```zig
        bus.pgxp_texture_correction = true;
```

Add beside `pgxpVertexCache`:

```zig
    /// Perspective-correct texturing, with the master flag already folded in —
    /// the same shape as `pgxpVertexCache` and for the same reason.
    /// `Gp0Engine` decodes the vertex and cannot reach `Bus`, so this value is
    /// MIRRORED onto it at both setters; the AND lives here and nowhere else.
    pub inline fn pgxpTextureCorrection(self: *const Self) bool {
        return self.pgxp_enabled and self.pgxp_texture_correction;
    }

    /// Set it and mirror it, for the same reason `setPgxpTolerance` mirrors.
    pub fn setPgxpTextureCorrection(self: *Self, enabled: bool) void {
        self.pgxp_texture_correction = enabled;
        self.gpu.gp0.pgxp_texture_correction = self.pgxpTextureCorrection();
    }
```

and inside `setPgxp`, beside the other mirrors:

```zig
        self.gpu.gp0.pgxp_texture_correction = self.pgxpTextureCorrection();
```

- [ ] **Step 4: Add the mirror, the counter and the helper to `Gp0Engine`**

In `ps1-core/src/gpu/gp0.zig`, add to `PgxpStats`:

```zig
        /// Textured triangles that took the perspective-correct path — all
        /// three vertices carrying a depth, with the setting on. Reported and
        /// ratcheted beside the hit rates; it is how much of the hit rate
        /// reaches a texel rather than only a position.
        perspective_primitives: u64 = 0,
```

add beside `pgxp_tolerance`:

```zig
    /// Mirrors `Bus.pgxpTextureCorrection()` — the sub-setting with the master
    /// flag already ANDed in, for the same reason `vertex_cache` is a mirror.
    /// Defaults FALSE here and TRUE on `Bus`: this is the value for an engine
    /// `Bus` has not spoken to yet, which must be no correction.
    pgxp_texture_correction: bool = false,
```

and add beside `unifyTextured`:

```zig
/// One textured triangle's three quantised reciprocal depths, or zeros.
///
/// Decided HERE, on the way to the sink, for the same reason `unify` and
/// `weldPoint` are: the record a Metal replay consumes must already be
/// normalised, so the two rasterizers cannot disagree about it. A quad's two
/// halves call this separately and normalise independently, which is safe
/// because the normalisation constant cancels — see `reciprocalDepths`.
fn reciprocalDepths(self: *Gp0Engine, vs: []const Primitive.TexturedPoint) [3]i32 {
    if (!self.pgxp_texture_correction) return .{ 0, 0, 0 };
    const rw = Primitive.reciprocalDepths(.{ vs[0].point.w, vs[1].point.w, vs[2].point.w });
    if (rw[0] != 0) self.pgxp.perspective_primitives += 1;
    return rw;
}
```

- [ ] **Step 5: Widen the sink and the four call sites**

In `ps1-core/src/gpu/sink.zig`, `drawTexturedTriangle` gains a final parameter and writes it:

```zig
        opcode: u8,
        /// The three quantised reciprocal depths, decided in `gp0` — see
        /// `Gp0Engine.reciprocalDepths`. All zero means the affine path.
        rw: [3]i32,
    ) void {
        var v = [3]command.Vertex{ texturedVertexOf(v0), texturedVertexOf(v1), texturedVertexOf(v2) };
        v[0].color = c0;
        v[1].color = c1;
        v[2].color = c2;
        v[0].rw = rw[0];
        v[1].rw = rw[1];
        v[2].rw = rw[2];
```

In `ps1-core/src/gpu/gp0.zig`, the four textured handlers:

```zig
        // drawTexturedTriangleCommand
        sink.drawTexturedTriangle(vram, draw_env, vs[0], vs[1], vs[2], color, color, color, clut, tpage, is_transp, opcode, self.reciprocalDepths(vs[0..3]));

        // drawTexturedQuadCommand
        sink.drawTexturedTriangle(vram, draw_env, vs[0], vs[1], vs[2], color, color, color, clut, tpage, is_transp, opcode, self.reciprocalDepths(vs[0..3]));
        sink.drawTexturedTriangle(vram, draw_env, vs[1], vs[2], vs[3], color, color, color, clut, tpage, is_transp, opcode, self.reciprocalDepths(vs[1..4]));

        // drawShadedTexturedTriangle
        sink.drawTexturedTriangle(vram, draw_env, vs[0], vs[1], vs[2], c0, c1, c2, clut, tpage, is_transp, opcode, self.reciprocalDepths(vs[0..3]));

        // drawShadedTexturedQuad — read the existing two calls and mirror the
        // quad above: vs[0..3] for the first half, vs[1..4] for the second.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig fmt ps1-core && zig build test 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 7: Confirm nothing moved**

Run:

```bash
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
```

Expected: `verify` at the recorded baseline failure count, `stream-verify` clean. With PGXP off nothing resolves, so every `rw` is zero and every byte is identical.

- [ ] **Step 8: Commit**

```bash
git add ps1-core/src/memory.zig ps1-core/src/gpu/gp0.zig ps1-core/src/gpu/sink.zig ps1-core/tests/gpu_test.zig
git commit -m "$(cat <<'EOF'
feat(pgxp): gp0 normalises a textured triangle's three depths into the record

`pgxp_texture_correction` ships ON, ANDed with the master flag in exactly one
place (Bus.pgxpTextureCorrection) and mirrored onto Gp0Engine at both setters,
because Gp0Engine decodes the vertex and cannot reach Bus. Assigned in
Bus.init as well as defaulted on the field: the @memset there does not respect
field defaults, and pgxp_culling and pgxp_cpu both shipped broken over that.

The triple is decided in gp0, on the way to the sink, for the same reason
`unify` and `weldPoint` are — the record a Metal replay consumes must already
be normalised. A quad's halves normalise independently, which is safe because
the constant cancels.

Neither rasterizer reads rw yet; verify and stream-verify are unmoved.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 5: The perspective interpolant in the software rasterizer

The first task where a pixel can change. The Zig side gets `interpW` and the branch; the tests are the arithmetic done on paper.

**Files:**
- Modify: `ps1-core/src/gpu/renderer.zig` (`interpW`, `drawTexturedTriangle`)
- Modify: `ps1-core/src/gpu/command.zig` (`execute` passes `cmd.v[i].rw`)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `command.Vertex.rw`.
- Produces: `Renderer.drawTexturedTriangle(..., opcode: u8, rw: [3]i32)` — `rw` appended last, matching `Sink.drawTexturedTriangle`.

**The worked example every test below is built on.** Vertices `(0,0)`, `(64,0)`, `(0,64)` with no sub-pixel, drawing offset 0, so `bx = by = 0` and the q-space coordinates are exactly 16× the integers: `(0,0)`, `(1024,0)`, `(0,1024)`. Twice the area is `1024 · 1024 = 1048576`. At pixel `(32, 16)` the q-space sample point is `(512, 256)` and the three unbiased weights are

```
w0 = orient2d(1024,0, 0,1024, 512,256) = (-1024)(256) - (1024)(-512) =  262144
w1 = orient2d(0,1024, 0,0,    512,256) = (0)(-768)    - (-1024)(512)  =  524288
w2 = orient2d(0,0,    1024,0, 512,256) = (1024)(256)  - (0)(512)      =  262144
                                                        w0+w1+w2 = 1048576 = area
```

so the barycentrics are exactly `1/4, 1/2, 1/4`. With texcoords `u = (0, 240, 0)` the AFFINE answer is `floor(240/2) = 120`. Now give the two u-zero corners the near depth and the u-240 corner a depth four times further: `W = (1, 4, 1)`, so `Wmin = 1` and `rw = (65536, 16384, 65536)` — v1, the far one, gets the quarter. Then

```
t0 = 262144 · 65536 = 17179869184
t1 = 524288 · 16384 =  8589934592
t2 = 262144 · 65536 = 17179869184
den = t0 + t1 + t2  = 42949672960
num = t1 · 240      = 2061584302080
u   = floor(num/den) = 48          (42949672960 · 48 = 2061584302080 exactly)
```

**48 against the affine 120.** Both are read back directly from VRAM by using a raw (unmodulated) textured triangle over a 16bpp direct texture whose texel at `(u, 0)` is `0x0100 | u`: non-zero for every `u` so it is never a hole, bit 15 clear so it is never semi-transparent, and the low byte is `u` itself.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 3 Task 5: perspective-correct texcoord interpolation.

/// A 16bpp direct texture page at (256, 256) whose texel at (u, 0) is
/// `0x0100 | u`: never zero (so never a hole), bit 15 clear (so never
/// semi-transparent), and carrying `u` in its low byte so a VRAM readback
/// names the texel that was sampled.
fn seedRampTexture(gpu: *Gpu) void {
    var u: usize = 0;
    while (u < 256) : (u += 1) {
        gpu.vram.data[256 * 1024 + 256 + u] = @intCast(0x0100 | u);
    }
}

/// tpage for that page: 16bpp direct (bits 7-8 = 2), x = 4 * 64 = 256
/// (bits 0-3 = 4), y = 256 (bit 4 set).
const ramp_tpage: u16 = 0x0100 | 0x0010 | 0x0004;

/// The triangle the worked example above is computed for. `opcode` 0x25 is a
/// RAW textured triangle, so the drawn pixel IS the texel and no modulation
/// stands between the interpolant and the readback.
fn drawRampTriangle(gpu: *Gpu, rw: [3]i32) void {
    Renderer.drawTexturedTriangle(
        &gpu.vram, &gpu.draw_env,
        tpt(0, 0, 0, 0), tpt(64, 0, 240, 0), tpt(0, 64, 0, 0),
        0, 0, 0,
        0, ramp_tpage,
        false, 0x25,
        rw,
    );
}

/// The arithmetic is done on paper in the plan and restated here, so this test
/// checks the FORMULA rather than checking the implementation against itself.
///
///   q-space vertices (0,0) (1024,0) (0,1024); twice-area 1048576
///   at pixel (32,16): w = (262144, 524288, 262144), i.e. 1/4, 1/2, 1/4
///   u = (0, 240, 0)                     -> affine 120
///   W = (1, 4, 1) -> rw = (65536, 16384, 65536)
///   t  = (17179869184, 8589934592, 17179869184), den = 42949672960
///   num = 8589934592 * 240 = 2061584302080 = den * 48 exactly
test "Phase3: a textured triangle samples the hand-computed perspective texel" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    seedRampTexture(&gpu);
    drawRampTriangle(&gpu, .{ 65536, 16384, 65536 });
    try expectEqual(@as(u16, 0x0100 | 48), gpu.vram.data[16 * 1024 + 32]);
}

/// The property that makes the fallback safe, pinned rather than reasoned
/// about: with three equal reciprocals the interpolant reduces to `interp`.
test "Phase3: three equal reciprocal depths reproduce the affine result" {
    for ([_]i32{ 1, 4096, 65536 }) |r| {
        var gpu = Gpu.init();
        setupGpu(&gpu);
        seedRampTexture(&gpu);
        drawRampTriangle(&gpu, .{ r, r, r });
        try expectEqual(@as(u16, 0x0100 | 120), gpu.vram.data[16 * 1024 + 32]);
    }
}

test "Phase3: a zero on any vertex takes the affine path" {
    for ([_][3]i32{
        .{ 0, 0, 0 },
        .{ 0, 16384, 65536 },
        .{ 65536, 0, 65536 },
        .{ 65536, 16384, 0 },
    }) |rw| {
        var gpu = Gpu.init();
        setupGpu(&gpu);
        seedRampTexture(&gpu);
        drawRampTriangle(&gpu, rw);
        try expectEqual(@as(u16, 0x0100 | 120), gpu.vram.data[16 * 1024 + 32]);
    }
}

/// The whole triangle, not one pixel: the interpolant must stay a convex
/// combination of the three texcoords, so the defensive clamp in the shader
/// still cannot trigger and no pixel samples outside the ramp.
test "Phase3: every perspective-sampled texel stays inside the texcoord range" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    seedRampTexture(&gpu);
    drawRampTriangle(&gpu, .{ 65536, 16384, 65536 });
    var y: usize = 0;
    while (y < 66) : (y += 1) {
        var x: usize = 0;
        while (x < 66) : (x += 1) {
            const p = gpu.vram.data[y * 1024 + x];
            if (p == 0) continue;
            try std.testing.expect(p >= 0x0100 and p <= 0x0100 + 240);
        }
    }
}

/// The overflow bound, exercised at the cap rather than argued about: a
/// primitive at the oversized limit, the widest depth ratio the clamp allows,
/// and the largest texcoord. It must produce that texel rather than trap.
///
/// A DIFFERENT texture page from the ramp, and one single texel, because this
/// triangle covers most of VRAM — including the ramp page. A primitive that
/// samples its own destination is a permanent divergence class between the two
/// rasterizers (the software one scans row by row and sees its own new values;
/// nothing orders fragments within one primitive on a GPU), so no test here may
/// contain one. Page (0, 256) with u = v = 255 reads VRAM (255, 511), and
/// (255, 511) is outside this triangle: the edge from (1023, 0) to (0, 511)
/// reaches y = 511 only at x = 0.
test "Phase3: the overflow bound holds at the oversized cap" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    const lone: u16 = 0x01FF;
    gpu.vram.data[511 * 1024 + 255] = lone;
    Renderer.drawTexturedTriangle(
        &gpu.vram, &gpu.draw_env,
        tpt(0, 0, 255, 255), tpt(1023, 0, 255, 255), tpt(0, 511, 255, 255),
        0, 0, 0,
        0, 0x0100 | 0x0010, // 16bpp direct, tpage_x = 0, tpage_y = 256
        false, 0x25,
        .{ 65536, 1, 65536 },
    );
    // u = v = 255 at all three vertices, so the interpolant is constant
    // whatever the weights are — what is under test is that computing it at
    // the cap does not overflow.
    try expectEqual(lone, gpu.vram.data[10 * 1024 + 10]);
}
```

`seedRampTexture` as written above fills only row 256, so a `v` above 0 would read a zero texel and hole. Every ramp test uses `v = 0`, so that is correct as it stands — but fill the whole page anyway so a later test cannot trip over it:

```zig
fn seedRampTexture(gpu: *Gpu) void {
    var v: usize = 0;
    while (v < 256) : (v += 1) {
        var u: usize = 0;
        while (u < 256) : (u += 1) {
            gpu.vram.data[(256 + v) * 1024 + 256 + u] = @intCast(0x0100 | u);
        }
    }
}
```

The ramp page at (256..511, 256..511) is outside every ramp triangle, which spans only (0..64, 0..64) — so none of those tests samples its own destination either.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -30`
Expected: `expected 12 arguments, found 13` at `drawTexturedTriangle`. After adding the parameter but before adding the branch, the first test must fail with `expected 0x130, found 0x178` — **run it in that intermediate state and record the output**, because a test that cannot distinguish the perspective answer from the affine one is worse than no test.

- [ ] **Step 3: Add `interpW` to `renderer.zig`**

Beside `interp`:

```zig
    /// Exact perspective-correct interpolation of one integer attribute.
    ///
    ///     a = sum(w_i * rw_i * a_i) / sum(w_i * rw_i)
    ///
    /// where `rw_i` is the quantised reciprocal depth the record carries (see
    /// `primitive.zig`'s `reciprocalDepths`). A PS1 interpolates u/v linearly
    /// in screen space, which is correct only for a polygon parallel to the
    /// screen; on a floor or a wall the texture shears and slides as the
    /// camera moves. Interpolating `u/W` and `1/W` and dividing per fragment
    /// removes it.
    ///
    /// Position-evaluable by construction, exactly as `interp` is: everything
    /// here is either a weight the coverage test already produced or a field
    /// of the record, so the Metal fragment shader evaluates the same
    /// expression over the same integers and the two agree BY CONSTRUCTION
    /// rather than by a promise about two compilers' rounding. That exactness
    /// is what lets the PGXP-on parity gate be a strict equality.
    ///
    /// `area` is ABSENT, and that is not an omission: numerator and
    /// denominator are both first-order in `w`, so it cancels. So does any
    /// common factor in `rw`, which is why per-primitive normalisation is safe
    /// — and so does the internal resolution's factor, by the same argument
    /// `interp` uses.
    ///
    /// `den > 0` is guaranteed, not hoped for: coverage gives every `w_i >= 0`
    /// with `w0 + w1 + w2 == area > 0`, and `reciprocalDepths` clamps every
    /// `rw_i` to at least 1. `@divFloor` for the same reason `interp` uses it —
    /// it stays defined on the boundary pixels the fill rule admits.
    ///
    /// i64 throughout: `w_i * rw_i` reaches 2^45 and the numerator 2^55. The
    /// derivation is beside `primitive.rw_one`.
    fn interpW(
        w0: i32,
        w1: i32,
        w2: i32,
        a0: i32,
        a1: i32,
        a2: i32,
        rw0: i32,
        rw1: i32,
        rw2: i32,
    ) i32 {
        const t0 = @as(i64, w0) * @as(i64, rw0);
        const t1 = @as(i64, w1) * @as(i64, rw1);
        const t2 = @as(i64, w2) * @as(i64, rw2);
        const num = t0 * @as(i64, a0) + t1 * @as(i64, a1) + t2 * @as(i64, a2);
        return @intCast(@divFloor(num, t0 + t1 + t2));
    }
```

- [ ] **Step 4: Branch in `drawTexturedTriangle`**

Add `rw: [3]i32` as the last parameter of `Renderer.drawTexturedTriangle`, add `rw: [3]i32` and `perspective: bool` to `TexturedShader`, and replace the two texcoord interpolations:

```zig
                const iu = if (ctx.perspective)
                    interpW(w0, w1, w2, ctx.tu[0], ctx.tu[1], ctx.tu[2], ctx.rw[0], ctx.rw[1], ctx.rw[2])
                else
                    interp(w0, w1, w2, area, ctx.tu[0], ctx.tu[1], ctx.tu[2]);
                const iv = if (ctx.perspective)
                    interpW(w0, w1, w2, ctx.tv[0], ctx.tv[1], ctx.tv[2], ctx.rw[0], ctx.rw[1], ctx.rw[2])
                else
                    interp(w0, w1, w2, area, ctx.tv[0], ctx.tv[1], ctx.tv[2]);
                const u: u32 = @intCast(std.math.clamp(iu, 0, 255));
                const v: u32 = @intCast(std.math.clamp(iv, 0, 255));
```

and in the struct literal at the bottom:

```zig
            .rw = rw,
            // A triangle takes the perspective path if and only if all three
            // vertices carry a depth. `unify` already forces a primitive to be
            // all-resolved or none-resolved before the sink, so this is a
            // property of the record rather than a per-pixel decision.
            .perspective = rw[0] != 0 and rw[1] != 0 and rw[2] != 0,
```

**Only the texcoords take the perspective path.** The modulation colour keeps `interp`: colour correction is Phase 4 (the spec defers `gpu_pgxp_color_correction` explicitly), and changing it here would move every Gouraud-textured pixel in every PGXP-on frame for a reason nothing in this phase argues for.

- [ ] **Step 5: Pass `rw` through `command.execute`**

In `ps1-core/src/gpu/command.zig`, the `.draw_textured_triangle` arm gains a final argument:

```zig
            cmd.opcode,
            .{ cmd.v[0].rw, cmd.v[1].rw, cmd.v[2].rw },
        ),
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig fmt ps1-core && zig build test 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 7: Confirm the PGXP-off guarantee, then measure the PGXP-on sweep**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

Expected: the first two at the recorded baseline. The third runs with texture correction on for the first time; its hit-rate floors must all still pass (the feature does not change what resolves) and `perspective_primitives` is not yet reported — Task 9 adds that. Record the run's wall time and any floor that moved.

- [ ] **Step 8: Commit**

```bash
git add ps1-core/src/gpu/renderer.zig ps1-core/src/gpu/command.zig ps1-core/tests/gpu_test.zig
git commit -m "$(cat <<'EOF'
feat(gpu): perspective-correct texturing in the software rasterizer

interpW is sum(w_i*rw_i*a_i) / sum(w_i*rw_i) — every term an integer, the
division an integer division, and `area` absent because it cancels. A triangle
takes it iff all three vertices carry a depth; otherwise today's `interp` runs
and produces today's bytes. With PGXP off no rw is ever non-zero, so verify
and stream-verify are unchanged by construction.

The tests are the arithmetic done on paper: a triangle whose barycentrics at
one pixel are exactly 1/4, 1/2, 1/4 samples texel 48 at a 4:1 depth ratio
against the affine 120, and three equal reciprocals reproduce `interp` exactly.

Only the texcoords take the path. Colour correction is Phase 4.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 6: The same expression in Metal

`Ps1PrimInstance` carries the three reciprocals, `ps1_interp_w` sits beside `ps1_interp`, and the stale scaling comment on `ps1_interp` is corrected. The scaled-path assertion is the one that reaches inside a block.

**Files:**
- Modify: `ps1-macos/Shaders/PrimInstance.h`
- Modify: `ps1-macos/Shaders/Ps1Color.h`
- Modify: `ps1-macos/Shaders/Rasterizer.metal`
- Modify: `ps1-macos/Sources/PS1/PrimBuilder.swift`
- Test: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`

**Interfaces:**
- Consumes: `Ps1GpuVertex.rw` (Task 3).
- Produces: `Ps1PrimInstance.rw0, rw1, rw2` (three `int`s appended last, field count 48 → 51); `ps1_interp_w(int w0, int w1, int w2, int a0, int a1, int a2, int rw0, int rw1, int rw2) -> int`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`:

```swift
/// The scaled path's own gate, and it must reach INSIDE a block.
///
/// `readbackNative()` is the top-left subtexel of each block, where the sample
/// point IS the native pixel — so anything decided from px/py reproduces its
/// 1x answer there by construction and both existing gates pass whatever the
/// other s*s - 1 subtexels do. A correction applied only at the lattice would
/// be invisible to every gate this project has.
///
/// So: render the same triangle at 8x twice, once with a real depth ratio and
/// once with three equal reciprocals (which is the affine answer exactly), and
/// require them to differ at a subtexel that is NOT on the native lattice.
/// The texture the two tests below sample: a 16bpp direct page at (256, 256)
/// whose texel at (u, v) is `0x0100 | u`, so a raw (unmodulated) draw writes
/// the texel's own u and a readback names what was sampled. Seeded through
/// `preload:` rather than through a GP0 upload, so no pass split and no
/// primitive sampling its own destination.
private func rampVram() -> [UInt16] {
    var vram = [UInt16](repeating: 0, count: 1024 * 512)
    for v in 0..<256 {
        for u in 0..<256 { vram[(256 + v) * 1024 + 256 + u] = UInt16(0x0100 | u) }
    }
    return vram
}

/// The same triangle `gpu_test.zig`'s Phase 3 tests use: (0,0) (64,0) (0,64),
/// u = 0, 240, 0. The ramp page at (256..511, 256..511) is well outside it.
private func rampTriangle(_ rw: (Int32, Int32, Int32)) -> (MetalRasterizer) -> Void {
    return { r in
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)

        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue)
        tri.opcode = 0x25                                  // raw: no modulation
        tri.tpage = 0x0100 | 0x0010 | 0x0004               // 16bpp, page (256, 256)
        tri.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        tri.v.1 = Ps1GpuVertex(x: 64, y: 0, u: 240, v: 0, _pad: 0, color: 0)
        tri.v.2 = Ps1GpuVertex(x: 0, y: 64, u: 0, v: 0, _pad: 0, color: 0)
        tri.v.0.rw = rw.0
        tri.v.1.rw = rw.1
        tri.v.2.rw = rw.2
        r.apply(tri)
    }
}

@Test func perspectiveCorrectionReachesTheInteriorOfABlockAtEightX() throws {
    let scale = 8
    let vram = rampVram()
    guard let affine = try MetalScaleHarness.frame(scale: scale, preload: vram,
                                                   rampTriangle((65536, 65536, 65536))),
          let persp = try MetalScaleHarness.frame(scale: scale, preload: vram,
                                                  rampTriangle((65536, 16384, 65536)))
    else { return }

    // Without this the test passes against a shader that refuses the triangle
    // outright, which is a different bug with the same shape.
    #expect((0..<(64 * scale)).contains { y in
        (0..<(64 * scale)).contains { x in affine.scaled[y * affine.width + x] != 0 }
    }, "the affine control drew nothing")

    var onLattice = 0, offLattice = 0
    for y in 0..<(64 * scale) {
        for x in 0..<(64 * scale)
        where affine.scaled[y * affine.width + x] != persp.scaled[y * persp.width + x] {
            if x % scale == 0 && y % scale == 0 { onLattice += 1 } else { offLattice += 1 }
        }
    }
    #expect(onLattice > 0, "the correction did not change the 1x picture at all")
    #expect(offLattice > 0,
            "the correction fires only at the native lattice — the one bug no existing gate can see")
}

/// The perspective SIGNATURE, read on rows `readbackNative()` never looks at.
///
/// Across a receding surface the texel steps SHRINK with distance; affine's are
/// uniform. Row 8*ny + 4 is the middle of a block, so every sample here is one
/// the downsample-invariance gate is blind to by construction.
@Test func aPerspectiveRowStepsFasterNearThanFarOffTheLattice() throws {
    let scale = 8
    let vram = rampVram()
    // 16:1 rather than the 4:1 used elsewhere, so the near/far step difference
    // is large enough to read through integer flooring.
    guard let persp = try MetalScaleHarness.frame(scale: scale, preload: vram,
                                                  rampTriangle((65536, 4096, 65536))),
          let affine = try MetalScaleHarness.frame(scale: scale, preload: vram,
                                                   rampTriangle((65536, 65536, 65536)))
    else { return }

    /// The sampled `u` at every painted subtexel of one off-lattice row,
    /// left to right. `0x0100 | u` is the texel, so the low byte IS u.
    func row(_ f: MetalScaleHarness.Frame, _ y: Int) -> [Int] {
        (0..<(64 * scale)).compactMap { x -> Int? in
            let p = f.scaled[y * f.width + x]
            return p == 0 ? nil : Int(p & 0xFF)
        }
    }

    /// Mean step over the first and last thirds of the span. A single first
    /// difference is ±1 noise from the flooring; a third of the span is not.
    func nearFar(_ us: [Int]) -> (Double, Double) {
        let n = us.count / 3
        let near = Double(us[n] - us[0]) / Double(n)
        let far = Double(us[us.count - 1] - us[us.count - 1 - n]) / Double(n)
        return (near, far)
    }

    let y = 4                                   // inside native row 0, off the lattice
    let pu = row(persp, y), au = row(affine, y)
    #expect(pu.count > 30, "too few painted subtexels on row \(y) to read a trend")
    #expect(pu.count == au.count, "the two renders disagree on coverage, not just on sampling")

    let (pNear, pFar) = nearFar(pu)
    let (aNear, aFar) = nearFar(au)
    // Affine is the control: its step is uniform, so near and far agree.
    #expect(abs(aNear - aFar) < 0.05,
            Comment(rawValue: "the affine control is not uniform: near \(aNear), far \(aFar)"))
    // Perspective on a receding surface steps faster near than far.
    #expect(pNear > pFar * 1.5,
            Comment(rawValue: "no perspective trend off the lattice: near \(pNear), far \(pFar)"))
}
```

**The `1.5` and the `0.05` are the two numbers in this plan that are not derived.** Run the test once against the real render and read the printed `near`/`far` before landing it; widen the depth ratio or relax the factor to what the data carries, and say in the comment what was measured. Then confirm it FAILS with `rampTriangle((65536, 65536, 65536))` substituted for the perspective render — a guard test that cannot fail is worse than none.

Also update the stride assertion in `Rasterizer.metal`:

```c
static_assert(sizeof(Ps1PrimInstance) == 4 * 51,
              "Ps1PrimInstance layout changed — update the Swift stride test too");
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pkill -x Substation; zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -30`
Expected: the metallib build fails on the `4 * 51` assert until the fields are added; once they are, `perspectiveCorrectionReachesTheInteriorOfABlockAtEightX` fails with `onLattice == 0` (the shader ignores `rw`).

- [ ] **Step 3: Add the instance fields**

In `ps1-macos/Shaders/PrimInstance.h`, append to `Ps1PrimInstance` after `word_base, pixel_first, pixel_last`:

```c
    /* Quantised reciprocal depths, one per vertex — round(2^16 * Wmin / W_i),
       computed once per triangle on the CPU in ps1-core and carried through
       the record. All three non-zero means this triangle's texcoords are
       interpolated perspective-correctly; any zero means the affine path.

       Native, like every other field here: the reciprocal is a property of the
       geometry and carries no factor of the internal resolution. Textured
       triangles only. */
    int rw0, rw1, rw2;
```

- [ ] **Step 4: Add `ps1_interp_w` and correct `ps1_interp`'s comment**

In `ps1-macos/Shaders/Ps1Color.h`, **replace** `ps1_interp`'s doc comment's scaling paragraph. What is there today says the weights and the area scale by `s^2`; they do not, and the numbers built on it are wrong with it. The corrected text:

```c
/// Exact barycentric interpolation of one integer attribute.
///
/// `renderer.zig` does this in i64 because the expanded plane equation's
/// constant term exceeds i32. Nothing is expanded here — the weights are
/// evaluated at the pixel — but `ps1_orient` over box-relative 1/16-px
/// coordinates already reaches 2^29, so the numerator, bounded by area * 255,
/// reaches about 1.4e11 and needs `long` at 1x alone.
///
/// It needs NO MORE than that at any internal resolution.
/// `ps1_triangle_coverage` reduces the SAMPLE POINT to native 1/16-px units
/// (`qpx = (px * 16) / s`) rather than scaling the vertices up, so neither the
/// weights nor the area carries a factor of s and this bound is scale-
/// independent. An earlier version of this comment claimed both scaled by s^2
/// and put the ceiling at s = 5; that described the arrangement Phase C
/// inverted.
///
/// The DIVISION is exact and scale-invariant regardless: numerator and
/// denominator carry any common factor alike, and integer division satisfies
/// floor(k*num / k*den) == floor(num/den). Plain `/` rather than a floor
/// because on a covered pixel num >= 0 and area > 0.
inline int ps1_interp(int w0, int w1, int w2, int area, int a0, int a1, int a2) {
    long num = long(w0) * long(a0) + long(w1) * long(a1) + long(w2) * long(a2);
    return int(num / long(area));
}

/// `ps1_interp`'s perspective-correct sibling: renderer.zig's `interpW`,
/// transcribed. THE SAME EXPRESSION over the same integers, which is what lets
/// the PGXP-on parity gate be a strict equality rather than a tolerance.
///
///     a = sum(w_i * rw_i * a_i) / sum(w_i * rw_i)
///
/// `rw_i` is the quantised reciprocal depth the instance carries, decided once
/// per triangle on the CPU. `area` is absent because it cancels — numerator
/// and denominator are both first-order in w — and so does any common factor
/// in rw, which is why per-primitive normalisation is safe.
///
/// `den > 0` is guaranteed: coverage gives every w_i >= 0 with
/// w0 + w1 + w2 == area > 0, and the CPU clamps every rw_i to at least 1.
///
/// `long` throughout: w_i * rw_i reaches 2^45 and the numerator 2^55. The
/// derivation is beside `primitive.rw_one` in ps1-core. Note this is in the
/// ATTRIBUTE math, which crossed into `long` in Phase 0 — CLAUDE.md's "1/16 px
/// is a ceiling, more means `long` in the per-fragment loop" is about the
/// COVERAGE math, which is int and stays int.
inline int ps1_interp_w(int w0, int w1, int w2, int a0, int a1, int a2,
                        int rw0, int rw1, int rw2) {
    long t0 = long(w0) * long(rw0);
    long t1 = long(w1) * long(rw1);
    long t2 = long(w2) * long(rw2);
    long num = t0 * long(a0) + t1 * long(a1) + t2 * long(a2);
    return int(num / (t0 + t1 + t2));
}
```

- [ ] **Step 5: Branch in the textured-triangle fragment path**

In `ps1-macos/Shaders/Rasterizer.metal`, inside the `PS1_PRIM_TEXTURED_TRI` arm, replace the two texcoord lines:

```c
        // All three non-zero means every vertex carries a depth, which is a
        // property of the record: `unify` forces a primitive all-resolved or
        // none-resolved before the sink, so this is never a per-fragment
        // decision about geometry.
        bool perspective = p.rw0 != 0 && p.rw1 != 0 && p.rw2 != 0;
        int iu = perspective
            ? ps1_interp_w(w0, w1, w2, p.u0, p.u1, p.u2, p.rw0, p.rw1, p.rw2)
            : ps1_interp(w0, w1, w2, area, p.u0, p.u1, p.u2);
        int iv = perspective
            ? ps1_interp_w(w0, w1, w2, p.v0, p.v1, p.v2, p.rw0, p.rw1, p.rw2)
            : ps1_interp(w0, w1, w2, area, p.v0, p.v1, p.v2);
        uint u = uint(clamp(iu, 0, 255));
        uint v = uint(clamp(iv, 0, 255));
```

The three modulation-colour interpolations below it keep `ps1_interp`, matching `renderer.zig`. Colour correction is Phase 4.

- [ ] **Step 6: Copy `rw` in `PrimBuilder`**

In `ps1-macos/Sources/PS1/PrimBuilder.swift`, in `triangle(_:env:kind:)`, after the texcoord assignments:

```swift
        // Native, like every other field: the reciprocal is a property of the
        // geometry. Zero on every non-PGXP vertex, which is the affine path.
        (inst.rw0, inst.rw1, inst.rw2) = (verts[0].rw, verts[1].rw, verts[2].rw)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `pkill -x Substation; zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -30`
Expected: the full suite green, both new tests passing. Re-run once if `Failing tests:` appears with zero `✘` lines.

- [ ] **Step 8: Confirm Gate 1 and Gate 2 did not move**

Both are inside `ps1-macos/test.sh`. Confirm specifically that `MetalRasterizerTests` (Gate 1, the fixture hashes at 1x) and `MetalScaleTests`' downsample-invariance cases are green. Every fixture in the corpus was captured with PGXP off, so every `rw` in them is zero and the affine branch runs: a divergence there is a bug in the branch, never a hash to recapture.

- [ ] **Step 9: Commit**

```bash
git add ps1-macos/Shaders ps1-macos/Sources/PS1/PrimBuilder.swift ps1-macos/Tests/PS1Tests/MetalScaleTests.swift
git commit -m "$(cat <<'EOF'
feat(gpu): the Metal backend evaluates the same perspective interpolant

ps1_interp_w is renderer.zig's interpW transcribed — the same expression over
the same integers, which is what lets the PGXP-on parity gate be a strict
equality rather than a tolerance. Ps1PrimInstance carries the three native
reciprocals; the modulation colour keeps ps1_interp, since colour correction
is Phase 4.

ps1_interp's scaling comment is corrected while we are here. It claimed the
weights and the area both scale by s^2 and put int32's ceiling at s = 5;
ps1_triangle_coverage reduces the SAMPLE POINT to native units instead, so
neither carries a factor of s and the bound is scale-independent. The `long`
is still needed at 1x alone.

The scaled-path test asserts what readbackNative cannot see: a correction that
fired only at the native lattice would pass every gate this project has.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 7: The setting reaches the player

The C ABI setter, the atomic in the runner, the `UserDefaults`-backed setting and the greyed menu entry.

**Files:**
- Modify: `ps1-capi/include/ps1.h`, `ps1-capi/src/root.zig`
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift`, `EmulatorRunner.swift`, `EmulatorViewModel.swift`, `PgxpSetting.swift`
- Modify: `ps1-macos/Sources/PS1App/VideoCommands.swift`
- Test: `ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift`

**Interfaces:**
- Consumes: `Bus.setPgxpTextureCorrection` (Task 4).
- Produces:
  - C: `void ps1_set_pgxp_texture_correction(Ps1*, int enabled);`
  - Swift: `PgxpSetting.textureCorrection: Bool` (default `true`), `setTextureCorrection(_:)`, defaults key `pgxpEnabled.textureCorrection`; `Ps1Core.setPgxpTextureCorrection(_:)`; `EmulatorRunner.setPgxpTextureCorrection(_:)`; `EmulatorViewModel.pgxpTextureCorrection: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift`:

```swift
/// Texture correction ships ON, so a MISSING key must read as true — which
/// `bool(forKey:)` cannot express. The same trap `cpu` and `culling` carry.
@Test func textureCorrectionDefaultsOnForAFreshInstall() {
    let d = UserDefaults(suiteName: "pgxp.tc.fresh.\(UUID().uuidString)")!
    let s = PgxpSetting(key: "pgxpEnabled", defaults: d)
    #expect(s.textureCorrection)
}

@Test func textureCorrectionPersistsWhenTurnedOff() {
    let suite = "pgxp.tc.persist.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    var s = PgxpSetting(key: "pgxpEnabled", defaults: d)
    s.setTextureCorrection(false)
    #expect(!PgxpSetting(key: "pgxpEnabled", defaults: d).textureCorrection)
    s.setTextureCorrection(true)
    #expect(PgxpSetting(key: "pgxpEnabled", defaults: d).textureCorrection)
}
```

Read the existing tests in that file first and match their `UserDefaults` suite convention exactly — if they use a different fixture helper, use it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -20`
Expected: `value of type 'PgxpSetting' has no member 'textureCorrection'`.

- [ ] **Step 3: Add the C ABI setter**

In `ps1-capi/include/ps1.h`, after `ps1_set_pgxp_culling`, and change the paragraph above the group from "The four below" to "The five below":

```c
/* Perspective-correct texturing. A PS1 interpolates u/v linearly in screen
 * space, which is only correct for a polygon parallel to the screen; on a
 * floor or a wall the texture shears and slides as the camera moves.
 * Non-zero = on, and this is the DEFAULT — texture correction and culling
 * correction are the picture, while the vertex cache and CPU mode are the
 * workarounds. Textured RECTANGLES stay affine: a sprite has one position and
 * a size, no per-vertex depth, and is 2D by construction. */
void    ps1_set_pgxp_texture_correction(Ps1*, int enabled);
```

In `ps1-capi/src/root.zig`, beside `ps1_set_pgxp_culling` (find it with `grep -n ps1_set_pgxp_culling ps1-capi/src/root.zig`) and matching its exact shape:

```zig
export fn ps1_set_pgxp_texture_correction(p: ?*Ps1, enabled: c_int) void {
    const s = handle(p) orelse return;
    s.bus.setPgxpTextureCorrection(enabled != 0);
}
```

Read the neighbouring export before writing this — the null-handle idiom and the field path must match what is already there.

- [ ] **Step 4: Add the Swift setting**

In `ps1-macos/Sources/PS1/PgxpSetting.swift`, extend the type comment's "Three of them invert this type's original reasoning" to "Four of them", and add:

```swift
    /// Perspective-correct texturing. Ships ON, like `culling` — these two are
    /// the picture, where `cpu` and `vertexCache` are the workarounds.
    private(set) var textureCorrection: Bool
```

```swift
    private var textureCorrectionKey: String { key + ".textureCorrection" }
```

in `init`:

```swift
        self.textureCorrection =
            (defaults.object(forKey: key + ".textureCorrection") as? NSNumber)?.boolValue ?? true
```

and:

```swift
    mutating func setTextureCorrection(_ value: Bool) {
        textureCorrection = value
        defaults.set(value, forKey: textureCorrectionKey)
    }
```

- [ ] **Step 5: Wire it to the core**

`ps1-macos/Sources/PS1/Ps1Core.swift`, beside `setPgxpCulling`:

```swift
    func setPgxpTextureCorrection(_ enabled: Bool) {
        ps1_set_pgxp_texture_correction(handle, enabled ? 1 : 0)
    }
```

`ps1-macos/Sources/PS1/EmulatorRunner.swift`: add a `pgxpTextureCorrection` atomic beside `pgxpCulling` (copy its declaration verbatim, including the initial value — which must be `true`), the setter:

```swift
    func setPgxpTextureCorrection(_ enabled: Bool) {
        pgxpTextureCorrection.store(enabled, ordering: .releasing)
    }
```

and in the run loop, beside `core.setPgxpCulling(...)`:

```swift
            core.setPgxpTextureCorrection(pgxpTextureCorrection.load(ordering: .acquiring))
```

`ps1-macos/Sources/PS1/EmulatorViewModel.swift`: the property, beside `pgxpCulling`:

```swift
    public var pgxpTextureCorrection: Bool {
        get { pgxpSetting.textureCorrection }
        set {
            pgxpSetting.setTextureCorrection(newValue)
            runner?.setPgxpTextureCorrection(newValue)
        }
    }
```

and in the per-disc re-application block (~line 543), beside `runner.setPgxpCulling(pgxpSetting.culling)`, updating the comment from "All five" to "All six":

```swift
            runner.setPgxpTextureCorrection(pgxpSetting.textureCorrection)
```

- [ ] **Step 6: Add the menu entry**

`ps1-macos/Sources/PS1App/VideoCommands.swift`, inside the `Group` that carries `.disabled(!model.pgxpEnabled)`, first in the list because it is the one a player will look for:

```swift
                Toggle("PGXP Texture Correction", isOn: $model.pgxpTextureCorrection)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `pkill -x Substation; zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -20`
Expected: green, including a `capi_test` pass from `zig build test`.

- [ ] **Step 8: See it in the real app**

Run: `zig build macos && open zig-out/Substation.app`, then Video ▸ check that **PGXP Texture Correction** appears greyed with PGXP off and enabled with it on. Load a 3D game (Tomb Raider or Crash) with PGXP on and toggle the entry; the floors and walls must visibly stop swimming. Note what you saw in the commit message — this is the first phase a player can see, and "the tests pass" is not the same claim.

- [ ] **Step 9: Commit**

```bash
git add ps1-capi ps1-macos/Sources ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift
git commit -m "$(cat <<'EOF'
feat(macos): PGXP Texture Correction is a Video menu setting

ps1_set_pgxp_texture_correction joins the sub-setting group in the C ABI, and
the Swift setting reads with object(forKey:) rather than bool(forKey:) because
it ships ON and a missing key must read as true — the trap `cpu` and `culling`
already carry. Greyed rather than silently ineffective while PGXP is off, and
re-applied per disc with the other five.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 8: The PGXP-on parity gate

The new gate the spec calls for: one 3D workload captured with PGXP on, replayed through both rasterizers at 1x, at strict full-VRAM equality. It is expressible as a strict equality only because the interpolant is exact.

**Files:**
- Modify: `ps1-golden/src/main.zig` (`--pgxp-on` names its own file)
- Modify: `build.zig` (the `fixtures` step)
- Create: `ps1-macos/Tests/PS1Tests/PgxpParityTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `zig-out/fixtures/tr1-usa-v1-1-pgxp.p1fx`, and a Swift test that replays it through `MetalFixtureHarness.replay` at strict per-frame hash equality.

**Why `tr1-usa-v1-1`.** It is 3D and texture-heavy with the classic swim case (floors and walls), it already has a pinned 100-frame capture window in `main.zig:463`, its PGXP hit rate is 99.1%, and Gate 4 puts it at 8.2 ms/frame against silent-hill's 33.7 — so it costs the Swift suite a fraction of what the other geometry fixture would.

- [ ] **Step 1: Write the failing test**

Create `ps1-macos/Tests/PS1Tests/PgxpParityTests.swift`:

```swift
import Foundation
import Testing
@testable import PS1

/// PGXP-ON PARITY, at STRICT equality — the gate that proves the shared
/// integer perspective path.
///
/// Every other fixture in the corpus was captured with PGXP off, so every `rw`
/// in them is zero and every textured triangle takes the affine branch: the
/// perspective interpolant is entirely uncovered by Gate 1 and Gate 2. This
/// fixture is the same 100-frame Tomb Raider window captured with PGXP on, so
/// its textured triangles carry real reciprocal depths and its per-frame VRAM
/// hashes are the software rasterizer's answer to them.
///
/// It is a STRICT equality rather than a tolerance only because the
/// interpolant is exact: every term is an integer and the division is an
/// integer division, so the two rasterizers evaluate one expression over
/// identical inputs and agree by construction. No float formulation could
/// offer this, and it matters because the comparison is a HASH — under float,
/// one ULP anywhere is a red gate with no diagnostic.
///
/// Skipped rather than failed when the fixture is absent: it needs
/// `zig build fixtures -Doptimize=ReleaseFast` and a `games/` directory.
@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "tr1-usa-v1-1-pgxp").path)),
      .timeLimit(.minutes(5)))
func aPgxpOnCaptureReplaysBitExactlyInMetal() throws {
    guard let r = try MetalFixtureHarness.replay("tr1-usa-v1-1-pgxp") else { return }
    #expect(r.firstDivergence == nil, Comment(rawValue: r.message))
    #expect(r.framesChecked == 100)
}

/// The gate above is worthless if the capture carried no perspective triangles
/// — a fixture recorded with PGXP accidentally off would pass it trivially, by
/// taking exactly the affine path Gate 1 already covers.
@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "tr1-usa-v1-1-pgxp").path)))
func thePgxpParityFixtureActuallyCarriesPerspectiveTriangles() throws {
    let file = try FixtureFile(contentsOf: FixtureFile.url(named: "tr1-usa-v1-1-pgxp"))
    var perspective = 0
    withExtendedLifetime(file) {
        for i in 0..<file.frames.count {
            for cmd in file.records(for: i)
            where cmd.kind == UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue) {
                let v = withUnsafeBytes(of: cmd.v) { raw -> [Ps1GpuVertex] in
                    let p = raw.bindMemory(to: Ps1GpuVertex.self)
                    return [p[0], p[1], p[2]]
                }
                if v[0].rw != 0 && v[1].rw != 0 && v[2].rw != 0 { perspective += 1 }
            }
        }
    }
    #expect(perspective > 1000,
            Comment(rawValue: "only \(perspective) perspective triangles — was the capture really --pgxp-on?"))
}
```

Check `MetalFixtureHarness.replay`'s `dither` default before relying on it: it pins `.native`, which is what this gate wants, since the reference is the software rasterizer and it dithers.

- [ ] **Step 2: Run the test to verify it is SKIPPED, not passing**

Run: `pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -i pgxpparity`
Expected: skipped — the fixture does not exist yet. A skipped gate is not a passing gate; Step 5 is where it acquires teeth.

- [ ] **Step 3: Give `--pgxp-on` its own output filename**

In `ps1-golden/src/main.zig`, in `runStreamCapture`, replace the output path construction:

```zig
    // `--pgxp-on` writes a SEPARATE file. The two captures of one workload are
    // different command streams — one carries reciprocal depths and the other
    // does not — and a shared name would silently overwrite whichever ran
    // first, leaving the PGXP-on gate comparing the affine capture.
    const path = if (opts.pgxp_on)
        try std.fmt.allocPrint(a, "{s}/{s}-pgxp.p1fx", .{ opts.out_dir, wl.key })
    else
        try std.fmt.allocPrint(a, "{s}/{s}.p1fx", .{ opts.out_dir, wl.key });
```

and update the `--pgxp-on` line in `usage`:

```zig
    \\  --pgxp-on               (stream-capture) capture with PGXP enabled, into
    \\                          `<key>-pgxp.p1fx` rather than `<key>.p1fx`
```

- [ ] **Step 4: Add the capture to the `fixtures` step**

In `build.zig`, after the `geometry_filters` loop and before `fixtures_step`:

```zig
    // The PGXP-ON parity fixture. Every other fixture in the corpus is
    // captured with PGXP off, so every `rw` in them is zero and the
    // perspective interpolant is uncovered by Gate 1 and Gate 2 alike. This is
    // the same tr1 window with PGXP on, and the Swift gate replaying it is the
    // whole automated coverage the shared integer path has.
    //
    // Chained onto the run before it for the same reason every other capture
    // is: `stream-capture` writes `synthetic-movers.p1fx` unconditionally,
    // regardless of filter, so parallel runs would race on that path.
    const fixtures_run_pgxp = b.addRunArtifact(golden_exe);
    fixtures_run_pgxp.step.dependOn(&prev_fixture_run.step);
    fixtures_run_pgxp.addArgs(&.{ "stream-capture", "--filter=tr1-usa-v1-1", "--pgxp-on" });
    prev_fixture_run = fixtures_run_pgxp;
```

- [ ] **Step 5: Generate the fixture and run the gate for real**

```bash
zig build -Doptimize=ReleaseFast
zig build fixtures -Doptimize=ReleaseFast
ls -la zig-out/fixtures/tr1-usa-v1-1-pgxp.p1fx
pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -30
```

Expected: the fixture exists, `thePgxpParityFixtureActuallyCarriesPerspectiveTriangles` reports a count in the thousands, and `aPgxpOnCaptureReplaysBitExactlyInMetal` is GREEN over 100 frames. **If it diverges, that is the gate doing its job** — the two rasterizers disagree on the perspective path and the first divergent frame's dump names the pixel. Do not weaken the gate to a tolerance; find the disagreement. `MetalFixtureHarness` prints `VramDump.report` for the first divergent frame.

- [x] **Step 6: Prove the gate can fail** — DONE 2026-09-15, after the two fixes below.

Temporarily change `ps1_interp_w`'s `t0 + t1 + t2` to `t0 + t1 + t2 + 1` in `Ps1Color.h`, rebuild the metallib, and confirm `aPgxpOnCaptureReplaysBitExactlyInMetal` goes RED. Revert. A guard test that cannot fail is worse than none, and this one is the phase's headline claim.

**This step failed on 2026-09-13 and stayed failed through four escalating perturbations, up to XOR-ing the low bit of every pixel every primitive kind writes. Both causes are now fixed and the step passes: `firstDivergence → 0` under the perturbation, green again on revert (`006a8f9`, `fb6a2e3`).**

1. **The fixture drew nothing.** `runStreamCapture` blanked live VRAM at the window boundary to make a from-blank replay reproducible. It was reproducible — and empty. tr1's textures were uploaded before the window, so blanking destroyed them, every textured primitive sampled texel 0 (transparent), and the game drew no pixels for 100 straight frames. All 100 recorded hashes were `0xa96777069d622325`, which is FNV-1a over an all-zero 1 MB buffer. The gate compared blank against blank, and no corruption of a fragment path can redden that. `ff7-menu` was blank the same way; `tr1-usa-v1-1` (affine, ungated) too. The window now carries a synthesized whole-VRAM upload — `ps1-golden/src/vram_seed.zig` — and tr1 hashes 41 distinct frames.
2. **The shader was not always rebuilt.** `zig build metallib` declared only the `.metal` sources as cache inputs, not the headers they include, so a `Ps1Color.h`-only edit left the old metallib installed.

**Hazard worth knowing:** `-only-testing:PS1Tests/aTestName` (no parentheses) matches no swift-testing free function and reports `Executed 0 tests` as **passed**. The parentheses are required.

- [ ] **Step 7: Commit**

```bash
git add ps1-golden/src/main.zig build.zig ps1-macos/Tests/PS1Tests/PgxpParityTests.swift
git commit -m "$(cat <<'EOF'
test(pgxp): a PGXP-on parity fixture, at strict equality

Every fixture in the corpus was captured with PGXP off, so every rw in them is
zero and the perspective interpolant is uncovered by Gate 1 and Gate 2 alike.
`stream-capture --pgxp-on` now writes `<key>-pgxp.p1fx` rather than
overwriting the affine capture, and `zig build fixtures` captures the tr1
window both ways.

The gate is a STRICT full-VRAM equality, not a tolerance, and it is only
expressible because the interpolant is exact — under float, one ULP anywhere
is a red hash with no diagnostic. A second test asserts the fixture actually
carries perspective triangles, so a capture recorded with PGXP accidentally
off cannot pass it trivially. Verified to fail against a perturbed denominator.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 9: `perspective_primitives` in the sweep, and its ratchet

How much of the hit rate reaches a texel rather than only a position, reported and ratcheted in the same file as the hit rates and the clamp ceilings.

**Files:**
- Modify: `ps1-golden/src/pgxp_sweep.zig` (`Report`, `report`, a third ratchet parser)
- Modify: `ps1-golden/src/main.zig` (`runPgxp` copies the counter; `readFloors` parses the third kind)
- Modify: `ps1-core/tests/goldens/pgxp/floors.txt`

**Interfaces:**
- Consumes: `Gp0Engine.PgxpStats.perspective_primitives` (Task 4).
- Produces: `pgxp_sweep.Report.perspective_primitives: u64`; a `perspective <key> <count>` FLOOR line in `floors.txt`, parsed by `parsePerspectiveFloors` and checked by `report`.

- [ ] **Step 1: Write the failing test**

`pgxp_sweep.zig` has no test file of its own today; add unit tests to it inline, which is what `parseFloors` already lacks and should have:

```zig
test "the three ratchet line kinds do not read each other's lines" {
    const text =
        \\# comment
        \\croc 99.4
        \\clamped croc 81466
        \\perspective croc 12345
        \\
    ;
    const a = std.testing.allocator;
    const floors = try parseFloors(a, text);
    defer a.free(floors);
    const ceilings = try parseClampCeilings(a, text);
    defer a.free(ceilings);
    const persp = try parsePerspectiveFloors(a, text);
    defer a.free(persp);

    try std.testing.expectEqual(@as(usize, 1), floors.len);
    try std.testing.expectEqual(@as(usize, 1), ceilings.len);
    try std.testing.expectEqual(@as(usize, 1), persp.len);
    try std.testing.expectEqual(@as(u64, 12345), persp[0].count);
}
```

`golden_test.zig` already pulls `pgxp_sweep.zig`'s own tests into its binary (`test { _ = @import("pgxp_sweep.zig"); ... }` at the top of the file), so this test runs under `zig build test` with no `build.zig` change.

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: `no member named 'parsePerspectiveFloors'`.

- [ ] **Step 3: Add the counter to the report**

In `ps1-golden/src/pgxp_sweep.zig`, add to `Report`:

```zig
    /// Textured triangles sampled perspective-correctly — all three vertices
    /// carrying a depth, with the setting on. It is how much of the hit rate
    /// reaches a TEXEL rather than only a position, which is a different
    /// question from `resolved` and the one this phase moves.
    perspective_primitives: u64 = 0,
```

Add the parser:

```zig
/// The prefix that marks a `perspective_primitives` FLOOR line — a floor, not
/// a ceiling, because more perspective triangles is the improvement here where
/// more clamps is the regression.
const perspective_prefix = "perspective ";

pub const PerspectiveFloor = struct {
    key: []const u8,
    count: u64,
};

/// Parses the SAME `floors.txt` a third time, for `perspective <key> <count>`
/// lines. Everything else is skipped, mirroring the other two parsers skipping
/// these.
pub fn parsePerspectiveFloors(a: std.mem.Allocator, text: []const u8) ![]PerspectiveFloor {
    var out = std.ArrayList(PerspectiveFloor).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, perspective_prefix)) continue;
        const rest = std.mem.trim(u8, line[perspective_prefix.len..], " \t");
        const sep = std.mem.indexOfAny(u8, rest, " \t") orelse return error.BadFloorLine;
        const value = std.mem.trim(u8, rest[sep..], " \t");
        try out.append(a, .{
            .key = rest[0..sep],
            .count = try std.fmt.parseInt(u64, value, 10),
        });
    }
    return out.toOwnedSlice(a);
}

pub fn perspectiveFloorFor(floors: []const PerspectiveFloor, key: []const u8) ?u64 {
    for (floors) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.count;
    }
    return null;
}
```

**Both existing parsers need the new skip added**, or `parseFloors` will call `parseFloat` on `"croc 12345"` from a `perspective ` line and error out, taking the whole sweep with it. In `parseFloors`, beside its existing `clamp_prefix` skip:

```zig
        if (std.mem.startsWith(u8, line, perspective_prefix)) continue;
```

and the same line in `parseClampCeilings`, before its `if (!std.mem.startsWith(u8, line, clamp_prefix)) continue;` — which happens to skip it already, but stating it keeps the three symmetric and stops the next kind being added wrongly. That asymmetry is exactly what the Step 1 test pins.

In `report`, take the floors as a third slice parameter and add the check beside the clamp-ceiling one, matching its existing column formatting and its `failures`/bool return convention:

```zig
    if (perspectiveFloorFor(perspective, key)) |floor| {
        if (r.perspective_primitives < floor) {
            std.debug.print("  {s: <22} perspective {s} BELOW FLOOR {d}\n",
                .{ key, commas(&buf, r.perspective_primitives), floor });
            failed = true;
        }
    }
```

Read the surrounding lines of `report` before pasting: `commas` needs its own 26-byte buffer, and the existing code declares one per call site.

In `ps1-golden/src/main.zig`, in the block that builds the `Report` (around line 550, `const p = bus.gpu.gp0.pgxp;`), add:

```zig
        .perspective_primitives = p.perspective_primitives,
```

and in `readFloors`, parse and return the third list, extending the `Floors` struct with `perspective: []pgxp_sweep.PerspectiveFloor`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig fmt ps1-golden && zig build test 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 5: Measure and pin the floors**

```bash
zig build -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- pgxp 2>&1 | tee /tmp/pgxp-sweep.txt
```

Record every workload's `perspective_primitives`. Add a block to `ps1-core/tests/goldens/pgxp/floors.txt`:

```
# `perspective <key> <count>` — the number of textured triangles sampled
# perspective-correctly, a FLOOR rather than a ceiling: more of them is the
# improvement, where more `clamped` is the regression. Pinned at the measured
# value rounded DOWN to three significant figures, so a propagation regression
# that costs coverage shows up here as well as in the hit rate.
#
# Measured <DATE>, the full unfiltered sweep closing PGXP Phase 3, with the
# shipped defaults — which as of that day include TEXTURE CORRECTION ON.
#
perspective bios-only                  <measured>
perspective crash-bandicoot-europe-edc <measured>
perspective crash-bandicoot-warped     <measured>
perspective crash-bandicoot-2          <measured>
perspective resident-evil-usa          <measured>
perspective croc                       <measured>
perspective silent-hill-usa            <measured>
perspective mgs                        <measured>
perspective tr1-usa-v1-1               <measured>
perspective spyro-the-dragon-usa       <measured>
```

Those ten keys are the full sweep as of the Phase 2 measurement block already in that file; confirm the list against the sweep's own output rather than against this plan, since `games/` decides it.

A workload with no line is a WARNING, not an error, exactly as a missing hit-rate floor is. **A zero for any 3D workload is a finding, not a floor** — it means no textured triangle in that capture had three resolved vertices, and the cause has to be understood before a zero is pinned.

- [ ] **Step 6: Confirm the sweep is green against its own floors**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- pgxp`
Expected: no failures.

- [ ] **Step 7: Commit**

```bash
git add ps1-golden/src/pgxp_sweep.zig ps1-golden/src/main.zig ps1-core/tests/goldens/pgxp/floors.txt
git commit -m "$(cat <<'EOF'
test(pgxp): the sweep counts and ratchets perspective_primitives

How much of the hit rate reaches a TEXEL rather than only a position, which is
a different question from `resolved` and the one this phase moves. A FLOOR, not
a ceiling — more of them is the improvement, where more `clamped` is the
regression.

The three ratchet kinds share one file, so each parser skips the other two's
prefixes; a unit test pins that they do not read each other's lines, which is
the mistake a third kind makes easy.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 10: The inherited open question — measure croc's drifted W

The spec specifies this as a MEASUREMENT, not a design decision taken blind. Phase 2 left croc clamping 81,466 of 199,788 resolved vertices, 75,726 of them drifting a full pixel or more, peaking at 2.03 px. `toFixed` pins a drifted vertex's POSITION inside its own wire pixel; **nothing pins its W**, and there is no hardware value to pin one against. This phase is where that stops being theoretical, because texture correction reads W per fragment.

**Files:**
- Modify: `.claude/skills/ps1-pgxp/SKILL.md` (the finding)
- Create: nothing. **Do NOT pre-emptively build a W-specific admission test.**

**Interfaces:** none — this task produces a measurement and a written finding.

- [ ] **Step 1: Run the lockstep A/B**

`ps1-trace`'s `tol=<px>` is the lockstep A/B, because tolerance is consumed only at the GP0 vertex decode: `tol=1.0` (which rejects exactly the `drift_far` set) and the default `-1` run the identical instruction stream and land on the same frame. A PGXP on/off A/B does NOT work — float NCLIP writes MAC0, the game reads it, and the two runs diverge into different scenes.

```bash
zig build -Doptimize=ReleaseFast
mkdir -p /tmp/croc-tol-all /tmp/croc-tol-1
PS1_VRAM_DUMP=1 ./zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin \
  "games/croc/croc.cue" 700000000 /tmp/croc-tol-all explore lean pgxp 2>&1 | tail -5
PS1_VRAM_DUMP=1 ./zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin \
  "games/croc/croc.cue" 700000000 /tmp/croc-tol-1 explore lean pgxp tol=1.0 2>&1 | tail -5
```

Confirm from the `[probe]` lines that both runs report the SAME `vertices=` count. If they do not, the runs are not in lockstep and nothing below means anything. Adjust the instruction budget until a frame with real 3D geometry is dumped; check the exact `games/croc` path and cue name with `ls games/`.

- [ ] **Step 2: Compare the two on a 3D surface**

Diff the matching `vram_*.ppm` pairs. **Classify before concluding**: the question is not "do pixels differ" — Phase 2 already measured that the drifted set changes 30-62% of painted pixels through texture and dither sampling shifting by a sub-pixel, with geometry landing in the same place. The question this phase adds is narrower: **does a 3D floor or wall show visible texture SWIM in the `tol=-1` run that the `tol=1.0` run does not** — a coherent sliding or shearing of the texture across the surface, not a scattering of ±1 sampling differences.

- [ ] **Step 3: Write the finding down, whichever way it lands**

Append a dated paragraph to `.claude/skills/ps1-pgxp/SKILL.md`, replacing the existing closing paragraph ("**What is still open is the W, and it is Phase 3's problem.**"). State what was run, what was seen, and the conclusion. **If the drifted W values do produce visible swim**, the mitigation is `pgxp_tolerance`, which already exists and already ships off, and the finding is an argument for a W-specific admission test rather than a position-based one — **record that argument; do not build the test.** Phase 2 measured that refusing the drifted set on position costs croc 1,150,338 → 817,838 resolved and takes `mixed_primitives` from 4,938 to 111,405, because `unify` snaps a whole primitive back when one vertex is refused. A refusal that costs twenty times what it repairs needs evidence first, and one A/B is not yet that evidence.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/ps1-pgxp/SKILL.md
git commit -m "$(cat <<'EOF'
docs(pgxp): what croc's drifted W values do to a corrected texture

The measurement Phase 3 inherited. `toFixed` pins a drifted vertex's POSITION
inside its own wire pixel and nothing pins its W — there is a hardware integer
SXY to clamp a position to and no hardware value whatsoever to clamp a depth
to. Run as a lockstep tol=-1 against tol=1.0 A/B, which is the only A/B that
stays on one instruction stream.

No W-specific admission test is built: refusing the drifted set on position
costs twenty times what it repairs, and one A/B is not yet evidence for a
second refusal rule.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

### Task 11: The rules the next reader needs

Everything above is worthless to whoever meets it cold without the tripwires. `CLAUDE.md` carries the one-line rules; the skills carry the reasoning.

**Files:**
- Modify: `CLAUDE.md` (the `ps1-gpu-metal` and `ps1-pgxp` rule blocks, the `test` binary count if it moved, the `.p1fx` version if it is named)
- Modify: `.claude/skills/ps1-pgxp/SKILL.md`
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md`
- Modify: `.claude/skills/ps1-test-harnesses/SKILL.md`

**Interfaces:** none.

- [ ] **Step 1: Add the rules to `CLAUDE.md`**

Under **PGXP** (`ps1-pgxp`):

```markdown
- **A textured triangle takes the perspective path IFF all three vertices
  carry a depth**, signalled by `rw != 0` on all three. With PGXP off no
  vertex resolves, so every `rw` is 0 and every output byte is unchanged BY
  CONSTRUCTION — a moved golden there is a bug in the gating, never a
  behaviour change to recapture.
- **A vertex's depth travels with its position, everywhere.** `unify` clears
  `w` when it snaps a primitive back, and `weldPoint` publishes and adopts `w`
  with `px`/`py`. One vertex's position paired with another's depth is the
  mixed-coordinate-space defect, one level down.
- **The `rw` normalisation constant CANCELS**, so it decides quantisation only
  and a quad's two halves may normalise independently. The clamp to 1 is what
  makes the denominator provably positive.
- **Textured RECTANGLES stay affine, permanently.** A sprite has one position
  and a size and no per-vertex depth to interpolate between.
- **Only the TEXCOORDS take the perspective path.** The modulation colour keeps
  `interp` in both rasterizers; colour correction is a later phase.
```

Under **GPU + Metal** (`ps1-gpu-metal`):

```markdown
- **`ps1_interp_w` and `interpW` are ONE expression over identical integers**,
  and that exactness is the only reason the PGXP-on parity gate can be a strict
  equality. No float formulation of it is acceptable.
- **Neither the weights nor the area carries a factor of the internal
  resolution.** `ps1_triangle_coverage` reduces the SAMPLE POINT to native
  1/16-px units; `ps1_interp`'s old "both scale by s^2" comment was stale and
  every bound built on it was wrong.
```

Update the `zig build test` row if the binary count changed, and the `zig build fixtures` row to say that `--pgxp-on` writes `<key>-pgxp.p1fx` and that `tr1-usa-v1-1-pgxp.p1fx` is the PGXP-on parity gate's fixture.

- [ ] **Step 2: Extend `.claude/skills/ps1-pgxp/SKILL.md`**

Add a Phase 3 section covering: the interpolant and the four properties (exact, scale-invariant, constant cancels, divide already paid); why DuckStation's deal is not available to us (its hardware rasterizer interpolates for free and its `gpu_sw.cpp` has zero PGXP references, so it has no second rasterizer to be in parity with — on this question it is one engineering trade-off, not an oracle, because texture correction is not a hardware behaviour at all); the `weldPoint` depth rule and why it exists; the quantisation and its overflow derivation; and the result of Task 10's measurement.

- [ ] **Step 3: Extend `.claude/skills/ps1-gpu-metal/SKILL.md`**

Add: `ps1_interp_w` beside `ps1_interp`; the correction to the stale scaling comment and what it invalidated; the scaled-path blind spot as it applies here (a correction firing only at the native lattice passes every existing gate, and the test that catches it); and the `Ps1PrimInstance` field count 48 → 51 with its `static_assert`.

- [ ] **Step 4: Extend `.claude/skills/ps1-test-harnesses/SKILL.md`**

Add: `.p1fx` version 3 and what changed (24-byte `Vertex`, 108-byte `Command`); `--pgxp-on` writing `<key>-pgxp.p1fx`; the PGXP-on parity gate, what it proves that Gate 1 and Gate 2 cannot, and the companion test that stops an accidentally-affine capture passing it trivially; and the `perspective <key> <count>` floor lines in `floors.txt` with the note that all three parsers must skip each other's prefixes.

- [ ] **Step 5: Run everything one last time**

```bash
zig fmt ps1-core ps1-golden ps1-capi
zig build test
zig build test-roms-pl
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
zig build capi-lib && zig build metallib
pkill -x Substation; ps1-macos/test.sh
```

Expected: every command green, with `verify` at the baseline failure count recorded in Task 1 Step 7 and no other failures. **Paste the actual output into the commit message** — a completion claim without the output is not a completion claim.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md .claude/skills
git commit -m "$(cat <<'EOF'
docs: the Phase 3 rules, and the one that was already wrong

Six new tripwires in CLAUDE.md and the reasoning behind them in the three
skills that own it. The one worth reading twice is not new: ps1_interp's doc
comment claimed the weights and the area both scale by s^2 at internal
resolution and put int32's ceiling at s = 5. Phase C inverted that — the
SAMPLE POINT is reduced to native units instead — so every bound built on it
was wrong, in the safe direction, for three phases.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01He7qKJ6zjiHjicJB4Yk2M5
EOF
)"
```

---

## Self-review against the spec

**Spec coverage.** Every section maps to a task.

| Spec section | Task |
|---|---|
| `Point`/`Vertex` carry the depth; `getPointPrecise` stops dropping `p.z` | 1, 3 |
| The perspective interpolant as one shared integer expression | 5, 6 |
| `.p1fx` version 3, `Ps1PrimInstance` fields, C ABI setter, Swift setting, menu item | 3, 6, 7 |
| A new gate: PGXP-on fixture, both rasterizers, strict equality | 8 |
| Quantisation and the named constant with its derivation | 2 |
| The overflow bound, and the "verify rather than trust" scaling question | Review section (settled); 2, 6 |
| Which primitives take the path; `unify` clears `rw` | 1, 4, 5 |
| Plumbing table, all nine rows | 1, 3, 4, 5, 6, 7 |
| The setting: default ON, ANDed in one place, set in `Bus.init` | 4, 7 |
| Gates unchanged and still strict | 1, 3, 4, 5, 6 verification steps |
| `perspective_primitives` counter, reported and ratcheted | 9 |
| Gate 2's blind spot / the interior-of-block assertion | 6 (with the spec's proposed assertion corrected) |
| The inherited open question, as a measurement | 10 |
| Every unit and Swift test the spec lists | 2, 4, 5, 6, 7, 8 |

Two spec items are deliberately **out**, as the spec itself says: the depth buffer, `transparent_depth`, colour correction and `disable_2d` (Phase 4); preserve-projection-precision (Phase 5); DuckStation's widescreen hack (never). Textured rectangles stay affine permanently.

**Two additions beyond the spec**, both argued in the Review section: `weldPoint` carrying `w` (Task 1), and `--pgxp-on` writing its own filename (Task 8, without which the new gate would silently compare the affine capture).

**One spec assertion replaced**: the scaled-path interior test. "Not the same texel repeated" cannot fail, because `qpx` already varies by 2 q-units per subtexel at `s = 8` under affine interpolation too.

**Type consistency.** `Primitive.Point.w: f32`; `Primitive.rw_one: i32`; `Primitive.reciprocalDepths([3]f32) [3]i32`; `command.Vertex.rw: i32`; `Sink.drawTexturedTriangle(..., rw: [3]i32)` and `Renderer.drawTexturedTriangle(..., rw: [3]i32)` both take it last and both match `command.execute`'s call; `Ps1GpuVertex.rw` is `int32_t`; `Ps1PrimInstance.rw0/rw1/rw2` are `int`; `ps1_interp_w` and `interpW` take `(w0,w1,w2,a0,a1,a2,rw0,rw1,rw2)` in that order on both sides. `Bus.pgxpTextureCorrection()` is the AND, `Gp0Engine.pgxp_texture_correction` is the mirror, `PgxpSetting.textureCorrection` is the Swift name and `ps1_set_pgxp_texture_correction` the C one.
