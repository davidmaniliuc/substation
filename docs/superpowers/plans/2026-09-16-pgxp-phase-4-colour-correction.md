# PGXP Phase 4 — Perspective-Correct Colour Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Gouraud triangle whose three vertices carry a depth is shaded perspective-correctly in both the Zig software rasterizer and the Metal backend, bit-for-bit identically, under a setting that is independently switchable from texture correction, with every existing gate unchanged and still strict.

**Architecture:** Phase 3 built the interpolant (`a = Σ(wᵢ·rwᵢ·aᵢ) / Σ(wᵢ·rwᵢ)`) and the record field it reads (`Vertex.rw`); this phase points the same expression at the vertex colour. Two settings now consume one `rw`, so the record has to say WHICH attribute may use it: `Command._pad0` — dead in both declarations and referenced nowhere — becomes `Command.flags: u8` carrying one bit per corrected attribute class. The bits are decided in `gp0.zig` on the way to the sink, beside `rw` itself, because a Metal replay has only the record. No stride moves: not `Vertex` (24), not `Command` (108), not `Ps1PrimInstance` (51 ints), not the `.p1fx` version (3).

**Tech Stack:** Zig 0.16.0 (`ps1-core`, `ps1-golden`, `ps1-capi`), Metal Shading Language (`ps1-macos/Shaders`), Swift + swift-testing (`ps1-macos`), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-09-16-pgxp-phase-4-colour-correction-design.md`

---

## Review of the spec before planning

Seven things were checked against the tree. Five confirm the spec; two are gaps the plan closes, and one is a stale instruction in the spec's own testing section.

**1. GAP — `reciprocalDepths`'s gate must WIDEN, and the spec does not say so.** `Gp0Engine.reciprocalDepths` (`gp0.zig:454`) returns `.{0,0,0}` when `pgxp_texture_correction` is off. With two settings that is wrong at exactly one site class: a **Gouraud-textured** triangle drawn with colour correction ON and texture correction OFF needs a real `rw`, and under today's gate it would get zeros — so the colour branch, which also requires `rw != 0`, could never fire. The gate becomes "texture correction OR colour correction", and the two flag bits then select which attribute actually uses the depth. Task 3 does this, and the four-combination test in Task 3 is what catches it.

**2. The flat-shaded carve-out can be made STRUCTURAL as well as arithmetic, and should be.** The spec argues it arithmetically: three equal colours make `interpW` return exactly `c`, so `gp0.zig:694`/`:706`'s `color, color, color` sites are bit-identical either way. True, and pinned by a test. But `gp0` also KNOWS which opcodes carry three possibly-different colours, so the plan passes `gouraud: false` at the two flat-shaded textured sites and never sets the colour bit there at all. The arithmetic property stays pinned by its own test — the structural refusal is a second lock on the same door, not a replacement for the first.

**3. SETTLED — `ps1_interp_w`'s truncating division stays correct, and its comment is the thing that is wrong.** `Ps1Color.h:279` warns that "an attribute that can go negative (Phase 4's signed colour deltas) would need a real floor here". Checked: a colour channel arrives as an unsigned 8-bit wire field (`renderer.zig:384-386` masks `c & 0xFF`), the dither offset is added AFTER interpolation (`renderer.zig:367-371`), and the clamp is after that. So `num >= 0` still holds, plain `/` still agrees exactly with `@divFloor`, and there are no signed colour deltas anywhere in this phase. Task 5 corrects the comment; the division does not change.

**4. The overflow derivation carries over verbatim.** `primitive.rw_one`'s bound (`primitive.zig:250-262`) is stated over "an 8-bit wire field", which a colour channel also is: `aᵢ·rwᵢ < 2^24`, numerator `< 2^55`, denominator `< 2^47`, inside `i64` at every internal resolution. No constant moves; Task 4 widens the wording only.

**5. `renderer.zig` must NOT import `command.zig`.** `command.zig` imports `renderer.zig` (`command.zig:16`), so the flag constants stay in `command.zig` and `execute` decodes them into plain `bool`s before calling the renderer. The renderer never learns the record's encoding — which is also why it can keep taking `rw: [3]i32` unchanged.

**6. STALE — there are no "sub-setting count assertions in the menu tests".** The spec's testing section asks to increment them. `grep` finds no such assertion anywhere in `ps1-macos/Tests`. What is actually stale is `PgxpSettingTests.swift:32`'s comment ("The four sub-settings", when there are five) and `theSubSettingsKeepTheirOwnKeys`, which exercises four of the five keys. Task 8 fixes the comment and extends that test rather than incrementing a count that does not exist.

**7. `renderer.zig` is already 679 lines**, past CLAUDE.md's ~600 rule, and this phase adds roughly 25 more. Not split here, deliberately: the split worth doing is lifting the four shader structs into a `gpu/shaders.zig`, which touches every rasterizer entry point at once and would land on top of the only phase whose whole safety argument is "nothing else moved". Flagged in Task 9 as the follow-up.

---

## Global Constraints

Exact values, copied from the spec and from `CLAUDE.md`. Every task's requirements implicitly include this section.

- **Zig 0.16.0.** `zig version` must print exactly that.
- **Run every command from the repo root.** The harnesses read the BIOS, `games/` and the test ROMs relative to the process CWD.
- **With PGXP off, every output byte in this phase is unchanged BY CONSTRUCTION.** No vertex resolves, so every `rw` is 0, so `rw != 0` fails and the affine branch runs. The new bits NARROW the perspective path and can never widen it, because `rw != 0` remains a necessary condition. `trace-golden -- verify`, `trace-golden -- stream-verify`, Gate 1 (fixture hashes at 1x) and Gate 2 (`readbackNative` at scale equals 1x) cannot move. **If one moves it is a bug in the gating, never a behaviour change to recapture** — do NOT run `trace-golden -- capture` and do NOT re-pin a PL floor at any point in this plan.
- **No stride changes.** `@sizeOf(Vertex) == 24`, `@sizeOf(Command) == 108`, `PS1_GPU_COMMAND_STRIDE == 108`, `.p1fx` `version == 3`, `Ps1PrimInstance` stays 51 `int`s. A version-3 fixture captured before this phase must still load: a byte written zero decodes as "neither attribute corrected", which is what those captures did.
- **`pgxp_color_correction` defaults OFF, and a default-OFF flag must NOT be assigned in `Bus.init`.** The `@memset` there gives it `false`, which is correct; an assignment would be noise. This is the exact inverse of the `pgxp_culling`/`pgxp_cpu`/`pgxp_texture_correction` rule and it is easy to get backwards.
- **The sub-setting is ANDed with the master flag in ONE place**, `Bus.pgxpColorCorrection()`, mirrored onto `Gp0Engine` at both setters — the same shape as `Bus.pgxpTextureCorrection()`.
- **The Swift side reads the key with `object(forKey:)`, not `bool(forKey:)`**, even though the default is `false` and `bool(forKey:)` would give the right answer. Uniformity with the other four is the point: the next default-ON setting added beside it must not inherit a probe-free idiom.
- **No `f32` in the rasterizer inner loop, in either rasterizer.** `f32` appears only in `Primitive.Point.w` and the once-per-triangle `reciprocalDepths` reduction, both on the CPU before the sink.
- **A record carries every input its effect needs**; nothing may be re-derived at replay time, and records stay in native 1024×512 units at every scale.
- **`ps1_interp_w` and `interpW` are ONE expression over identical integers.** No float formulation is acceptable. The same now applies to whatever wrapper selects between affine and perspective: it must be the same shape on both sides.
- **The fill-rule bias stays at `-1`** in both rasterizers. Nothing in this plan touches coverage.
- **Textured RECTANGLES stay affine, permanently**, and flat-shaded primitives of every class are out by construction.
- **Run `zig fmt` before every commit.** Match the surrounding style: inline field defaults, doc comments that state the reasoning, no thinking-out-loud comments, no copy-pasted blocks.
- **`zig build trace-golden` and `zig build fixtures` must be run `-Doptimize=ReleaseFast`.** A Debug core runs at ~0.45× real time and reads as a hang.
- **`pkill -x Substation` before running `ps1-macos/test.sh`.** A running app shares the bundle id and fails the run in a way that looks like a real failure. The script needs `zig build capi-lib` and `zig build metallib` built first.
- **The Swift suite intermittently crashes the test process under sustained scale-8 load.** The tell is `Failing tests:` with zero `✘` lines. Re-run before believing it.
- **Every carve-out test must be verified to FAIL against the naive implementation before the implementation lands.** A guard test that cannot fail is worse than none — `0xa96777069d622325` is the standing reminder. Each task below names the mutation to try.
- **Never `git push`.** Commit to `master` locally, one commit per task.

---

## File Structure

| File | Responsibility after this phase |
|---|---|
| `ps1-core/src/gpu/command.zig` | `_pad0` → `flags: u8`; `flag_texture_perspective` / `flag_color_perspective`; `execute` decodes both into `bool`s for the two triangle renderers |
| `ps1-core/src/gpu/sink.zig` | `drawShadedTriangle` gains `rw: [3]i32, flags: u8`; `drawTexturedTriangle` gains `flags: u8`; both write them into the record |
| `ps1-core/src/gpu/gp0.zig` | `Depths` (rw + flags, decided together); `shadedDepths` / `texturedDepths`; the `pgxp_color_correction` mirror; `shaded_triangles` + `color_perspective_primitives` |
| `ps1-core/src/gpu/renderer.zig` | `interpAttr`; the perspective branch for `r/g/b` in `ShadedShader` and for `cr/cg/cb` in `TexturedShader` |
| `ps1-core/src/gpu/primitive.zig` | the `rw_one` overflow comment widened from "texcoord" to "8-bit wire attribute" |
| `ps1-core/src/memory.zig` | `Bus.pgxp_color_correction`, `pgxpColorCorrection()`, `setPgxpColorCorrection` — and deliberately nothing in `Bus.init` |
| `ps1-capi/include/ps1.h` | `Ps1GpuCommand.flags`; `PS1_GPU_FLAG_TEXTURE_PERSPECTIVE` / `PS1_GPU_FLAG_COLOR_PERSPECTIVE`; `ps1_set_pgxp_color_correction` |
| `ps1-capi/src/root.zig` | the setter; the snapshot/restore of the flag across `ps1_swap_disc` |
| `ps1-macos/Shaders/PrimInstance.h` | `PS1_PRIM_TEXTURE_PERSPECTIVE` / `PS1_PRIM_COLOR_PERSPECTIVE` beside the five existing bits |
| `ps1-macos/Shaders/Ps1Color.h` | `ps1_interp_attr`; the corrected "signed colour deltas" comment |
| `ps1-macos/Shaders/Rasterizer.metal` | the branch in `PS1_PRIM_GOURAUD_TRI` and in `PS1_PRIM_TEXTURED_TRI` |
| `ps1-macos/Sources/PS1/PrimBuilder.swift` | translates the record's two bits into the instance's two bits |
| `ps1-macos/Sources/PS1/PgxpSetting.swift` | `colorCorrection`, default OFF, probed with `object(forKey:)` |
| `ps1-macos/Sources/PS1/{Ps1Core,EmulatorRunner,EmulatorViewModel}.swift` | the setting's path from the menu to the core |
| `ps1-macos/Sources/PS1App/VideoCommands.swift` | the sixth toggle in the greyed group |
| `ps1-golden/src/main.zig` | `--pgxp-on` enables every correction sub-setting; the sweep forces them on |
| `ps1-golden/src/pgxp_sweep.zig` | `shaded_triangles` + `color_perspective_primitives`; the `color ` ratchet; `Ratchets` replaces main.zig's `Floors` |
| `ps1-core/tests/{gpu_test,pgxp_test}.zig` | the arithmetic, the carve-out, the four combinations, the `unify` clears |
| `ps1-macos/Tests/PS1Tests/{PgxpParityTests,MetalScaleTests,PgxpSettingTests}.swift` | the widened parity fixture, the off-lattice Gouraud assertion, the setting |
| `ps1-core/tests/goldens/pgxp/floors.txt` | the fourth ratchet's measured lines and its header |
| `CLAUDE.md`, `.claude/skills/ps1-pgxp/SKILL.md` | the rules a cold reader needs |

---

### Task 1: `Command.flags` — the byte, end to end

The transport lands in one task so it crosses every boundary at once: a record byte, an ABI byte, an instance bit, and the textured gate reshaped without changing behaviour. Nothing here can move a pixel — the texture bit is set exactly when `pgxp_texture_correction` is on, which is exactly the condition that produces a non-zero `rw` today, so `bit && rw != 0` and `rw != 0` are the same predicate at this commit.

**Files:**
- Modify: `ps1-core/src/gpu/command.zig:106` (`_pad0`), `:163-186` (`execute`)
- Modify: `ps1-core/src/gpu/sink.zig:69-89` (`drawShadedTriangle`), `:91-124` (`drawTexturedTriangle`)
- Modify: `ps1-core/src/gpu/gp0.zig:454-461` (`reciprocalDepths`), `:666`, `:678-679`, `:694`, `:706-707`, `:725`, `:742-743`
- Modify: `ps1-core/src/gpu/renderer.zig:346-356` (`drawShadedTriangle` signature), `:512-526` (`drawTexturedTriangle` signature), `:612` (the gate)
- Modify: `ps1-capi/include/ps1.h:229` (`_pad0`), and the PGXP block near `:281`
- Modify: `ps1-macos/Shaders/PrimInstance.h:34-39` (the flag block)
- Modify: `ps1-macos/Sources/PS1/PrimBuilder.swift:96` (the `transparent` line's neighbourhood)
- Test: `ps1-core/tests/gpu_test.zig`, `ps1-capi/src/capi_test.zig`, `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift`

**Interfaces:**
- Produces: `command.flag_texture_perspective: u8 = 1 << 0`, `command.flag_color_perspective: u8 = 1 << 1`, `Command.flags: u8`; `Sink.drawShadedTriangle(..., is_transparent: bool, rw: [3]i32, flags: u8)`; `Sink.drawTexturedTriangle(..., rw: [3]i32, flags: u8)`; `Renderer.drawShadedTriangle(..., is_transparent: bool, rw: [3]i32, perspective_color: bool)`; `Renderer.drawTexturedTriangle(..., rw: [3]i32, perspective_texture: bool, perspective_color: bool)`; C `PS1_GPU_FLAG_TEXTURE_PERSPECTIVE` / `PS1_GPU_FLAG_COLOR_PERSPECTIVE`; MSL `PS1_PRIM_TEXTURE_PERSPECTIVE = (1u << 5)` / `PS1_PRIM_COLOR_PERSPECTIVE = (1u << 6)`.
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing test**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// --- Phase 4 Task 1: the flags byte.

// The bit is a property of the RECORD, not of the renderer: a Metal replay
// has only the record, so a bit re-derived on either side is exactly the
// second transcription the sink exists to prevent.
test "Phase4: a corrected textured triangle records the texture bit" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    gpu.gp0.pgxp_enabled = true;
    gpu.gp0.pgxp_texture_correction = true;
    gpu.sink.rec.arm();

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
    _ = gpu.step(1000);

    const rec = lastRecord(&gpu, .draw_textured_triangle);
    try std.testing.expect((rec.flags & command.flag_texture_perspective) != 0);
    try expectEqual(@as(u8, 0), rec.flags & command.flag_color_perspective);
}

test "Phase4: an uncorrected textured triangle records neither bit" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    gpu.gp0.pgxp_enabled = true;
    gpu.gp0.pgxp_texture_correction = false;
    gpu.sink.rec.arm();

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
    _ = gpu.step(1000);

    try expectEqual(@as(u8, 0), lastRecord(&gpu, .draw_textured_triangle).flags);
}
```

These tests need the recorder, which the shared unit-test module cannot see. **Put them in `ps1-core/tests/gpu_stream_test.zig` instead** — it is the binary built against the recording core module — and add the helper there:

```zig
/// The last record of a given kind in the armed recorder. The recorder is a
/// fixed-capacity array, so this reads the stream rather than a return value:
/// what is under test is what a Metal replay would receive.
fn lastRecord(gpu: *Gpu, kind: command.Kind) command.Command {
    const stream = gpu.sink.rec.stream();
    var i = stream.records.len;
    while (i > 0) {
        i -= 1;
        if (stream.records[i].kind == kind) return stream.records[i];
    }
    unreachable;
}
```

Adapt the two tests above to `gpu_stream_test.zig`'s `StreamCase` idiom (`case.gp0(word)` for plain words; use `case.gpu.writeGp0(word, value)` directly where a `pgxp.Value` is needed), and import `subPixelDepth` from `pgxp_value.zig` as that file already does.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — `no field named 'flags' in struct 'command.Command'` and `root struct of file 'command' has no member named 'flag_texture_perspective'`.

- [ ] **Step 3: Rename the pad byte and declare the bits**

In `ps1-core/src/gpu/command.zig`, above `pub const Command`:

```zig
/// `Command.flags`, one bit per attribute class that may be interpolated
/// through the vertex depths.
///
/// The record has to carry this because the rasterizers cannot see the
/// settings: a record is replayed by a Metal backend that has only the record.
/// With one setting consuming `rw` the non-zero test alone was enough; with
/// two it is not, because a triangle drawn with colour correction on and
/// texture correction off carries a depth that its texcoords must NOT use.
///
/// Each bit is ANDed with `rw != 0` at the point of use, never substituted for
/// it. That is what keeps the PGXP-off guarantee structural: no vertex
/// resolves, so every `rw` is 0, so no bit can widen anything.
pub const flag_texture_perspective: u8 = 1 << 0;
pub const flag_color_perspective: u8 = 1 << 1;
```

and replace the field:

```zig
    transparent: u8 = 0,
    /// See `flag_texture_perspective` above. Was `_pad0`, which cost no bytes
    /// to claim: the stride is unchanged and a version-3 fixture decodes its
    /// zero as "neither attribute corrected", which is what those captures did.
    flags: u8 = 0,
```

The two `comptime` size assertions at the foot of the file are unchanged and must still pass — that is the check that this cost no bytes.

- [ ] **Step 4: Decode the bits in `execute`**

In `command.zig`'s `execute`, the two triangle arms:

```zig
        .draw_shaded_triangle => Renderer.drawShadedTriangle(
            vram,
            env,
            vertexPoint(cmd.v[0]),
            cmd.v[0].color,
            vertexPoint(cmd.v[1]),
            cmd.v[1].color,
            vertexPoint(cmd.v[2]),
            cmd.v[2].color,
            transp,
            .{ cmd.v[0].rw, cmd.v[1].rw, cmd.v[2].rw },
            (cmd.flags & flag_color_perspective) != 0,
        ),
        .draw_textured_triangle => Renderer.drawTexturedTriangle(
            vram,
            env,
            vertexTexturedPoint(cmd.v[0]),
            vertexTexturedPoint(cmd.v[1]),
            vertexTexturedPoint(cmd.v[2]),
            cmd.v[0].color,
            cmd.v[1].color,
            cmd.v[2].color,
            cmd.clut,
            cmd.tpage,
            transp,
            cmd.opcode,
            .{ cmd.v[0].rw, cmd.v[1].rw, cmd.v[2].rw },
            (cmd.flags & flag_texture_perspective) != 0,
            (cmd.flags & flag_color_perspective) != 0,
        ),
```

Plain `bool`s rather than the raw byte: `command.zig` imports `renderer.zig`, so the renderer cannot import the constants back without a cycle, and it has no business knowing the record's encoding anyway.

- [ ] **Step 5: Widen the two renderer signatures, gate the texture path on the bit**

In `ps1-core/src/gpu/renderer.zig`, add to `drawShadedTriangle`'s parameter list, after `is_transparent: bool`:

```zig
        rw: [3]i32,
        perspective_color: bool,
```

and, for now, silence them at the top of the body so this step compiles without behaviour:

```zig
        // Read in Task 4; the record carries them from Task 1 so the transport
        // lands in one commit rather than two.
        _ = rw;
        _ = perspective_color;
```

In `drawTexturedTriangle`, add after `rw: [3]i32`:

```zig
        perspective_texture: bool,
        perspective_color: bool,
```

`_ = perspective_color;` for now, and change the gate at the foot of the shader context:

```zig
            // A triangle takes the perspective path if and only if the record
            // says this attribute may use the depths AND all three vertices
            // carry one. `unify` already forces a primitive all-resolved or
            // none-resolved before the sink, so the second clause is a property
            // of the record rather than a per-pixel decision about geometry.
            .perspective = perspective_texture and rw[0] != 0 and rw[1] != 0 and rw[2] != 0,
```

- [ ] **Step 6: Carry the flags through the sink**

In `ps1-core/src/gpu/sink.zig`, `drawShadedTriangle` gains two parameters and writes them:

```zig
    pub fn drawShadedTriangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        p0: Primitive.Point,
        c0: u32,
        p1: Primitive.Point,
        c1: u32,
        p2: Primitive.Point,
        c2: u32,
        is_transparent: bool,
        /// The three quantised reciprocal depths and the bits saying which
        /// attributes may use them — both decided in `gp0`, see
        /// `Gp0Engine.shadedDepths`. All-zero `rw` is the affine path.
        rw: [3]i32,
        flags: u8,
    ) void {
        var v0 = vertexOf(p0);
        var v1 = vertexOf(p1);
        var v2 = vertexOf(p2);
        v0.color = c0;
        v1.color = c1;
        v2.color = c2;
        v0.rw = rw[0];
        v1.rw = rw[1];
        v2.rw = rw[2];
        self.submit(vram, env, .{
            .kind = .draw_shaded_triangle,
            .transparent = @intFromBool(is_transparent),
            .flags = flags,
            .v = .{ v0, v1, v2 },
        });
    }
```

`drawTexturedTriangle` gains `flags: u8` after its existing `rw: [3]i32` and adds `.flags = flags,` to the record literal.

- [ ] **Step 7: Set the texture bit in `gp0`**

In `ps1-core/src/gpu/gp0.zig`, add the import beside the others at the top:

```zig
const command = @import("command.zig");
```

Change `reciprocalDepths` to return both halves:

```zig
    /// One triangle's three quantised reciprocal depths and the flag bits that
    /// say which of its attributes may interpolate through them.
    ///
    /// Decided together because the bits are a function of the settings AND of
    /// whether a depth survived — computing them apart is how they drift.
    const Depths = struct {
        rw: [3]i32 = .{ 0, 0, 0 },
        flags: u8 = 0,
    };

    /// One textured triangle's depths.
    ///
    /// Decided HERE, on the way to the sink, for the same reason `unify` and
    /// `weldPoint` are: the record a Metal replay consumes must already be
    /// normalised, so the two rasterizers cannot disagree about it. A quad's
    /// two halves call this separately and normalise independently, which is
    /// safe because the normalisation constant cancels — see
    /// `Primitive.reciprocalDepths`.
    fn reciprocalDepths(self: *Gp0Engine, vs: []const Primitive.TexturedPoint) Depths {
        self.pgxp.textured_triangles += 1;
        if (!self.pgxp_texture_correction) return .{};
        const rw = Primitive.reciprocalDepths(.{ vs[0].point.w, vs[1].point.w, vs[2].point.w });
        if (rw[0] == 0) return .{};
        self.pgxp.perspective_primitives += 1;
        return .{ .rw = rw, .flags = command.flag_texture_perspective };
    }
```

Each of the four `sink.drawTexturedTriangle` call sites changes from passing the triple to passing both halves — `gp0.zig:694`:

```zig
        const d = self.reciprocalDepths(vs[0..3]);
        sink.drawTexturedTriangle(vram, draw_env, vs[0], vs[1], vs[2], color, color, color, clut, tpage, is_transp, opcode, d.rw, d.flags);
```

and the same shape at `:706`/`:707`, `:725`, `:742`/`:743`. **Each half of a quad needs its own `const d`** — the two calls normalise independently and must not share one.

The three `sink.drawShadedTriangle` call sites pass zeros for now:

```zig
        sink.drawShadedTriangle(vram, draw_env, pts[0], c0, pts[1], c1, pts[2], c2, is_transp, .{ 0, 0, 0 }, 0);
```

Task 3 replaces those.

- [ ] **Step 8: Fix the two direct `Renderer` callers in the tests**

`ps1-core/tests/gpu_test.zig:943` and `:986` call `Renderer.drawShadedTriangle` directly. Append `, .{ 0, 0, 0 }, false` to each. `drawRampTriangle` (`:2064`) and the two direct `drawTexturedTriangle` calls gain `, true, false` after their `rw` argument — `true` because those tests pass a real `rw` and expect the perspective path.

- [ ] **Step 9: Mirror the byte across the C ABI**

In `ps1-capi/include/ps1.h`, replace `uint8_t _pad0;` in `Ps1GpuCommand`:

```c
    uint8_t  flags;   /* PS1_GPU_FLAG_* below. Was a pad byte, so the stride is
                         unchanged and a fixture written before this existed
                         decodes its zero as "neither attribute corrected". */
```

and above the struct:

```c
/* Which attributes of a triangle may be interpolated through the vertex
 * depths in Ps1GpuVertex.rw. Each is ANDed with "all three rw non-zero" at the
 * point of use, never substituted for it: with PGXP off no vertex resolves, so
 * every rw is zero and no flag can widen anything. */
#define PS1_GPU_FLAG_TEXTURE_PERSPECTIVE (1u << 0)
#define PS1_GPU_FLAG_COLOR_PERSPECTIVE   (1u << 1)
```

The `_Static_assert` on `PS1_GPU_COMMAND_STRIDE` is unchanged and must still hold.

- [ ] **Step 10: Add the two instance bits and translate them**

In `ps1-macos/Shaders/PrimInstance.h`, beneath `PS1_PRIM_CHECK_MASK`:

```c
#define PS1_PRIM_TEXTURE_PERSPECTIVE (1u << 5) /* record's PS1_GPU_FLAG_TEXTURE_PERSPECTIVE */
#define PS1_PRIM_COLOR_PERSPECTIVE   (1u << 6) /* record's PS1_GPU_FLAG_COLOR_PERSPECTIVE */
```

In `ps1-macos/Sources/PS1/PrimBuilder.swift`, in `triangle`, beside the `transparent` line:

```swift
        if cmd.transparent != 0 { inst.flags |= PS1_PRIM_TRANSPARENT }
        // Two namespaces, deliberately: the record's bits describe a GP0
        // primitive, the instance's describe one Metal draw. Translated here
        // for the same reason `transparent` is, rather than shared as one
        // constant — the two structs version independently.
        if cmd.flags & UInt8(PS1_GPU_FLAG_TEXTURE_PERSPECTIVE) != 0 {
            inst.flags |= PS1_PRIM_TEXTURE_PERSPECTIVE
        }
        if cmd.flags & UInt8(PS1_GPU_FLAG_COLOR_PERSPECTIVE) != 0 {
            inst.flags |= PS1_PRIM_COLOR_PERSPECTIVE
        }
        return inst
```

In `ps1-macos/Shaders/Rasterizer.metal`, the textured branch's gate at `:360`:

```c
        bool perspective = (p.flags & PS1_PRIM_TEXTURE_PERSPECTIVE) != 0
            && p.rw0 != 0 && p.rw1 != 0 && p.rw2 != 0;
```

- [ ] **Step 11: Add the Swift translation test**

Append to `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift`:

```swift
/// The record's bits and the instance's are two namespaces, so the mapping is
/// a thing that can be wrong. Pinned per bit rather than as a pair: swapping
/// the two would pass a test that only checked "flags != 0".
@Test func theRecordsPerspectiveBitsReachTheInstance() throws {
    for (recordBit, instanceBit) in [
        (PS1_GPU_FLAG_TEXTURE_PERSPECTIVE, PS1_PRIM_TEXTURE_PERSPECTIVE),
        (PS1_GPU_FLAG_COLOR_PERSPECTIVE, PS1_PRIM_COLOR_PERSPECTIVE),
    ] {
        var cmd = Ps1GpuCommand()
        cmd.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
        cmd.flags = UInt8(recordBit)
        cmd.v.0 = Ps1GpuVertex(x: 0, y: 0)
        cmd.v.1 = Ps1GpuVertex(x: 32, y: 0)
        cmd.v.2 = Ps1GpuVertex(x: 0, y: 32)
        let inst = try #require(PrimBuilder.triangle(cmd, env: DrawEnv(), kind: Int32(PS1_PRIM_GOURAUD_TRI)))
        #expect(inst.flags & instanceBit != 0)
        #expect(inst.flags & (PS1_PRIM_TEXTURE_PERSPECTIVE | PS1_PRIM_COLOR_PERSPECTIVE) == instanceBit)
    }
}
```

Use whatever `DrawEnv()` initialiser the neighbouring tests in that file already use for a full-VRAM clip; copy their setup verbatim rather than inventing one.

- [ ] **Step 12: Run everything and confirm nothing moved**

```bash
zig fmt ps1-core/src ps1-capi/src ps1-golden/src
zig build test
zig build capi-lib && zig build metallib
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
pkill -x Substation; ps1-macos/test.sh
```

Expected: all pass. `verify` and `stream-verify` must be clean — a move here is a bug in this task, not a behaviour change. (`verify` reports a known orphaned `mgs` golden key; that pre-existing failure is not this task's.)

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "feat(pgxp): Command.flags — one bit per perspective-corrected attribute

_pad0 was dead in both declarations and referenced nowhere, so the byte costs
nothing to claim and no stride moves. The texture bit is set exactly when
texture correction is on, which is exactly when rw is non-zero today, so
'bit && rw != 0' is the same predicate as 'rw != 0' at this commit.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DUCkCw9pmF4e3rv6Ct2LZ1"
```

---

### Task 2: `pgxp_color_correction`, the setting

Inert on landing: nothing reads it yet. Landed before Task 3 because `gp0` needs the mirror to decide the colour bit.

**Files:**
- Modify: `ps1-core/src/memory.zig:144` (beside `pgxp_texture_correction`), `:390-400` (`setPgxp`), `:420-431` (the accessor pair)
- Modify: `ps1-core/src/gpu/gp0.zig:124` (beside the `pgxp_texture_correction` mirror)
- Modify: `ps1-capi/src/root.zig:122-143` (the swap snapshot), `:449` (beside the texture setter)
- Modify: `ps1-capi/include/ps1.h` (the PGXP block)
- Test: `ps1-core/tests/gpu_test.zig`, `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Bus.pgxp_color_correction: bool` (default `false`), `Bus.pgxpColorCorrection() bool`, `Bus.setPgxpColorCorrection(bool) void`, `Gp0Engine.pgxp_color_correction: bool`, `ps1_set_pgxp_color_correction(Ps1*, int)`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`:

```zig
// The inverse of Phase 3's `Bus.init` test, and the inverse is the point: a
// default-OFF flag must NOT be assigned in `Bus.init`, because the @memset
// there already gives it false. An assignment would be noise, and copying the
// default-ON idiom onto it is the mistake this pins.
test "Phase4: colour correction is off by default" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    try std.testing.expect(!bus.pgxp_color_correction);
    try std.testing.expect(!bus.pgxpColorCorrection());
}

test "Phase4: colour correction is ANDed with the master flag" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    bus.setPgxpColorCorrection(true);
    // The sub-setting alone does nothing: there is no state in which it acts
    // while geometry correction does not.
    try std.testing.expect(!bus.pgxpColorCorrection());
    try std.testing.expect(!bus.gpu.gp0.pgxp_color_correction);
    bus.setPgxp(true);
    try std.testing.expect(bus.pgxpColorCorrection());
    try std.testing.expect(bus.gpu.gp0.pgxp_color_correction);
    bus.setPgxpColorCorrection(false);
    try std.testing.expect(!bus.gpu.gp0.pgxp_color_correction);
    bus.setPgxpColorCorrection(true);
    bus.setPgxp(false);
    try std.testing.expect(!bus.gpu.gp0.pgxp_color_correction);
}
```

Append to `ps1-capi/src/capi_test.zig`:

```zig
test "colour correction crosses the ABI and defaults off" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // OFF is the shipped default, matching the reference — it is the one
    // correction with a per-game disable list there.
    try std.testing.expect(!h.cpu.bus.pgxp_color_correction);
    capi.ps1_set_pgxp_color_correction(h, 1);
    try std.testing.expect(h.cpu.bus.pgxp_color_correction);
    // Still inert without the master flag.
    try std.testing.expect(!h.cpu.bus.pgxpColorCorrection());
    capi.ps1_set_pgxp(h, 1);
    try std.testing.expect(h.cpu.bus.pgxpColorCorrection());
    try std.testing.expect(h.cpu.bus.gpu.gp0.pgxp_color_correction);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `no field named 'pgxp_color_correction'`.

- [ ] **Step 3: Add the flag and its accessors to `Bus`**

In `ps1-core/src/memory.zig`, immediately after `pgxp_texture_correction`:

```zig
    /// Perspective-correct vertex COLOUR, gated by `pgxp_enabled` above. OFF
    /// by default, and the default is the reference's own: colour correction
    /// is the one correction it carries a per-game disable list for, where
    /// texture and culling correction are the picture.
    ///
    /// A default-OFF flag must NOT be assigned in `Bus.init`, which is the
    /// exact inverse of the rule three fields above: the `@memset` there gives
    /// it `false`, which is correct, and an assignment would be noise.
    pgxp_color_correction: bool = false,
```

Beside `pgxpTextureCorrection`:

```zig
    /// Perspective-correct colour, with the master flag already folded in —
    /// the same shape as `pgxpTextureCorrection` and for the same reason.
    pub inline fn pgxpColorCorrection(self: *const Self) bool {
        return self.pgxp_enabled and self.pgxp_color_correction;
    }

    /// Set it and mirror it, for the same reason `setPgxpTextureCorrection`
    /// mirrors: `Gp0Engine` decides the record's bits and cannot reach `Bus`.
    pub fn setPgxpColorCorrection(self: *Self, enabled: bool) void {
        self.pgxp_color_correction = enabled;
        self.gpu.gp0.pgxp_color_correction = self.pgxpColorCorrection();
    }
```

and one line inside `setPgxp`, beside the texture-correction mirror:

```zig
        self.gpu.gp0.pgxp_color_correction = self.pgxpColorCorrection();
```

- [ ] **Step 4: Add the `Gp0Engine` mirror**

In `ps1-core/src/gpu/gp0.zig`, after `pgxp_texture_correction`:

```zig
    /// Mirrors `Bus.pgxpColorCorrection()` — the sub-setting with the master
    /// flag already ANDed in, for the same reason the four above are mirrored.
    /// Defaults FALSE both here and on `Bus`, unlike its texture sibling.
    pgxp_color_correction: bool = false,
```

- [ ] **Step 5: Add the C ABI setter**

In `ps1-capi/src/root.zig`, beside `ps1_set_pgxp_texture_correction`:

```zig
/// Perspective-correct vertex colour. OFF by default, gated on `ps1_set_pgxp`.
/// The bus method, not a raw field write, because it re-derives the
/// `Gp0Engine` mirror that decides the record's flag bits.
pub export fn ps1_set_pgxp_color_correction(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpColorCorrection(enabled != 0);
}
```

Add it to the `pgxp_was` snapshot/restore around `ps1_swap_disc` (`root.zig:122-143`) so a reset or disc change does not drop it: extend the anonymous struct with `color: bool` = `h.bus.pgxp_color_correction`, and restore it with `h.bus.pgxp_color_correction = pgxp_was.color;` **before** the closing `h.bus.setPgxp(pgxp_was.on)`, which is what re-derives every mirror.

**`pgxp_texture_correction` is missing from that snapshot today — verified, and it is a latent Phase 3 bug.** `Bus.init` restores it to its default of `true`, so a player who turned texture correction OFF has it silently turned back on by a reset or a disc swap. The macOS app masks this because `EmulatorRunner` re-applies every setting per frame, but the ABI's own contract is broken. Add both fields in this step and say so in the commit message. Pin it with a `capi_test.zig` case:

```zig
test "a reset keeps the player's correction settings" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_set_pgxp(h, 1);
    capi.ps1_set_pgxp_texture_correction(h, 0);
    capi.ps1_set_pgxp_color_correction(h, 1);
    capi.ps1_reset(h);
    // Renderer settings are the player's choice, not machine state: a reset
    // rebuilds Bus, and Bus.init puts every one of them back at its default.
    try std.testing.expect(!h.cpu.bus.pgxp_texture_correction);
    try std.testing.expect(h.cpu.bus.pgxp_color_correction);
}
```

Check the exported reset entry point's real name in `root.zig` before writing the call — use whichever of `ps1_reset` / `ps1_swap_disc` reaches the `pgxp_was` block.

In `ps1-capi/include/ps1.h`, beneath `ps1_set_pgxp_texture_correction`, and change the block's opening comment from "The five below" to "The six below":

```c
/* Perspective-correct vertex COLOUR. A PS1 interpolates a Gouraud gradient
 * linearly in screen space for the same reason it interpolates u/v that way,
 * and it is wrong on the same polygons: a lit floor running away from the
 * camera has its shading bunched toward the near edge and stretched across the
 * far one, and the whole gradient swims as the camera moves.
 * Non-zero = on; 0 is the DEFAULT, matching the reference, which carries a
 * per-game disable list for this correction and for no other. Only a GOURAUD
 * primitive can change: three equal colours reproduce the affine result
 * exactly, so every flat-shaded primitive is identical either way. */
void    ps1_set_pgxp_color_correction(Ps1*, int enabled);
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
zig fmt ps1-core/src ps1-capi/src
git add -A
git commit -m "feat(pgxp): pgxp_color_correction, default OFF

Inert: nothing reads it until the next commit. Default OFF is the reference's
own default and the reason it stays out of Bus.init — the @memset already
gives it false, which is the inverse of the default-ON rule beside it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DUCkCw9pmF4e3rv6Ct2LZ1"
```

---

### Task 3: `rw` on Gouraud triangles, and the colour bit

Record-only: no rasterizer reads the colour bit yet, so no pixel can move. This is the task that closes spec-review finding 1 — the textured gate widens to "texture OR colour" — and finding 2 — the flat-shaded sites never set the colour bit at all.

**Files:**
- Modify: `ps1-core/src/gpu/gp0.zig` — `PgxpStats` (`:28-80`), the depth helpers (`:445-461`), `drawShadedTriangle` (`:658-667`), `drawShadedQuad` (`:669-680`), and the four textured sites
- Test: `ps1-core/tests/gpu_stream_test.zig`, `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `command.flag_texture_perspective` / `flag_color_perspective` and `Sink.drawShadedTriangle(..., rw, flags)` from Task 1; `Gp0Engine.pgxp_color_correction` from Task 2.
- Produces: `Gp0Engine.PgxpStats.shaded_triangles: u64`, `.color_perspective_primitives: u64`; `Gp0Engine.shadedDepths([]const Primitive.Point) Depths`; `Gp0Engine.texturedDepths([]const Primitive.TexturedPoint, gouraud: bool) Depths`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_stream_test.zig` (it can see the recorder). The four-combination test is the one the flags byte exists for, so it is written first:

```zig
/// The defect the flags byte exists to prevent: with one bit, a triangle drawn
/// with colour correction on and texture correction off would have its
/// TEXCOORDS corrected by a setting the player turned off.
///
/// One Gouraud-textured triangle (GP0 0x34), four setting combinations, and
/// the pair of bits each must produce. Verified to FAIL against a single-bit
/// implementation before landing — see Step 2.
test "Phase4: the two correction bits are independent" {
    const cases = [_]struct { tex: bool, col: bool, want: u8 }{
        .{ .tex = false, .col = false, .want = 0 },
        .{ .tex = true, .col = false, .want = command.flag_texture_perspective },
        .{ .tex = false, .col = true, .want = command.flag_color_perspective },
        .{ .tex = true, .col = true, .want = command.flag_texture_perspective | command.flag_color_perspective },
    };
    for (cases) |c| {
        var case = try StreamCase.init(std.testing.allocator);
        defer case.deinit();
        case.gpu.gp0.pgxp_enabled = true;
        case.gpu.gp0.pgxp_texture_correction = c.tex;
        case.gpu.gp0.pgxp_color_correction = c.col;
        drawGouraudTexturedTriangle(&case);
        try std.testing.expectEqual(c.want, lastRecord(case.gpu, .draw_textured_triangle).flags);
        // The depths themselves must be present whenever EITHER setting wants
        // them: gating them on texture correction alone is what would make the
        // colour bit unusable on its own.
        const rec = lastRecord(case.gpu, .draw_textured_triangle);
        const want_rw = c.tex or c.col;
        try std.testing.expectEqual(want_rw, rec.v[0].rw != 0);
    }
}

/// An untextured Gouraud triangle carries depths only for the colour setting.
test "Phase4: an untextured Gouraud triangle records the colour bit alone" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_texture_correction = true;
    case.gpu.gp0.pgxp_color_correction = true;
    drawShadedTriangleWithDepth(&case);

    const rec = lastRecord(case.gpu, .draw_shaded_triangle);
    try std.testing.expectEqual(command.flag_color_perspective, rec.flags);
    try std.testing.expect(rec.v[0].rw != 0 and rec.v[1].rw != 0 and rec.v[2].rw != 0);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.shaded_triangles);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.color_perspective_primitives);
    // Untextured: it must not touch the textured population at all.
    try std.testing.expectEqual(@as(u64, 0), case.gpu.gp0.pgxp.textured_triangles);
}

/// The structural half of the flat-shaded carve-out. The arithmetic half is
/// pinned in gpu_test.zig; this one says gp0 never even offers the bit, so a
/// future change to `interpW` cannot reach a flat-shaded primitive by accident.
test "Phase4: a flat-shaded textured triangle never carries the colour bit" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_texture_correction = true;
    case.gpu.gp0.pgxp_color_correction = true;
    drawFlatTexturedTriangle(&case);

    const rec = lastRecord(case.gpu, .draw_textured_triangle);
    try std.testing.expectEqual(command.flag_texture_perspective, rec.flags);
    try std.testing.expectEqual(@as(u64, 0), case.gpu.gp0.pgxp.shaded_triangles);
}

/// `unify` snaps a partly-resolved primitive back to integers and clears `w`
/// with the position. The textured equivalents are pinned by Phase 3; these
/// are the SHADED ones, which had no depth to lose until this task.
test "Phase4: unify clears the depth on a mixed shaded primitive" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_color_correction = true;
    drawShadedTriangleWithDepth2Of3(&case);   // vertex 2 unresolved

    const rec = lastRecord(case.gpu, .draw_shaded_triangle);
    try std.testing.expectEqual(@as(u8, 0), rec.flags);
    try std.testing.expectEqual(@as(i32, 0), rec.v[0].rw);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.mixed_primitives);
}

test "Phase4: a thin shaded primitive keeps no depth either" {
    var case = try StreamCase.init(std.testing.allocator);
    defer case.deinit();
    case.gpu.gp0.pgxp_enabled = true;
    case.gpu.gp0.pgxp_color_correction = true;
    drawThinShadedTriangleWithDepth(&case);

    const rec = lastRecord(case.gpu, .draw_shaded_triangle);
    try std.testing.expectEqual(@as(u8, 0), rec.flags);
    try std.testing.expectEqual(@as(u64, 1), case.gpu.gp0.pgxp.thin_primitives);
}
```

The five `draw*` helpers write the GP0 words for one primitive each. Model them on `gpu_test.zig:1994`'s existing sequence and on `pgxp_test.zig`'s mixed/thin cases — a Gouraud triangle is GP0 `0x30` with words `colour, xy, colour, xy, colour, xy`, and a Gouraud-textured triangle is `0x34` with `colour, xy, uv+clut, colour, xy, uv, colour, xy, uv`. Each vertex word carries its `pgxp.Value` via the second argument to `writeGp0`, built with `subPixelDepth(word, fx, fy, z)`; use depths `4.0`, `1.0`, `16.0` so the ratio is wide enough that no `rw` rounds to the same value. For the mixed case pass `Value.none` for the third vertex; for the thin case place the three vertices within 1 px of a line, as `pgxp_test.zig`'s thin-primitive test does. Write the helpers next to the tests, one per test, with a doc comment naming what makes each primitive the case it is.

Append to `ps1-core/tests/gpu_test.zig`:

```zig
test "Phase4: the shaded population counts Gouraud-textured triangles too" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    gpu.gp0.pgxp_enabled = true;
    gpu.gp0.pgxp_color_correction = true;
    // A Gouraud-TEXTURED triangle is in both populations: its texcoords and
    // its modulation colour are corrected by two different settings, so it is
    // the denominator of both rates.
    drawGouraudTexturedTriangleAt(&gpu, 4.0, 1.0, 16.0);
    try expectEqual(@as(u64, 1), gpu.gp0.pgxp.shaded_triangles);
    try expectEqual(@as(u64, 1), gpu.gp0.pgxp.textured_triangles);
}
```

- [ ] **Step 2: Run the tests to verify they fail, and verify the key one fails for the RIGHT reason**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — `no field named 'shaded_triangles'`.

Then, once Step 3 is written, temporarily make `texturedDepths` set both bits from `pgxp_texture_correction` alone (the single-bit implementation) and re-run just that test:

Run: `zig build test 2>&1 | grep -A5 "two correction bits are independent"`
Expected: FAIL on the `.tex = false, .col = true` case. **Revert the mutation.** A four-combination test that passes against a single-bit implementation is testing nothing.

- [ ] **Step 3: Add the two counters**

In `Gp0Engine.PgxpStats`, after `textured_triangles`:

```zig
        /// Triangles whose vertex COLOUR was interpolated through the depths —
        /// all three vertices carrying one, with the setting on. The colour
        /// sibling of `perspective_primitives`.
        color_perspective_primitives: u64 = 0,
        /// Every triangle drawn whose three colours can differ: the untextured
        /// Gouraud opcodes and the Gouraud-TEXTURED ones. The denominator the
        /// count above is read against, and deliberately not "every triangle" —
        /// a flat-shaded primitive reproduces its colour exactly whatever the
        /// setting says, so counting it would dilute the rate with triangles
        /// the setting cannot move.
        shaded_triangles: u64 = 0,
```

(`perspective_primitives` and `textured_triangles` already exist from Phase 3 and do not move.)

- [ ] **Step 4: Split the depth helper in two**

Replace Task 1's `reciprocalDepths` in `gp0.zig` with the shared core plus two entry points:

```zig
    /// The quantisation and the flag bits, decided together: a bit is a
    /// function of the settings AND of whether a depth survived, so computing
    /// them apart is how they drift.
    ///
    /// Decided HERE, on the way to the sink, for the same reason `unify` and
    /// `weldPoint` are: the record a Metal replay consumes must already be
    /// normalised, so the two rasterizers cannot disagree about it. A quad's
    /// two halves call this separately and normalise independently, which is
    /// safe because the normalisation constant cancels — see
    /// `Primitive.reciprocalDepths`.
    fn depthsFor(self: *Gp0Engine, w: [3]f32, want_texture: bool, want_color: bool) Depths {
        if (!want_texture and !want_color) return .{};
        const rw = Primitive.reciprocalDepths(w);
        if (rw[0] == 0) return .{};
        var out: Depths = .{ .rw = rw };
        if (want_texture) {
            out.flags |= command.flag_texture_perspective;
            self.pgxp.perspective_primitives += 1;
        }
        if (want_color) {
            out.flags |= command.flag_color_perspective;
            self.pgxp.color_perspective_primitives += 1;
        }
        return out;
    }

    /// One untextured Gouraud triangle's depths. The colour bit is the only
    /// one it can carry: there are no texcoords to correct.
    fn shadedDepths(self: *Gp0Engine, pts: []const Primitive.Point) Depths {
        self.pgxp.shaded_triangles += 1;
        return self.depthsFor(
            .{ pts[0].w, pts[1].w, pts[2].w },
            false,
            self.pgxp_color_correction,
        );
    }

    /// One textured triangle's. `gouraud` says whether its three modulation
    /// colours can differ — a flat-shaded primitive repeats one colour three
    /// times, and `interpW` reproduces that exactly, so a colour bit there
    /// would be a bit that cannot change a pixel. Refusing it structurally as
    /// well as arithmetically is the second lock on that door.
    ///
    /// The depths themselves are produced whenever EITHER setting wants them:
    /// gating on texture correction alone would leave colour correction
    /// unusable on its own, since the colour branch also requires `rw != 0`.
    fn texturedDepths(self: *Gp0Engine, vs: []const Primitive.TexturedPoint, gouraud: bool) Depths {
        self.pgxp.textured_triangles += 1;
        if (gouraud) self.pgxp.shaded_triangles += 1;
        return self.depthsFor(
            .{ vs[0].point.w, vs[1].point.w, vs[2].point.w },
            self.pgxp_texture_correction,
            gouraud and self.pgxp_color_correction,
        );
    }
```

- [ ] **Step 5: Point every call site at the right entry**

`gp0.zig:694` and `:706`/`:707` (flat-shaded textured triangle and quad) become `self.texturedDepths(vs[0..3], false)` / `self.texturedDepths(vs[1..4], false)`.

`gp0.zig:725` and `:742`/`:743` (Gouraud-textured triangle and quad) become `self.texturedDepths(vs[0..3], true)` / `self.texturedDepths(vs[1..4], true)`.

`drawShadedTriangle` (`:658`) and `drawShadedQuad` (`:669`) compute theirs after `unify`:

```zig
    fn drawShadedTriangle(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        var pts = [3]Primitive.Point{ self.point(1), self.point(3), self.point(5) };
        self.unify(&pts);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[2] & 0xFFFFFF;
        const c2 = self.cmd_buffer[4] & 0xFFFFFF;
        const d = self.shadedDepths(pts[0..3]);

        sink.drawShadedTriangle(vram, draw_env, pts[0], c0, pts[1], c1, pts[2], c2, is_transp, d.rw, d.flags);
    }
```

and, in `drawShadedQuad`, **two separate `const d0` / `const d1`** for the two halves — they normalise independently, and sharing one would pin the second half to the first's nearest vertex:

```zig
        const d0 = self.shadedDepths(pts[0..3]);
        const d1 = self.shadedDepths(pts[1..4]);
        sink.drawShadedTriangle(vram, draw_env, pts[0], c0, pts[1], c1, pts[2], c2, is_transp, d0.rw, d0.flags);
        sink.drawShadedTriangle(vram, draw_env, pts[1], c1, pts[2], c2, pts[3], c3, is_transp, d1.rw, d1.flags);
```

`unify` has already run on all four points at this stage, which is what makes each half's depths all-or-nothing.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS. Then run the Step 2 mutation check on the four-combination test and confirm it fails; revert.

- [ ] **Step 7: Confirm nothing moved**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
```

Expected: unchanged. With PGXP off nothing resolves, so `depthsFor` returns `.{}` on every primitive in every workload.

- [ ] **Step 8: Commit**

```bash
zig fmt ps1-core/src
git add -A
git commit -m "feat(pgxp): Gouraud triangles carry depths, and gp0 decides both bits

The textured gate widens from 'texture correction' to 'texture OR colour': a
triangle drawn with colour correction alone still needs a non-zero rw, because
the colour branch requires it too. The flat-shaded textured sites pass
gouraud=false and so never carry the colour bit — the carve-out made
structural as well as arithmetic.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DUCkCw9pmF4e3rv6Ct2LZ1"
```

---

### Task 4: The colour branch in the software rasterizer

The first task that can move a pixel — and only with PGXP on, colour correction on, and a Gouraud primitive whose three vertices all carry a depth.

**Files:**
- Modify: `ps1-core/src/gpu/renderer.zig:164-180` (add `interpAttr` beneath `interpW`), `:357-389` (`ShadedShader`), `:527-596` (`TexturedShader`)
- Modify: `ps1-core/src/gpu/primitive.zig:250-262` (the `rw_one` bound's wording)
- Test: `ps1-core/tests/gpu_test.zig`

**Interfaces:**
- Consumes: `Renderer.drawShadedTriangle(..., rw: [3]i32, perspective_color: bool)` and `drawTexturedTriangle(..., rw, perspective_texture, perspective_color)` from Task 1.
- Produces: `Renderer.interpAttr(perspective: bool, w0, w1, w2: i32, area: i32, a0, a1, a2: i32, rw0, rw1, rw2: i32) i32`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/gpu_test.zig`. The worked arithmetic is restated in the comment so the test checks the FORMULA rather than checking the implementation against itself:

```zig
// --- Phase 4 Task 4: perspective-correct colour.

/// The same triangle the Phase 3 texcoord tests use — (0,0) (64,0) (0,64) —
/// with red carrying the ramp instead of `u`. Wire colours are 24-bit BGR, so
/// red is the low byte: vertex 1 is 240, the other two are 0.
///
///   q-space vertices (0,0) (1024,0) (0,1024); twice-area 1048576
///   at pixel (32,16): w = (262144, 524288, 262144), i.e. 1/4, 1/2, 1/4
///   r = (0, 240, 0)                    -> affine 120, packed 120 >> 3 == 15
///   W = (1, 4, 1) -> rw = (65536, 16384, 65536)
///   t   = (17179869184, 8589934592, 17179869184), den = 42949672960
///   num = 8589934592 * 240 = 2061584302080 = den * 48 exactly
///                                      -> perspective 48, packed 48 >> 3 == 6
///
/// `setupGpu` never writes GP0(E1), so dithering is off and the packed value
/// is the interpolant's own five bits.
fn drawShadedRampTriangle(gpu: *Gpu, rw: [3]i32, perspective: bool) void {
    Renderer.drawShadedTriangle(
        &gpu.vram,
        &gpu.draw_env,
        pt(0, 0),
        0x000000,
        pt(64, 0),
        0x0000F0,
        pt(0, 64),
        0x000000,
        false,
        rw,
        perspective,
    );
}

test "Phase4: a Gouraud triangle shades the hand-computed perspective value" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    _ = gpu.step(1000); // drain setupGpu's GP0 FIFO before drawing directly
    drawShadedRampTriangle(&gpu, .{ 65536, 16384, 65536 }, true);
    try expectEqual(@as(u16, 6), gpu.vram.data[16 * 1024 + 32]);
}

test "Phase4: the colour bit clear leaves the shading affine" {
    var gpu = Gpu.init();
    setupGpu(&gpu);
    _ = gpu.step(1000);
    drawShadedRampTriangle(&gpu, .{ 65536, 16384, 65536 }, false);
    try expectEqual(@as(u16, 15), gpu.vram.data[16 * 1024 + 32]);
}

// The test that fails if the `rw != 0` guard is dropped: with the bit set and
// no depths, `interpW`'s denominator is zero. Affine output here is the
// assertion; not dividing by zero is the reason it exists.
test "Phase4: the colour bit with no depths takes the affine path" {
    for ([_][3]i32{
        .{ 0, 0, 0 },
        .{ 0, 16384, 65536 },
        .{ 65536, 0, 65536 },
        .{ 65536, 16384, 0 },
    }) |rw| {
        var gpu = Gpu.init();
        setupGpu(&gpu);
        _ = gpu.step(1000);
        drawShadedRampTriangle(&gpu, rw, true);
        try expectEqual(@as(u16, 15), gpu.vram.data[16 * 1024 + 32]);
    }
}

// The flat-shaded carve-out, asserted rather than reasoned about: with three
// equal colours `interpW` returns exactly that colour, because
// num = c*(t0+t1+t2) and den = t0+t1+t2. Over a spread of depth ratios and
// over the WHOLE triangle, not one pixel — a rounding-shaped bug would show up
// at the edges long before it showed up at the centre.
test "Phase4: three equal colours reproduce the affine result exactly" {
    for ([_][3]i32{
        .{ 65536, 16384, 65536 },
        .{ 65536, 1, 65536 },
        .{ 1, 65536, 4096 },
        .{ 30011, 65536, 7 },
    }) |rw| {
        var affine = Gpu.init();
        setupGpu(&affine);
        _ = affine.step(1000);
        var persp = Gpu.init();
        setupGpu(&persp);
        _ = persp.step(1000);
        for ([_]*Gpu{ &affine, &persp }, [_]bool{ false, true }) |gpu, on| {
            Renderer.drawShadedTriangle(
                &gpu.vram, &gpu.draw_env,
                pt(0, 0), 0x3070F0,
                pt(64, 0), 0x3070F0,
                pt(0, 64), 0x3070F0,
                false, rw, on,
            );
        }
        try std.testing.expectEqualSlices(u16, affine.vram.data[0 .. 66 * 1024], persp.vram.data[0 .. 66 * 1024]);
    }
}

// The same carve-out for the textured path's modulation colour, which is where
// most of a real frame lives: gp0 passes `color, color, color` at every
// flat-shaded textured opcode.
test "Phase4: an equal modulation colour reproduces the affine texel exactly" {
    var affine = Gpu.init();
    setupGpu(&affine);
    _ = affine.step(1000);
    seedRampTexture(&affine);
    var persp = Gpu.init();
    setupGpu(&persp);
    _ = persp.step(1000);
    seedRampTexture(&persp);
    for ([_]*Gpu{ &affine, &persp }, [_]bool{ false, true }) |gpu, on| {
        Renderer.drawTexturedTriangle(
            &gpu.vram, &gpu.draw_env,
            tpt(0, 0, 0, 0), tpt(64, 0, 240, 0), tpt(0, 64, 0, 0),
            0x808080, 0x808080, 0x808080,
            0, ramp_tpage, false, 0x24, // 0x24: modulated, not raw
            .{ 65536, 16384, 65536 }, true, on,
        );
    }
    try std.testing.expectEqualSlices(u16, affine.vram.data[0 .. 66 * 1024], persp.vram.data[0 .. 66 * 1024]);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -30`
Expected: the first test FAILS with `expected 6, found 15` — the perspective branch does not exist yet. The affine tests pass already, which is correct: they are regression locks, not new behaviour.

- [ ] **Step 3: Add `interpAttr`**

In `renderer.zig`, directly beneath `interpW`:

```zig
    /// Select the interpolant for one attribute. Both rasterizers spell this
    /// the same way, scalar parameters and all, so the two are comparable by
    /// eye at every call site — see `ps1_interp_attr` in `Ps1Color.h`.
    ///
    /// `perspective` is the record's flag ANDed with "all three depths
    /// present" by the caller, once per primitive. Never a per-pixel decision
    /// about geometry: `unify` forces a primitive all-resolved or
    /// none-resolved before the sink ever sees it.
    fn interpAttr(
        perspective: bool,
        w0: i32,
        w1: i32,
        w2: i32,
        area: i32,
        a0: i32,
        a1: i32,
        a2: i32,
        rw0: i32,
        rw1: i32,
        rw2: i32,
    ) i32 {
        return if (perspective)
            interpW(w0, w1, w2, a0, a1, a2, rw0, rw1, rw2)
        else
            interp(w0, w1, w2, area, a0, a1, a2);
    }
```

- [ ] **Step 4: Use it in `ShadedShader`**

Replace `drawShadedTriangle`'s body. The shader context gains two fields and the three channels go through `interpAttr`:

```zig
        const ShadedShader = struct {
            r: [3]i32,
            g: [3]i32,
            b: [3]i32,
            rw: [3]i32,
            perspective: bool,
            dither_enabled: bool,
            pub fn shade(ctx: @This(), w0: i32, w1: i32, w2: i32, area: i32, px: i16, py: i16, is_transp: bool) ShadeResult {
                var r = interpAttr(ctx.perspective, w0, w1, w2, area, ctx.r[0], ctx.r[1], ctx.r[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);
                var g = interpAttr(ctx.perspective, w0, w1, w2, area, ctx.g[0], ctx.g[1], ctx.g[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);
                var b = interpAttr(ctx.perspective, w0, w1, w2, area, ctx.b[0], ctx.b[1], ctx.b[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);

                if (ctx.dither_enabled) {
                    const offset: i32 = Color.dither_table[@intCast(@mod(py, 4))][@intCast(@mod(px, 4))];
                    r += offset;
                    g += offset;
                    b += offset;
                }

                // Dither is an 8-bit-scale offset, so it is added before the
                // shift to 5 bits, and the clamp is at 8-bit range. That
                // ordering is also why the interpolant's inputs stay unsigned:
                // nothing subtracts from a channel before it is interpolated.
                const r5: u16 = @intCast(std.math.clamp(r, 0, 255) >> 3);
                const g5: u16 = @intCast(std.math.clamp(g, 0, 255) >> 3);
                const b5: u16 = @intCast(std.math.clamp(b, 0, 255) >> 3);

                return .{ .color = (b5 << 10) | (g5 << 5) | r5, .is_transparent = is_transp, .draw = true };
            }
        };
        rasterizeTriangle(vram, env, p0, p1, p2, is_transparent, ShadedShader, ShadedShader{
            .r = .{ @intCast(c0 & 0xFF), @intCast(c1 & 0xFF), @intCast(c2 & 0xFF) },
            .g = .{ @intCast((c0 >> 8) & 0xFF), @intCast((c1 >> 8) & 0xFF), @intCast((c2 >> 8) & 0xFF) },
            .b = .{ @intCast((c0 >> 16) & 0xFF), @intCast((c1 >> 16) & 0xFF), @intCast((c2 >> 16) & 0xFF) },
            .rw = rw,
            .perspective = perspective_color and rw[0] != 0 and rw[1] != 0 and rw[2] != 0,
            .dither_enabled = (env.draw_mode & (1 << 9)) != 0,
        });
```

Delete the `_ = rw; _ = perspective_color;` placeholders from Task 1.

- [ ] **Step 5: Use it in `TexturedShader`**

Rename the existing `perspective` field to `perspective_texture`, add `perspective_color: bool`, and put all five attributes through `interpAttr`:

```zig
                const iu = interpAttr(ctx.perspective_texture, w0, w1, w2, area, ctx.tu[0], ctx.tu[1], ctx.tu[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);
                const iv = interpAttr(ctx.perspective_texture, w0, w1, w2, area, ctx.tv[0], ctx.tv[1], ctx.tv[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]);
```

and in the modulation block:

```zig
                if ((ctx.opcode & 1) == 0) { // Modulation
                    // The three colours are equal on a flat-shaded primitive,
                    // and both interpolants reproduce an equal triple exactly —
                    // `interp` because w0+w1+w2 == area, `interpW` because the
                    // weighted sum factors out — so a flat-shaded textured
                    // polygon is bit-identical whether colour correction is on
                    // or off. `gp0` refuses it the bit as well.
                    const cr: u16 = @intCast(interpAttr(ctx.perspective_color, w0, w1, w2, area, ctx.cr[0], ctx.cr[1], ctx.cr[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]) >> 3);
                    const cg: u16 = @intCast(interpAttr(ctx.perspective_color, w0, w1, w2, area, ctx.cg[0], ctx.cg[1], ctx.cg[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]) >> 3);
                    const cb: u16 = @intCast(interpAttr(ctx.perspective_color, w0, w1, w2, area, ctx.cb[0], ctx.cb[1], ctx.cb[2], ctx.rw[0], ctx.rw[1], ctx.rw[2]) >> 3);
```

with the context built as:

```zig
            .perspective_texture = perspective_texture and rw[0] != 0 and rw[1] != 0 and rw[2] != 0,
            .perspective_color = perspective_color and rw[0] != 0 and rw[1] != 0 and rw[2] != 0,
```

- [ ] **Step 6: Widen the overflow bound's wording**

In `ps1-core/src/gpu/primitive.zig`, in `rw_one`'s doc comment, change "and a texcoord is an 8-bit wire field" to:

```zig
/// or 512 vertically is DROPPED, so in the box-relative 1/16-px space both
/// rasterizers work in every barycentric weight is under 2^29 (see
/// `renderer.zig`'s `toQ`), and every attribute this interpolates — a texcoord
/// and, since Phase 4, a colour channel — is an 8-bit wire field:
```

No constant moves: a colour channel has the same range as a texcoord, so the derivation below it holds verbatim.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 8: Verify the carve-out test can fail**

Temporarily change `interpW`'s divisor from `t0 + t1 + t2` to `t0 + t1`, then:

Run: `zig build test 2>&1 | grep -A5 "three equal colours"`
Expected: FAIL. With an equal triple the numerator is `c·(t0+t1+t2)`, so a wrong denominator no longer cancels. **Revert the mutation** and re-run to confirm green.

- [ ] **Step 9: Confirm nothing moved**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
```

Expected: unchanged.

- [ ] **Step 10: Commit**

```bash
zig fmt ps1-core/src
git add -A
git commit -m "feat(pgxp): perspective-correct colour in the software rasterizer

interpAttr selects between interp and interpW for one attribute, spelled the
same way at all five call sites so the Metal mirror is comparable by eye. Three
equal colours reproduce the affine result exactly — pinned over four depth
ratios and the whole triangle, and verified to fail against a wrong denominator.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DUCkCw9pmF4e3rv6Ct2LZ1"
```

---

### Task 5: The same expression in Metal

**Files:**
- Modify: `ps1-macos/Shaders/Ps1Color.h:255-280` (the `ps1_interp_w` comment), and add `ps1_interp_attr` beneath it
- Modify: `ps1-macos/Shaders/Rasterizer.metal:335-346` (`PS1_PRIM_GOURAUD_TRI`), `:347-395` (`PS1_PRIM_TEXTURED_TRI`)
- Test: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`

**Interfaces:**
- Consumes: `PS1_PRIM_TEXTURE_PERSPECTIVE` / `PS1_PRIM_COLOR_PERSPECTIVE` and `PrimBuilder`'s translation from Task 1; the software answers from Task 4.
- Produces: `ps1_interp_attr(bool perspective, int w0, int w1, int w2, int area, int a0, int a1, int a2, int rw0, int rw1, int rw2)`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`:

```swift
/// The Gouraud counterpart of `rampTriangle`: the same (0,0) (64,0) (0,64)
/// triangle with red carrying the ramp. Red is the low byte of the 24-bit BGR
/// wire colour, so vertex 1 is 0x0000F0 and the other two are 0.
private func shadedRampTriangle(_ rw: (Int32, Int32, Int32),
                                colorPerspective: Bool) -> (MetalRasterizer) -> Void {
    return { r in
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)

        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
        if colorPerspective { tri.flags = UInt8(PS1_GPU_FLAG_COLOR_PERSPECTIVE) }
        tri.v.0 = Ps1GpuVertex(x: 0, y: 0, color: 0x000000)
        tri.v.1 = Ps1GpuVertex(x: 64, y: 0, color: 0x0000F0)
        tri.v.2 = Ps1GpuVertex(x: 0, y: 64, color: 0x000000)
        tri.v.0.rw = rw.0
        tri.v.1.rw = rw.1
        tri.v.2.rw = rw.2
        r.apply(tri)
    }
}

/// The same arithmetic `gpu_test.zig`'s "hand-computed perspective value" test
/// pins, read back from Metal: the two rasterizers evaluate one expression over
/// identical integers, so this is an equality with a number worked on paper
/// rather than a comparison against our own other implementation.
@Test func aGouraudTriangleShadesTheHandComputedPerspectiveValueInMetal() throws {
    guard let persp = try MetalScaleHarness.frame(scale: 1,
                                                  shadedRampTriangle((65536, 16384, 65536), colorPerspective: true)),
          let affine = try MetalScaleHarness.frame(scale: 1,
                                                   shadedRampTriangle((65536, 16384, 65536), colorPerspective: false))
    else { return }
    #expect(persp.native[16 * 1024 + 32] == 6)
    #expect(affine.native[16 * 1024 + 32] == 15)
}

/// The scaled path's own gate, the Gouraud copy of
/// `perspectiveCorrectionReachesTheInteriorOfABlockAtEightX`.
///
/// `readbackNative()` is the top-left subtexel of each block, where the sample
/// point IS the native pixel, so anything decided from px/py reproduces its 1x
/// answer there by construction and both existing gates pass whatever the other
/// s*s - 1 subtexels do. A correction applied only at the lattice would be
/// invisible to every gate this project has.
@Test func colourCorrectionReachesTheInteriorOfABlockAtEightX() throws {
    let scale = 8
    guard let affine = try MetalScaleHarness.frame(scale: scale,
                                                   shadedRampTriangle((65536, 16384, 65536), colorPerspective: false)),
          let persp = try MetalScaleHarness.frame(scale: scale,
                                                  shadedRampTriangle((65536, 16384, 65536), colorPerspective: true))
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
```

If `Ps1GpuVertex`'s memberwise initialiser in this test target requires every field, follow whatever form `rampTriangle` (`MetalScaleTests.swift:1202-1206`) uses and set `color` and `rw` by assignment afterwards.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
pkill -x Substation
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: FAIL — `6 != 15` on the first test (Metal is still affine), and `offLattice > 0` unsatisfied on the second.

- [ ] **Step 3: Correct the `ps1_interp_w` comment and add the selector**

In `ps1-macos/Shaders/Ps1Color.h`, replace the stale sentence in `ps1_interp_w`'s comment:

```c
/// `num >= 0` is likewise guaranteed: every w_i >= 0 (coverage), every rw_i >= 1
/// (CPU clamped), and every a_i in [0, 255] — an 8-bit texcoord, or since
/// Phase 4 an 8-bit colour channel. Plain `/` rather than a floor because
/// truncating division agrees exactly with renderer.zig's `@divFloor`, which is
/// what keeps the two rasterizers bit-identical. Phase 4 does NOT introduce a
/// signed attribute: a colour arrives unsigned on the wire and the dither
/// offset is added after interpolation, so the guarantee is unchanged.
```

and beneath it:

```c
/* Select the interpolant for one attribute. Spelled the same way as
 * renderer.zig's `interpAttr`, scalar parameters and all, so the two are
 * comparable by eye at every call site.
 *
 * `perspective` is the instance's flag ANDed with "all three depths present"
 * by the caller, once per primitive — never a per-fragment decision about
 * geometry: `unify` forces a primitive all-resolved or none-resolved before
 * the sink ever sees it. */
inline int ps1_interp_attr(bool perspective, int w0, int w1, int w2, int area,
                           int a0, int a1, int a2, int rw0, int rw1, int rw2) {
    return perspective ? ps1_interp_w(w0, w1, w2, a0, a1, a2, rw0, rw1, rw2)
                       : ps1_interp(w0, w1, w2, area, a0, a1, a2);
}
```

- [ ] **Step 4: Branch in `PS1_PRIM_GOURAUD_TRI`**

In `Rasterizer.metal`:

```c
    } else if (p.kind == PS1_PRIM_GOURAUD_TRI) {
        int w0, w1, w2, area;
        if (!ps1_triangle_coverage(p, s, px, py, w0, w1, w2, area)) { discard_fragment(); return ps1_discarded(); }
        // All three non-zero means every vertex carries a depth, which is a
        // property of the record; the flag says the player asked for this
        // attribute to use it. Both clauses, never one: with PGXP off no vertex
        // resolves, so the rw test alone keeps every output byte unchanged.
        bool color_persp = (p.flags & PS1_PRIM_COLOR_PERSPECTIVE) != 0
            && p.rw0 != 0 && p.rw1 != 0 && p.rw2 != 0;
        // Wire colours are 24-bit BGR: red in the low byte.
        int r = ps1_interp_attr(color_persp, w0, w1, w2, area,
                                int(p.c0 & 0xFFu), int(p.c1 & 0xFFu), int(p.c2 & 0xFFu),
                                p.rw0, p.rw1, p.rw2);
        int g = ps1_interp_attr(color_persp, w0, w1, w2, area,
                                int((p.c0 >> 8) & 0xFFu), int((p.c1 >> 8) & 0xFFu), int((p.c2 >> 8) & 0xFFu),
                                p.rw0, p.rw1, p.rw2);
        int b = ps1_interp_attr(color_persp, w0, w1, w2, area,
                                int((p.c0 >> 16) & 0xFFu), int((p.c1 >> 16) & 0xFFu), int((p.c2 >> 16) & 0xFFu),
                                p.rw0, p.rw1, p.rw2);
        src = ps1_pack(r + dither_o, g + dither_o, b + dither_o);
        src8 = true_colour ? ps1_pack8(r, g, b) : ps1_expand(src);
```

The `src8` line is unchanged and must stay unchanged: the sidecar takes whatever the interpolant produced, at eight bits, exactly as before.

- [ ] **Step 5: Branch in `PS1_PRIM_TEXTURED_TRI`**

Rename the existing `perspective` local to `tex_persp`, add `color_persp` beside it, and route all five attributes through the selector:

```c
        bool tex_persp = (p.flags & PS1_PRIM_TEXTURE_PERSPECTIVE) != 0
            && p.rw0 != 0 && p.rw1 != 0 && p.rw2 != 0;
        bool color_persp = (p.flags & PS1_PRIM_COLOR_PERSPECTIVE) != 0
            && p.rw0 != 0 && p.rw1 != 0 && p.rw2 != 0;
        int iu = ps1_interp_attr(tex_persp, w0, w1, w2, area, p.u0, p.u1, p.u2, p.rw0, p.rw1, p.rw2);
        int iv = ps1_interp_attr(tex_persp, w0, w1, w2, area, p.v0, p.v1, p.v2, p.rw0, p.rw1, p.rw2);
```

and the three shade channels with `color_persp`, keeping the existing comment about interpolating at eight bits and handing on at both widths.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
pkill -x Substation
zig build metallib && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: PASS. If `Failing tests:` appears with zero `✘` lines, that is the known scale-8 process crash — re-run before believing it.

**Shader headers are metallib cache inputs.** If the build system does not already list `Ps1Color.h` and `PrimInstance.h` as dependencies of the `metallib` step, the old shader ships and every result taken from it is a lie. Check `build.zig`'s `metallib` step before trusting a green run; if the headers are missing from its inputs, add them and say so in the commit message.

- [ ] **Step 7: Confirm the 1x gates did not move**

```bash
zig build fixtures -Doptimize=ReleaseFast
pkill -x Substation; ps1-macos/test.sh
```

Expected: Gate 1 (fixture hashes at 1x) and Gate 2 (`readbackNative` at scale equals 1x) unchanged. Every fixture in the corpus except the PGXP one was captured with PGXP off, so every `flags` byte in them is zero.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(pgxp): perspective-correct colour in the Metal rasterizer

ps1_interp_attr mirrors renderer.zig's interpAttr, scalar parameters and all,
so the two are comparable by eye. Also corrects ps1_interp_w's comment: Phase 4
introduces no signed attribute — a colour arrives unsigned on the wire and the
dither offset is added after interpolation, so truncating division still agrees
exactly with @divFloor.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DUCkCw9pmF4e3rv6Ct2LZ1"
```

---

### Task 6: The PGXP-on capture starts exercising both interpolants

The parity fixture exists and is strict, but `--pgxp-on` is `bus.setPgxp(true)` and nothing else (`main.zig:810`), so with colour correction defaulting off that fixture would exercise none of this phase.

**Files:**
- Modify: `ps1-golden/src/main.zig:51-52` (the flag's help text), `:810`, `:972-980` (the fixture's doc comment)
- Test: `ps1-macos/Tests/PS1Tests/PgxpParityTests.swift`

**Interfaces:**
- Consumes: `Bus.setPgxpColorCorrection` from Task 2; the record's `flags` from Task 1.
- Produces: a regenerated `zig-out/fixtures/tr1-usa-v1-1-pgxp.p1fx` carrying both bits.

- [ ] **Step 1: Write the failing test**

Append to `ps1-macos/Tests/PS1Tests/PgxpParityTests.swift`:

```swift
/// The colour half of the same guard the test above applies to texcoords: a
/// fixture captured before `--pgxp-on` learned the sub-settings would pass the
/// strict-equality gate trivially, by taking the affine colour path Gate 1
/// already covers.
///
/// Counts GOURAUD triangles specifically — both the untextured opcode and the
/// Gouraud-textured one — because those are the only records that can carry the
/// colour bit at all.
@Test(.enabled(if: FileManager.default.fileExists(
                    atPath: FixtureFile.url(named: "tr1-usa-v1-1-pgxp").path)))
func thePgxpParityFixtureCarriesColourCorrectedTriangles() throws {
    let file = try FixtureFile(contentsOf: FixtureFile.url(named: "tr1-usa-v1-1-pgxp"))
    var corrected = 0
    withExtendedLifetime(file) {
        for i in 0..<file.frames.count {
            for cmd in file.records(for: i)
            where cmd.kind == UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
               || cmd.kind == UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue) {
                if cmd.flags & UInt8(PS1_GPU_FLAG_COLOR_PERSPECTIVE) != 0 { corrected += 1 }
            }
        }
    }
    #expect(corrected > 100,
            Comment(rawValue: "only \(corrected) colour-corrected triangles — did --pgxp-on enable the sub-settings?"))
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
zig build fixtures -Doptimize=ReleaseFast
pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -A5 ColourCorrected
```

Expected: FAIL with `only 0 colour-corrected triangles`.

If the run instead SKIPS (no `games/` directory, so no fixture), say so and stop: this task cannot be verified without the Tomb Raider rip, and a skipped gate must not be reported as a passing one.

- [ ] **Step 3: Make `--pgxp-on` mean every correction**

At `ps1-golden/src/main.zig:810`:

```zig
    bus.setPgxp(opts.pgxp_on);
    // Every correction sub-setting, not just the master flag. The fixture's
    // purpose is to prove the two rasterizers evaluate the shared integer
    // expressions identically, so it should maximise the corrected surface.
    // It is a TEST ARTIFACT and deliberately NOT the shipped configuration:
    // colour correction ships off.
    bus.setPgxpColorCorrection(opts.pgxp_on);
```

`pgxp_texture_correction` already defaults on, so it needs no line — but add one anyway if the reader would otherwise have to know that: an explicit `bus.setPgxpTextureCorrection(opts.pgxp_on)` costs nothing and says what the flag means.

Update the help text at `:51-52`:

```zig
    \\  --pgxp-on               (stream-capture) capture with PGXP and EVERY
    \\                          correction sub-setting enabled, into
    \\                          `<key>-pgxp.p1fx` rather than `<key>.p1fx`.
    \\                          NOT the shipped configuration — colour
    \\                          correction ships off; the fixture maximises the
    \\                          corrected surface because it is a parity gate.
```

and extend the doc comment at `:972-975` to say the same thing about the file it writes: the two captures of one workload are different command streams — one carries reciprocal depths and correction flags, the other does not — and a shared name would leave the PGXP-on gate comparing the affine capture.

- [ ] **Step 4: Regenerate and re-run**

```bash
zig build fixtures -Doptimize=ReleaseFast
pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -30
```

Expected: PASS, including `aPgxpOnCaptureReplaysBitExactlyInMetal` at strict equality with `framesChecked == 100`. A divergence here is a real disagreement between the two rasterizers on the colour interpolant — the gate doing its job. Report the frame and pixel it names rather than widening the comparison.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-golden/src
git add -A
git commit -m "test(pgxp): --pgxp-on enables every correction sub-setting

The parity fixture is a test artifact, not a picture of the defaults: its whole
purpose is per-fragment agreement between the two rasterizers, so it should
maximise the corrected surface. One capture with both interpolants live tests
strictly more than two captures with one each.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DUCkCw9pmF4e3rv6Ct2LZ1"
```

---

### Task 7: The sweep learns a second population

`trace-golden -- pgxp` gains `color_perspective_primitives` over `shaded_triangles`, reported and ratcheted the same way `perspective` is. A fourth ratchet line kind in one file, so all four parsers must know the other three's prefixes.

**Files:**
- Modify: `ps1-golden/src/pgxp_sweep.zig` — `Report` (`:15-62`), the parsers (`:75-175`), `report` (`:236-336`), the parser tests (`:338-439`)
- Modify: `ps1-golden/src/main.zig:204`, `:254`, `:537-538` (`runPgxp`), `:566-567` (the counter copy), `:571-600` (`Floors` → `pgxp_sweep.Ratchets`)
- Modify: `ps1-core/tests/goldens/pgxp/floors.txt`

**Interfaces:**
- Consumes: `Gp0Engine.PgxpStats.{shaded_triangles, color_perspective_primitives}` from Task 3; `Bus.setPgxpColorCorrection` from Task 2.
- Produces: `pgxp_sweep.ColorFloor`, `parseColorFloors`, `colorFloorFor`, `Report.colorPerspectiveRate()`, `pgxp_sweep.Ratchets` (with `Ratchets.none`), `report(key, r, ratchets) bool`.

- [ ] **Step 1: Write the failing tests**

Extend `ps1-golden/src/pgxp_sweep.zig`'s existing parser tests. The critical one is `"the three ratchet line kinds do not read each other's lines"` at `:416` — rename it to four and add the new kind:

```zig
test "the four ratchet line kinds do not read each other's lines" {
    const a = std.testing.allocator;
    const text =
        \\# a comment
        \\croc 99
        \\clamped croc 81466
        \\perspective croc 47200
        \\color croc 12300
        \\
    ;
    const floors = try parseFloors(a, text);
    defer a.free(floors);
    const ceilings = try parseClampCeilings(a, text);
    defer a.free(ceilings);
    const persp = try parsePerspectiveFloors(a, text);
    defer a.free(persp);
    const color = try parseColorFloors(a, text);
    defer a.free(color);

    // One line each, and each reading ITS line rather than a neighbour's — the
    // mistake a fourth kind makes easy is a parser that takes `color croc` for
    // a hit-rate line keyed `color`.
    try std.testing.expectEqual(@as(usize, 1), floors.len);
    try std.testing.expectEqualStrings("croc", floors[0].key);
    try std.testing.expectEqual(@as(usize, 1), ceilings.len);
    try std.testing.expectEqual(@as(u64, 81466), ceilings[0].count);
    try std.testing.expectEqual(@as(usize, 1), persp.len);
    try std.testing.expectEqual(@as(u64, 47200), persp[0].count);
    try std.testing.expectEqual(@as(usize, 1), color.len);
    try std.testing.expectEqualStrings("croc", color[0].key);
    try std.testing.expectEqual(@as(u64, 12300), color[0].count);
}

test "the colour floor gates, and a missing one does not" {
    const r: Report = .{
        .vertices = 100, .resolved = 100, .identity_fail = 0,
        .disp_sum = 0, .disp_max = 0,
        .shaded_triangles = 1000, .color_perspective_primitives = 400,
    };
    const ratchets: Ratchets = .{
        .color = &[_]ColorFloor{.{ .key = "k", .count = 500 }},
    };
    try std.testing.expect(report("k", r, ratchets));           // 400 < 500: FAIL
    try std.testing.expect(!report("k", r, .{}));               // no line: WARN, not fail
}
```

Fill in `Ratchets`' other fields as the existing `"the report's hard checks fire"` test at `:378` does — copy its `Report` literal so this one differs only in the fields under test.

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `parseColorFloors` and `shaded_triangles` do not exist.

- [ ] **Step 3: Add the counters to `Report`**

```zig
    /// Triangles whose vertex COLOUR was interpolated through the depths —
    /// all three vertices carrying one, with the setting on.
    color_perspective_primitives: u64 = 0,
    /// Every triangle drawn whose three colours can differ: the untextured
    /// Gouraud opcodes and the Gouraud-textured ones. The denominator the count
    /// above is read against — see `Gp0Engine.PgxpStats.shaded_triangles` for
    /// why a flat-shaded primitive is not in it.
    shaded_triangles: u64 = 0,
```

and beside `perspectiveRate`:

```zig
    /// What share of the triangles that COULD be colour-corrected were. Read
    /// exactly as `perspectiveRate` is, and not as the hit rate: `resolved`
    /// counts vertices that got a sub-pixel POSITION, this counts triangles
    /// that got all three DEPTHS.
    pub fn colorPerspectiveRate(self: Report) f64 {
        if (self.shaded_triangles == 0) return 0;
        return @as(f64, @floatFromInt(self.color_perspective_primitives)) * 100.0 /
            @as(f64, @floatFromInt(self.shaded_triangles));
    }
```

- [ ] **Step 4: Add the fourth parser and teach the other three to skip it**

```zig
/// The prefix that marks a `color_perspective_primitives` FLOOR line. A floor
/// for the same reason `perspective ` is one: more corrected triangles is the
/// improvement here, where more `clamped` is the regression.
const color_prefix = "color ";

pub const ColorFloor = struct {
    key: []const u8,
    count: u64,
};

/// Parses the SAME `floors.txt` a fourth time, for `color <key> <count>` lines.
/// Everything else is skipped, mirroring the other three parsers skipping
/// these — four kinds share this file, so each parser has to know the other
/// three's prefixes or it reads their key as its own.
pub fn parseColorFloors(a: std.mem.Allocator, text: []const u8) ![]ColorFloor {
    var out = std.ArrayList(ColorFloor).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, color_prefix)) continue;
        const rest = std.mem.trim(u8, line[color_prefix.len..], " \t");
        const sep = std.mem.indexOfAny(u8, rest, " \t") orelse return error.BadFloorLine;
        const value = std.mem.trim(u8, rest[sep..], " \t");
        try out.append(a, .{
            .key = rest[0..sep],
            .count = try std.fmt.parseInt(u64, value, 10),
        });
    }
    return out.toOwnedSlice(a);
}

pub fn colorFloorFor(floors: []const ColorFloor, key: []const u8) ?u64 {
    for (floors) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.count;
    }
    return null;
}
```

Note that this parser needs no skip list of its own: requiring `color ` already excludes the other three kinds, exactly as `parsePerspectiveFloors` requires `perspective `. The three OLDER parsers are the ones that must learn the new prefix, because two of them accept an unprefixed line.

**Exactly one existing parser needs a change: `parseFloors`.** It is the only unprefixed kind, so it is the only one that would read `color croc 12300` as a hit-rate line keyed `color`. Add

```zig
        if (std.mem.startsWith(u8, line, color_prefix)) continue;
```

beside its two existing skips. `parseClampCeilings` and `parsePerspectiveFloors` each REQUIRE their own prefix and already skip everything else, so they are correct as written — their doc comments say "skipped by the other two", which becomes "the other three".

`parseClampCeilings`, `parsePerspectiveFloors` and `parseColorFloors` are now three copies of one function differing only in a prefix and a field name, so **fold them**: one private

```zig
/// `<prefix><key> <count>` lines, for the three ratchets that are keyed counts.
/// Requiring the prefix is the whole skip rule: a line belonging to any other
/// kind fails it, including the unprefixed hit-rate lines.
fn parsePrefixedCounts(a: std.mem.Allocator, text: []const u8, prefix: []const u8) ![]KeyedCount
```

with `pub const KeyedCount = struct { key: []const u8, count: u64 };`, and make `ClampCeiling`/`PerspectiveFloor`/`ColorFloor` aliases of it (`pub const ColorFloor = KeyedCount;`) so no call site outside this file changes. `ClampCeiling`'s field is named `ceiling` rather than `count` today — renaming it to `count` touches only `ceilingFor` and one line of `report`, and is worth it to make the fold total; keep the *semantics* of ceiling-versus-floor where they belong, in `report`, which is the only place that decides whether a count failing high or low is the regression. `ceilingFor` / `perspectiveFloorFor` / `colorFloorFor` collapse the same way into one `countFor(floors: []const KeyedCount, key) ?u64`. `parseFloors` and `floorFor` stay separate: unprefixed, and an `f64`.

- [ ] **Step 5: Group the ratchets instead of adding a fifth positional slice**

Move `main.zig:571-582`'s `Floors`/`no_floors` into `pgxp_sweep.zig`:

```zig
/// The four ratchets `floors.txt` carries, read together because a workload's
/// numbers are read together. Grouped rather than passed as four slices: a
/// fifth positional `[]const T` of nearly identical type is a call waiting to
/// be made in the wrong order.
pub const Ratchets = struct {
    floors: []const Floor = &.{},
    clamp_ceilings: []const ClampCeiling = &.{},
    perspective: []const PerspectiveFloor = &.{},
    color: []const ColorFloor = &.{},
};
```

`report` becomes `pub fn report(key: []const u8, r: Report, ratchets: Ratchets) bool`, reading `ratchets.floors` etc. `main.zig:254` becomes `if (pgxp_sweep.report(wl.key, pr, ratchets)) failures += 1;`, `readFloors` returns `pgxp_sweep.Ratchets` and its failure path returns `.{}` (the defaults ARE the empty case, so `no_floors` disappears).

- [ ] **Step 6: Report the new population**

In `report`, directly after the `perspective` block, in the same shape:

```zig
    if (colorFloorFor(ratchets.color, key)) |cf| {
        const color_ok = r.color_perspective_primitives >= cf;
        if (!color_ok) failed = true;
        std.debug.print("  color             {s} of {s} shaded tris ({d:.1}%)   floor {s}  {s}\n", .{
            commas(&b3, r.color_perspective_primitives), commas(&b2, r.shaded_triangles),
            r.colorPerspectiveRate(),                    commas(&b4, cf),
            if (color_ok) "OK" else "BELOW FLOOR",
        });
    } else {
        std.debug.print("  color             {s} of {s} shaded tris ({d:.1}%)   no floor  WARN\n", .{
            commas(&b3, r.color_perspective_primitives), commas(&b2, r.shaded_triangles),
            r.colorPerspectiveRate(),
        });
    }
```

Extend `report`'s doc comment: it now describes five hard checks, and the fifth is a floor for the same reason the fourth is.

- [ ] **Step 7: Force the sub-settings on in `runPgxp`, and copy the counters**

At `main.zig:537-538`:

```zig
    bus.setPgxp(true);
    bus.pgxp_cpu = opts.pgxp_cpu;
    // The correction sub-settings are forced ON for the same reason the parity
    // fixture forces them: this measures PROPAGATION coverage, and a counter
    // reading zero because of a shipped default measures nothing. Colour
    // correction ships OFF; `floors.txt`'s header says so beside the numbers.
    bus.setPgxpTextureCorrection(true);
    bus.setPgxpColorCorrection(true);
```

and in the `Report` literal at `:566-567`:

```zig
        .color_perspective_primitives = p.color_perspective_primitives,
        .shaded_triangles = p.shaded_triangles,
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 9: Measure and pin the floors**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- pgxp 2>&1 | tee /tmp/pgxp-sweep.txt
```

Every workload will report `color ... no floor  WARN`. Take each `color_perspective_primitives` count, round DOWN to three significant figures (the rule the `perspective` block uses), and append to `ps1-core/tests/goldens/pgxp/floors.txt`:

```
# --- A fourth ratchet lives below: per-workload FLOORS on `color`. ---
#
# `color <key> <count>` — the number of triangles whose vertex COLOUR was
# interpolated through the depths. A FLOOR, like `perspective` above and for
# the same reason. Parsed by `parseColorFloors`, and skipped by the other three
# parsers on the `color ` prefix.
#
# The DENOMINATOR is `shaded_triangles`: the untextured Gouraud opcodes plus
# the Gouraud-TEXTURED ones. Not every triangle — a flat-shaded primitive
# reproduces its colour exactly whichever interpolant runs, so counting it
# would dilute the rate with triangles the setting cannot move.
#
# MEASURED WITH COLOUR CORRECTION FORCED ON, exactly as the hit rates above
# were measured with CPU MODE ON. Colour correction SHIPS OFF: it is the one
# correction the reference carries a per-game disable list for. A sweep is not
# a picture of the defaults.
#
# Measured <DATE>, the full unfiltered sweep closing PGXP Phase 4.
#
#   workload                    color   of shaded tris     rate
#   ...                       <fill from the sweep output>
#
# A zero floor gates nothing; keep a zero line as a record of the measurement,
# not as a ratchet — and say WHY it is zero, as the `perspective` block does for
# bios-only and mgs. A zero whose cause is not understood is a floor that can
# never fail sitting on top of a real bug.
color bios-only <n>
color crash-bandicoot-europe-edc <n>
color crash-bandicoot-warped <n>
color crash-bandicoot-2-cortex-strikes-back-europe-australia-en-fr-de-es-it-edc <n>
color resident-evil-usa <n>
color croc-legend-of-the-gobbos <n>
color silent-hill-usa <n>
color mgs <n>
color tr1-usa-v1-1 <n>
color spyro-the-dragon-usa <n>
```

The ten keys are the ones the other three ratchets already carry; take them verbatim from the blocks above them in the same file rather than retyping, and replace each `<n>` with the measured count rounded down to three significant figures.

**Do not pin a zero you cannot explain.** If a workload reports zero `color` where it reports a healthy `perspective` count, that is a finding, not a number to write down: the two populations differ only in whether the opcode is Gouraud, so a zero means either the workload draws no Gouraud geometry (check `shaded_triangles`) or the colour bit is not being set (a bug in Task 3). Chase it before pinning.

- [ ] **Step 10: Re-run the sweep green and commit**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- pgxp
```

Expected: every workload `OK` on all four ratchets, exit 0.

```bash
zig fmt ps1-golden/src
git add -A
git commit -m "test(pgxp): color_perspective_primitives, the fourth ratchet

Over shaded_triangles — the Gouraud opcodes, textured and not — because a
flat-shaded primitive reproduces its colour exactly whichever interpolant runs.
Measured with colour correction forced on; it ships off, and floors.txt says so.
The four ratchet parsers move behind one prefixed-count helper.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DUCkCw9pmF4e3rv6Ct2LZ1"
```

---

### Task 8: The setting reaches the player

**Files:**
- Modify: `ps1-macos/Sources/PS1/PgxpSetting.swift`
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift:146-157`
- Modify: `ps1-macos/Sources/PS1/EmulatorRunner.swift:65-77`, `:185-190`, `:408-415`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift:159`, `:195-201`, `:546-555`
- Modify: `ps1-macos/Sources/PS1App/VideoCommands.swift:47-63`
- Test: `ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift`

**Interfaces:**
- Consumes: `ps1_set_pgxp_color_correction` from Task 2.
- Produces: `PgxpSetting.colorCorrection: Bool` / `setColorCorrection(_:)`; `Ps1Core.setPgxpColorCorrection(_:)`; `EmulatorRunner.setPgxpColorCorrection(_:)`; `EmulatorViewModel.pgxpColorCorrection: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/PgxpSettingTests.swift`:

```swift
/// Colour correction ships OFF — the inverse of `textureCorrection` beside it,
/// and the inverse is the point. `bool(forKey:)` would give the right answer
/// here by accident; `object(forKey:)` is used anyway so the next default-ON
/// setting added beside it does not inherit a probe-free idiom.
@Test func colorCorrectionDefaultsOffForAFreshInstall() {
    let d = UserDefaults(suiteName: "pgxp.cc.fresh.\(UUID().uuidString)")!
    #expect(!PgxpSetting(key: "pgxpEnabled", defaults: d).colorCorrection)
}

@Test func colorCorrectionPersistsWhenTurnedOn() {
    let suite = "pgxp.cc.persist.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    var s = PgxpSetting(key: "pgxpEnabled", defaults: d)
    s.setColorCorrection(true)
    #expect(PgxpSetting(key: "pgxpEnabled", defaults: d).colorCorrection)
    s.setColorCorrection(false)
    #expect(!PgxpSetting(key: "pgxpEnabled", defaults: d).colorCorrection)
}
```

and extend `theSubSettingsKeepTheirOwnKeys` to cover all six, each set AWAY from its own default so a key collision shows up as a value that did not move:

```swift
        // after the existing s.set(true) / setCpu(false) / setVertexCache(true) /
        // setCulling(false), and before `let reloaded = ...`
        s.setTextureCorrection(false)
        s.setColorCorrection(true)

        // ...and beside the four existing #expect lines:
        #expect(reloaded.textureCorrection == false)
        #expect(reloaded.colorCorrection == true)
```

Fix the stale comment at `:32` while you are there: it says "The four sub-settings" and there are six after this task.

- [ ] **Step 2: Run to verify they fail**

```bash
pkill -x Substation; ps1-macos/test.sh 2>&1 | grep -A5 colorCorrection
```

Expected: FAIL — `value of type 'PgxpSetting' has no member 'colorCorrection'`.

- [ ] **Step 3: Add it to `PgxpSetting`**

```swift
    /// Perspective-correct vertex colour. Ships OFF, unlike `culling` and
    /// `textureCorrection`: it is the one correction the reference carries a
    /// per-game disable list for, and a feature with a per-game disable list in
    /// the reference is not a feature to default on.
    private(set) var colorCorrection: Bool
```

with `private var colorCorrectionKey: String { key + ".colorCorrection" }`, the `init` line

```swift
        self.colorCorrection =
            (defaults.object(forKey: key + ".colorCorrection") as? NSNumber)?.boolValue ?? false
```

and

```swift
    mutating func setColorCorrection(_ value: Bool) {
        colorCorrection = value
        defaults.set(value, forKey: colorCorrectionKey)
    }
```

Update the type's doc comment: "five sub-settings" becomes six, and the paragraph listing which default TRUE gains a sentence saying `colorCorrection` is the third that defaults false — and that it still probes with `object(forKey:)` for uniformity rather than necessity.

- [ ] **Step 4: Thread it to the core**

`Ps1Core.swift`, beside `setPgxpTextureCorrection` (and change "The five sub-settings" to six):

```swift
    func setPgxpColorCorrection(_ enabled: Bool) {
        ps1_set_pgxp_color_correction(handle, enabled ? 1 : 0)
    }
```

`EmulatorRunner.swift`: `private let pgxpColorCorrection = Atomic<Bool>(false)` beside its siblings; `func setPgxpColorCorrection(_ enabled: Bool) { pgxpColorCorrection.store(enabled, ordering: .releasing) }`; and one line in `runLoop` beside the other re-applied-every-frame setters:

```swift
            core.setPgxpColorCorrection(pgxpColorCorrection.load(ordering: .acquiring))
```

`EmulatorViewModel.swift`:

```swift
    public var pgxpColorCorrection: Bool {
        get { pgxpSetting.colorCorrection }
        set {
            pgxpSetting.setColorCorrection(newValue)
            runner?.setPgxpColorCorrection(newValue)
        }
    }
```

and, in the per-game re-application block (`:546-555`), `runner.setPgxpColorCorrection(pgxpSetting.colorCorrection)` — the runner is rebuilt with every disc while the settings outlive them all, so an omission here loses the player's choice on disc two. Update that block's "All six" comment to seven.

- [ ] **Step 5: Add the menu item**

`VideoCommands.swift`, inside the `Group` that is `.disabled(!model.pgxpEnabled)`, directly beneath the texture-correction toggle so the two corrections sit together:

```swift
                Toggle("PGXP Colour Correction", isOn: $model.pgxpColorCorrection)
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
zig build capi-lib
pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 7: Confirm it works in the real app**

```bash
zig build macos && open zig-out/Substation.app
```

Boot a disc with 3D Gouraud geometry (Croc or Spyro), turn on **PGXP Geometry Correction**, then toggle **PGXP Colour Correction** and confirm the shading gradient on a receding lit surface changes — and that the menu item is greyed while geometry correction is off. Report what you actually saw; if you cannot run the app, say so rather than implying the check passed.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(macos): PGXP Colour Correction in the Video menu, default off

The inverse of textureCorrection beside it: ships OFF, matching the reference,
which carries a per-game disable list for this correction and no other. Still
probed with object(forKey:) rather than bool(forKey:) — uniformity, so the next
default-ON setting added beside it does not inherit a probe-free idiom.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DUCkCw9pmF4e3rv6Ct2LZ1"
```

---

### Task 9: The rules the next reader needs

Everything above is invisible to someone meeting this code cold. This task writes down what would otherwise cost them a day.

**Files:**
- Modify: `CLAUDE.md` (the **PGXP** rule block, and the `zig build fixtures` row's `--pgxp-on` sentence)
- Modify: `.claude/skills/ps1-pgxp/SKILL.md`
- Modify: `.claude/skills/ps1-test-harnesses/SKILL.md` (the sweep's ratchets)

**Interfaces:** none — documentation only.

- [ ] **Step 1: Add the rules to CLAUDE.md**

In the **PGXP** block, after the texture-rectangle rule:

```markdown
- **Two settings consume ONE `rw`, so the RECORD says which attribute may use
  it.** `Command.flags` carries `flag_texture_perspective` and
  `flag_color_perspective`, decided in `gp0` beside `rw` itself because a Metal
  replay has only the record. Each is ANDed with `rw != 0` at the point of use
  and never substituted for it: that is what keeps the PGXP-off guarantee
  structural rather than a promise.
- **Colour correction can only change a GOURAUD primitive**, and that is a
  property of the interpolant rather than a rule on top of it: with three equal
  colours `interpW` returns exactly `c`, because `num = c·(t0+t1+t2)` and
  `den = t0+t1+t2`. `gp0` refuses the bit to the flat-shaded textured opcodes as
  well, so the carve-out is locked twice.
- **`pgxp_color_correction` ships OFF, and a default-OFF flag must NOT be
  assigned in `Bus.init`** — the inverse of the rule for the three default-ON
  ones, and easy to get backwards. Off matches the reference, which is the one
  place it carries a per-game disable list.
- **`--pgxp-on` and the `pgxp` sweep force EVERY correction sub-setting on.**
  Both are parity/coverage instruments, not pictures of the shipped defaults;
  a counter that reads zero because of a default measures nothing.
```

Replace the existing rule "**Only the TEXCOORDS take the perspective path.** The modulation colour keeps `interp` in both rasterizers; colour correction is a later phase." — it is now false. It becomes:

```markdown
- **Which attributes take the perspective path is a per-record decision**, not
  a fixed list: texcoords under `flag_texture_perspective`, vertex and
  modulation colour under `flag_color_perspective`. A textured RECTANGLE is
  still affine permanently, and so is every flat-shaded primitive.
```

Update the `zig build fixtures` row to say `--pgxp-on` now means "PGXP and every correction sub-setting", and note that `tr1-usa-v1-1-pgxp.p1fx` is therefore the parity gate for BOTH interpolants.

- [ ] **Step 2: Extend the `ps1-pgxp` skill**

Add a section covering, with the reasoning rather than only the rule:

- Why two settings cannot share the `rw != 0` signal, and the concrete failure it prevents (texcoords corrected by a setting the player turned off).
- The `depthsFor` / `shadedDepths` / `texturedDepths` shape, and specifically **why the depth gate is "texture OR colour" while the bits are separate** — this is the non-obvious line, and the four-combination test is what pins it.
- `interpAttr` / `ps1_interp_attr`: one expression, spelled the same way on both sides so the call sites are comparable by eye.
- Why `ps1_interp_w`'s truncating `/` survives Phase 4: a colour arrives unsigned and the dither offset is added AFTER interpolation, so `num >= 0` still holds. The old comment predicted signed colour deltas; there are none.
- Why the sweep's new rate must not be read as the hit rate, and why its denominator excludes flat-shaded primitives.
- The measurement from Task 7: the per-workload `color` counts and rates, and what a zero on any of them means.

- [ ] **Step 3: Note the deferred split**

Add to the skill (or to CLAUDE.md's housekeeping section, wherever the file-size rule's exceptions live) that `renderer.zig` stands at ~700 lines against a ~600 guideline, and that the split worth doing is lifting the four shader structs into `gpu/shaders.zig` — deliberately not done during a phase whose safety argument is "nothing else moved".

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs(pgxp): the Phase 4 rules, and the one that Phase 4 falsified

'Only the TEXCOORDS take the perspective path' is no longer true; which
attributes take it is now a per-record decision. Also records why the depth
gate is 'texture OR colour' while the bits stay separate — the one line in this
phase that reads like a mistake if you meet it cold.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DUCkCw9pmF4e3rv6Ct2LZ1"
```

---

## Self-review against the spec

**Spec coverage.** Every "In scope" item maps to a task: `Command.flags` → Task 1; `rw` on untextured Gouraud triangles at the three `drawShadedTriangle` sites → Task 3; the perspective branch at all four shader sites → Tasks 4 and 5; `pgxp_color_correction` (C ABI, Swift setting, Video menu) → Tasks 2 and 8; the sweep's second population and the widened PGXP-on capture → Tasks 7 and 6. Every plumbing-table row appears in the File Structure table with a task that touches it. Every "Testing" bullet is a named test with code, except the one the review found stale (menu sub-setting counts, finding 6), which Task 8 replaces with the assertion that actually exists. The Gates section's four unchanged gates are re-run in Tasks 1, 3, 4, 5 and 7, and the scaled-path assertion it specifies is Task 5's `colourCorrectionReachesTheInteriorOfABlockAtEightX`.

**Two places the plan deviates from the spec, both stated where they happen.** The depth gate widens to "texture OR colour" (finding 1) — without it colour correction cannot act alone, and the spec's own four-combination test would fail. And the flat-shaded carve-out is enforced structurally in `gp0` as well as arithmetically (finding 2); the spec's arithmetic test is kept, not replaced.

**Interfaces.** `Sink.drawShadedTriangle(..., is_transparent, rw, flags)` and `Sink.drawTexturedTriangle(..., rw, flags)` are declared in Task 1 and called with those names in Task 3. `Renderer.drawShadedTriangle(..., rw, perspective_color)` and `drawTexturedTriangle(..., rw, perspective_texture, perspective_color)` are declared in Task 1 and their bodies filled in Task 4. `Depths` / `shadedDepths` / `texturedDepths` are introduced in Task 1's step 7 in provisional form and split in Task 3's step 4 — Task 3 restates the whole helper rather than describing a delta. `PgxpStats.shaded_triangles` and `.color_perspective_primitives` are named identically in Tasks 3 and 7. `PS1_GPU_FLAG_*` (record) and `PS1_PRIM_*_PERSPECTIVE` (instance) are two deliberately distinct namespaces, translated in one place, `PrimBuilder.triangle`.

**Known caveats for the executor.**

- Task 4's equal-colour tests hold two `Gpu` values at once, which is ~2 MB of VRAM on the test-runner stack. If that overflows, heap-allocate both exactly as `gpu_stream_test.zig`'s `StreamCase` does and keep the assertions unchanged.
- Task 6 cannot be verified without `games/` and a Tomb Raider rip; a skipped fixture gate must be reported as skipped, never as passing.
- Task 7's floor numbers are a measurement, not a value this plan can supply. The rule is "measured, rounded down to three significant figures", and an unexplained zero is a finding to chase rather than a number to pin.
- The whole plan's safety argument is one sentence: with PGXP off no vertex resolves, so every `rw` is 0, so every branch added here is not taken. `verify`, `stream-verify`, Gate 1 and Gate 2 are re-run at five points and must never move. If one moves, stop and find the gating bug — do not capture.
