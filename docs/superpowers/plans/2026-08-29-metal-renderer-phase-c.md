# Metal Renderer Phase C — Internal-Resolution Upscaling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render at an internal resolution of N× (N ∈ 1…8) while the 1× output stays byte-identical to the software rasterizer and the scaled output stays a provably exact supersampling of it.

**Architecture:** Every `Ps1PrimInstance` stays in **native** VRAM units — not one field changes, and the `sizeof == 4 * 42` assert holds. A 2-word uniform (`scale`, `dither_off`) is bound at buffer index 2 for both stages; the vertex shader sizes the bounding-box quad to `box * s`, and each fragment shader recovers `nx = px / s`, `ny = py / s`, `sub_x = px % s`, `sub_y = py % s` and multiplies by `s` at the point of use. `MetalVram` owns the scale and gains a native view (`readbackNative`, `nativeHash`, `uploadNative`). Phase C is entirely fixture-driven; nothing is wired into the running app, and it adds **no Zig code at all**.

**Tech Stack:** Metal Shading Language, Swift 6 + swift-testing under `xcodebuild`, the `CPs1` module map, ImageIO (PNG), FNV-1a 64.

**Spec:** `docs/superpowers/specs/2026-08-29-metal-renderer-phase-c-design.md` — read it first, especially § The scaling rule and § The gate. Its predecessor is `docs/superpowers/specs/2026-08-27-metal-renderer-phase-b-design.md`; its parent is `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`.

---

## Deviations from the spec (decided while writing this plan; do not relitigate)

1. **The uniform is two words, not one.** The spec says "a 4-byte `scale`". Gate 2 also needs dithering forced off on *both* sides of the comparison, and the spec's own § Dithering forbids the obvious CPU-side implementation ("clearing the flag in `PrimBuilder` would make the instance record differ between N=1 and N>1 and forfeit the property"). A second uniform word keeps the instance bytes Gate 1 checks and the instance bytes Gate 2 checks **byte-identical** — only a uniform differs. `Ps1RasterUniforms { unsigned int scale; unsigned int dither_off; }`, 8 bytes, asserted on both sides.

2. **The per-task fixture assignments in the spec's task table are re-derived from a census, and three of them move.** Measured from `zig-out/fixtures/` (table in § Fixture census below), not assumed:
   - `pl-hello-world` and `pl-cpu-add` contain **zero draw records** — they are 26 and 432 GP0(A0) uploads plus one fill. They are mover fixtures, so they gate at Task 5, not Task 3.
   - `pl-render-texture-polygon` carries its texture in four GP0(A0) uploads **in the same frame** as the draws that sample it. Its Gate 2 therefore cannot pass until uploads scale, which is Task 5 — not Task 4 as the spec's table says. Task 4 instead gates on hand-built textured draws over a texture placed with `uploadNative` (Task 1), at all three depths, which is strictly earlier coverage of the same shader code.
   - `synthetic-primitives` frames 2, 4 and 6 contain uploads/copies for the same reason, so Task 3's cumulative Gate 2 runs `upTo: 2` and frames 3 and 5 are gated **from blank, one frame at a time** instead. The whole 7-frame replay lands at Task 5.
   - `tr1-usa-v1-1` has no uploads and no copies (fills and textured draws only), so it *can* gate at Task 4. `silent-hill-usa` has 100 `copy_rect`s and lands at Task 5.

3. **Gate 2b's density bound is a ratio band, not `perimeter · s`.** The spec's bound is not provable: a native covered pixel on a primitive's boundary has anywhere from 1 to N² of its subpixels covered, so the per-boundary-pixel error is O(N²), not O(N), and a legitimate render can exceed `perimeter · s`. The assertion is `0.6 ≤ nN / (N² · n1) ≤ 1.6`, which catches both failure modes it exists for — "only the top-left subpixel is drawn" (ratio ≈ 1/N² ≤ 0.25) and "the whole bounding box is painted" (ratio ≫ 1.6) — with a wide margin on the three chosen frames, whose primitives are chunky triangles, exact-by-construction rectangles and exact-by-construction line pixels. `perimeter` is still computed and **printed** as a diagnostic.

4. **Gate 2b gains a third, targeted check the spec does not list: a direct clip-bound test.** § Risks names the inclusive-bound conversion as the likely off-by-one, and neither Gate 1 nor Gate 2 can see it (at every top-left subtexel `p·s > x1·s` and `p·s > (x1+1)·s − 1` agree for integer `p`). The aggregate density check *can* swamp it — one clipped triangle losing `s−1` columns is a few hundred pixels against a frame-wide count. So Task 3 adds `theDrawingAreaClipScalesAsAnInclusiveBound`: one rectangle, one known clip rect, assert the exact min/max non-zero column and row at N=4. It cannot be swamped.

5. **The N=8 sweep over the two geometry fixtures is measured before it is made habitual.** § Risks anticipates this. Task 6 measures it (Gate 4 runs first in that task) and applies a stated rule: if the N=8 pass over `silent-hill-usa` + `tr1-usa-v1-1` exceeds 120 s, N=8 narrows to the synthetics and the PL ROMs by default and the full sweep goes behind `PS1_SCALE_FULL=1`. N ∈ {2,3,4} stays across the whole corpus either way, and **N=3 is never dropped**.

---

## Context

Phase B is landed and green. `MetalRasterizer` + `MetalVram` + `PrimBuilder` + `PrimEncoders` + `HazardTracker` consume a `.p1fx` command stream and produce VRAM byte-identical to the software rasterizer on every frame of every fixture, at 1×. Nothing is reachable from `ContentView`; that is Phase D.

Phase C adds **no emulated behaviour and no Zig code**. Every existing gate is a freeze check: a moved fixture hash, a moved trace golden or a moved PeterLemon floor is a bug in this phase, never a baseline to update.

### Fixture census (measured 2026-08-29 over `zig-out/fixtures/` and `ps1-core/tests/goldens/fixtures/`)

| fixture | frames | record census | first task whose Gate 2 it can pass |
|---|---|---|---|
| `synthetic-primitives` (committed) | 7 | 14 flat tri, 5 Gouraud tri, 8 textured tri, 9 rect, 7 textured rect, 11 line, 2 shaded line, 4 upload, 1 copy | frames 0–1 and (from blank) 3, 5 at **Task 3**; whole file at **Task 5** |
| `synthetic-movers` (committed) | 6 | 2 fill, 2 copy, 3 upload | **Task 5** |
| `pl-render-polygon` | 17 | 18 flat tri, 6 Gouraud tri | **Task 3** |
| `pl-render-rectangle` | 17 | 18 rect | **Task 3** |
| `pl-render-line` | 17 | 60 line, 20 shaded line | **Task 3** |
| `pl-render-texture-polygon` | 17 | 48 textured tri, 34 latch_texpage, 4 upload (2,720 words) | **Task 5** (its texture arrives by upload) |
| `pl-hello-world` | 17 | 26 upload, 1 fill, **0 draws** | **Task 5** |
| `pl-cpu-add` | 17 | 432 upload, 1 fill, **0 draws** | **Task 5** |
| `croc-legend-of-the-gobbos` | 200 | 1,014 upload, 50 fill, **0 draws** | **Task 5** |
| `tr1-usa-v1-1` | 100 | 12,440 textured tri, 979 textured rect, 50 fill, **0 uploads, 0 copies** | **Task 4** |
| `silent-hill-usa` | 100 | 55,793 textured tri, 28,120 Gouraud tri, 132 textured rect, 100 copy, 50 fill, **0 uploads** | **Task 5** |

Two measured facts worth carrying into the work, neither of which changes the plan but both of which bound what Gate 2 proves:

- **Neither geometry fixture uploads a texture.** Their windows begin from a blank VRAM by the format's own rule, so their textured draws sample whatever earlier frames' fills and copies left behind — and a texel of 0 is a *hole*, discarded rather than drawn. The Gouraud triangles (28,120 of them in Silent Hill) and the fills and copies paint regardless, so there is real geometry under the gate, but "84,045 draws" is not 84,045 painted primitives. Task 6's Gate 3 prints the non-zero pixel count of the frame it dumps so the eyeball has a number attached.
- **Sixteen of each PL fixture's seventeen frames are empty** and repeat frame 0's hash. That is Phase A2's finding, unchanged.

---

## Global Constraints

- **`ps1-core/src`, `ps1-capi`, `ps1-golden`, `build.zig` and `DisplayShader.metal` are not modified in this phase, at all.** Phase C adds no Zig code. If a task appears to need one, stop and ask.
- **`Ps1PrimInstance` does not change.** Not one field. `static_assert(sizeof(Ps1PrimInstance) == 4 * 42)` in `Rasterizer.metal` and `MemoryLayout<Ps1PrimInstance>.stride == 4 * 42` in `MetalVramTests.swift` both stay green.
- **Supported scale range is N ∈ 1…8**, validated by a `precondition` in `MetalVram.init`.
- **Gate 1 is a freeze.** Every Phase B test — `MetalRasterizerTests`, `MetalMoverTests`, `MetalVramTests`, `FixtureBridgeTests` — must stay green at 1× at **every** commit. A moved fixture hash is a bug in this phase, never a baseline to update.
- **Dithering: on at 1×, off above it**, decided in the shader as `(p.flags & PS1_PRIM_DITHER) && s == 1 && uni.dither_off == 0u`. Never cleared in `PrimBuilder`.
- **N=3 is in every scale sweep.** `px / s` and `px % s` compile to shifts and masks at every power of two, so a `>> log2(s)` or a "s divides this extent" assumption is invisible at 2, 4 and 8 and fires at 3.
- **Build before testing:** `zig build capi-lib && zig build metallib` then `ps1-macos/test.sh`. Both `zig build` steps need full Xcode; `metallib` recompiles `Rasterizer.metal`, so a shader edit that is not followed by `zig build metallib` is tested as the *old* shader.
- **`Sources/` and `Tests/` are `PBXFileSystemSynchronizedRootGroup`s.** Adding a `.swift` file needs **no** `PS1.xcodeproj` edit. Do not add `PBXFileReference`/`PBXBuildFile` entries.
- **New Swift and Metal files stay under ~350 lines**; split rather than exceed.
- **Everything display-side is out of scope**: the scale-aware scanout wrap, 24bpp scanout, `DisplayShader.metal`, the live ABI handoff, app wiring, the scale picker. All Phase D.
- **Commit style:** one commit per task, directly on `master`, message ending with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  ```
  **Never `git push`.**

---

## Design decisions taken (do not relitigate mid-execution)

**1. Native records, scaled at point of use.** Every `Ps1PrimInstance` field, every `VramRect`, every `.vram` dump and every fixture hash stays in native units. This is a testability decision: the N=1 gate compares literally the same instance bytes Phase B already pins, so "N=1 is unchanged" is a claim about one `* 1` in a shader rather than about a rebuilt encoder. It also keeps the two things that are native *by definition* — the oversized-primitive refusal and the hazard rectangles — out of a second coordinate space.

**2. `PrimBuilder`, `PrimEncoders` and `HazardTracker` change zero lines of logic.** Their only edit is re-pointing `MetalVram.width`/`.height` at `nativeWidth`/`nativeHeight`, because every clamp they perform — the box clamp, the line's VRAM bounds check, `wrapRanges`' axis, the oversized refusal, `conservativeRect`'s row-511 wrap — is native by definition.

**3. Scale is a runtime uniform, not a function constant or a build setting.** One build runs the whole gate ladder, and Phase D gets a picker without rebuilding pipelines.

**4. Two reads stay native.** `ps1_vram_read` linearizes `y * 1024 + x` in native space (that row-crossing is a faithful reproduction of `Vram.index`, which does no masking) and only *then* scales the 2D result. A textured rectangle's `u`/`v` wrap is `(nx − x0 + u0) & 0xFF` — the `+%` on `u8` is in texel units and has nothing to do with internal resolution.

**5. Texture data is never upscaled.** At scale N a texel at `(u, v)` reads the block's top-left subtexel. The parent spec's "render-to-texture content sampled at scale" checklist item is **struck** — it contradicts the rule above it, sampling a CLUT *index* at a sub-position is not a meaningful operation, and there would be no oracle for the N>1 result.

**6. The copy mover is the one exception, and it is deliberate.** `ps1_copy_fragment` keeps the subpixel offset and reads the scaled source, so a VRAM→VRAM blit preserves scaled detail. At a top-left subtexel `sub_x == sub_y == 0`, so the term vanishes and exactness is unaffected.

**7. `ps1_interp` widens to 64-bit rather than capping N at 4.** `Σ wᵢ·aᵢ ≤ area · 255` grows by N²; an oversized-capped primitive (1023 × 511) reaches ≈ 2.13e9 at N=4, ~1% under int32's ceiling, and over it at N=5. A supported range should be decided by what looks good, not by where an overflow lands. `ps1_orient` stays `int`: the oversized refusal bounds every vertex to within 1024 of the visible box, so at N=8 no term exceeds ≈ 1.0e8.

**8. Exactness is a property, not a tolerance.** Taking the top-left subtexel of each N×N block reproduces the 1× image byte-for-byte over the whole 1024×512, on every frame of every fixture, at every N. Coverage, interpolation, the clip, the mask check, the texel fetch, the blend destination and the copy source each evaluate at native coordinate exactly `p` when sampled at `(p·N, p·N)`; induction runs over the frame from a blank VRAM, which is the fixture format's own starting rule. Dithering is the single exception and is disabled above 1×.

---

## File Structure

**Metal (`ps1-macos/Shaders/`):**

- `PrimInstance.h` — **modified** (Task 2). Adds `Ps1RasterUniforms`. `Ps1PrimInstance` untouched.
- `Ps1Color.h` — **modified** (Tasks 3, 4). `ps1_interp` widened to `long`; `ps1_vram_read`/`ps1_fetch_texel`/`ps1_sample` take the scale; `ps1_modulate` takes the dither decision instead of re-deriving it.
- `Rasterizer.metal` — **modified** (Tasks 2, 3, 4, 5). The vertex function and all four fragment functions.

**Swift (`ps1-macos/Sources/PS1/`):**

- `MetalVram.swift` — **modified** (Task 1). Native statics, instance `scale`/`width`/`height`/`pixelCount`, `uploadNative`, `readbackNative`, `nativeHash`.
- `MetalRasterizer.swift` — **modified** (Tasks 1, 2). Scratch texture and snapshot blit follow the scaled size; `ditherDisabled`; the uniform binding.
- `PrimBuilder.swift`, `PrimEncoders.swift`, `VramDump.swift` — **modified** (Task 1), constant renames only.
- `VramImage.swift` — **new** (Task 6). ABGR1555 → PNG via ImageIO.

**Swift tests (`ps1-macos/Tests/PS1Tests/`):**

- `MetalScaleHarness.swift` — **new** (Tasks 2, 3). `frame`, `fixtureFrame`, `compare`.
- `MetalScaleTests.swift` — **new** (Tasks 2–6). Gates 2, 2b, 3, 4 and the `uploadNative` round trip's consumers.
- `MetalVramTests.swift` — **modified** (Tasks 1, 6). The scale round trips and the `VramImage` PNG round trip.
- `MetalMoverTests.swift` — **modified** (Task 2). Its hand-rolled encoder must bind the new uniform.
- `MetalRasterizerTests.swift` — **modified** (Task 1). Constant rename only.

**Docs:**

- `CLAUDE.md` — **modified** (Task 6).

---

## Running one test

The suite is `ps1-macos/test.sh` (no arguments, ~136 tests). To run a single swift-testing function while iterating:

```bash
xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" SYMROOT="$PWD/.build/xcode" \
  -only-testing:PS1Tests/theNameOfTheTestFunction test 2>&1 | tail -25
```

Give the function name **without** the trailing `()`. If xcodebuild reports that the filter matched nothing, fall back to the whole suite and grep. Every task ends by running the whole suite anyway — Gate 1 is a freeze and it is checked per commit, not per phase.

---

## Task 1: Scale-aware `MetalVram`

The render texture, the scratch texture and the staging buffer become N× while every *record* stays native. Removing the `static let width`/`height`/`pixelCount` members is deliberate: it turns every existing call site into a compile error, and each one has to be answered with "native or scaled?" rather than silently inheriting one.

Nothing in the shaders scales yet, so at N>1 the *rendered* output is meaningless after this task. What this task gates is the two native-view conversions and the fact that 1× is untouched.

**Files:**
- Modify: `ps1-macos/Sources/PS1/MetalVram.swift` (whole file)
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift:70-77` (the scratch descriptor), `:160-166` (the snapshot blit)
- Modify: `ps1-macos/Sources/PS1/PrimBuilder.swift` (7 sites), `ps1-macos/Sources/PS1/PrimEncoders.swift` (7 sites), `ps1-macos/Sources/PS1/VramDump.swift` (3 sites)
- Modify: `ps1-macos/Tests/PS1Tests/MetalVramTests.swift` (new tests + 0 renames), `ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift` (1 rename), `ps1-macos/Tests/PS1Tests/MetalMoverTests.swift` (3 renames)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces, all used by Tasks 2–6:
  - `MetalVram.nativeWidth: Int` (1024), `MetalVram.nativeHeight: Int` (512), `MetalVram.nativePixelCount: Int` (524288) — statics.
  - `MetalVram.init?(device: MTLDevice, queue: MTLCommandQueue, scale: Int = 1)`
  - `let scale: Int`, `var width: Int`, `var height: Int`, `var pixelCount: Int` — instance properties.
  - `func uploadNative(_ pixels: [UInt16])` — a 1× image replicated N×N.
  - `func readbackNative() -> [UInt16]` — `nativePixelCount` entries, each block's top-left subtexel.
  - `var nativeHash: UInt64` — FNV-1a 64 over that.
  - `func upload(_:)`, `func readback() -> [UInt16]`, `var hash: UInt64` keep their meaning: the **scaled** image, `pixelCount` entries, identical to today's at N=1.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`:

```swift
// MARK: - Phase C: the native view of a scaled texture

private func makeScaledVram(_ scale: Int) -> MetalVram? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return nil }
    return MetalVram(device: device, queue: queue, scale: scale)
}

/// A deterministic native image with distinct values in the places a
/// replication or a downsample bug lands: the four corners and a diagonal.
private func nativePattern() -> [UInt16] {
    var p = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for i in 0..<p.count { p[i] = UInt16(truncatingIfNeeded: i &* 2654435761) }
    p[0] = 0x8001
    p[MetalVram.nativeWidth - 1] = 0x7FFE
    p[(MetalVram.nativeHeight - 1) * MetalVram.nativeWidth] = 0x1234
    p[MetalVram.nativePixelCount - 1] = 0xABCD
    return p
}

@Test func theNativeConstantsDoNotFollowTheScale() throws {
    // Every Ps1PrimInstance field, every VramRect and every .vram dump is in
    // these units at EVERY internal resolution. If a scale ever leaks into
    // them, the encoder starts clamping in the wrong space and the oversized
    // refusal changes meaning.
    #expect(MetalVram.nativeWidth == 1024)
    #expect(MetalVram.nativeHeight == 512)
    #expect(MetalVram.nativePixelCount == 1024 * 512)

    guard let v = makeScaledVram(3) else { return }
    #expect(v.scale == 3)
    #expect(v.width == 3072)
    #expect(v.height == 1536)
    #expect(v.pixelCount == 3072 * 1536)
}

@Test func atOneXTheNativeViewIsTheWholeTexture() throws {
    guard let v = makeScaledVram(1) else { return }
    let pattern = nativePattern()
    v.uploadNative(pattern)
    #expect(v.readbackNative() == pattern)
    #expect(v.readback() == pattern)
    #expect(v.nativeHash == Fnv1a.hash(vram: pattern))
    #expect(v.nativeHash == v.hash)
}

@Test func uploadNativeReplicatesEveryPixelIntoAnNbyNBlock() throws {
    // scale 3, not 2 or 4: `px / s` and `px % s` are shifts and masks at every
    // power of two, so an odd scale is the only one that catches a bug written
    // as `>> log2(s)` or an assumption that s divides some extent.
    guard let v = makeScaledVram(3) else { return }
    let pattern = nativePattern()
    v.uploadNative(pattern)

    let full = v.readback()
    #expect(full.count == v.pixelCount)
    for (nx, ny) in [(0, 0), (1023, 0), (0, 511), (1023, 511), (17, 43)] {
        let want = pattern[ny * MetalVram.nativeWidth + nx]
        for sy in 0..<3 {
            for sx in 0..<3 {
                let i = (ny * 3 + sy) * v.width + (nx * 3 + sx)
                #expect(full[i] == want, "block (\(nx),\(ny)) subpixel (\(sx),\(sy))")
            }
        }
    }
}

@Test func readbackNativeRecoversTheImageUploadNativeReplicated() throws {
    for scale in [2, 3, 4, 8] {
        guard let v = makeScaledVram(scale) else { return }
        let pattern = nativePattern()
        v.uploadNative(pattern)
        #expect(v.readbackNative() == pattern, "scale \(scale)")
        #expect(v.nativeHash == Fnv1a.hash(vram: pattern), "scale \(scale)")
    }
}

@Test func readbackNativeTakesTheTopLeftSubtexelOfEachBlock() throws {
    // The downsample rule is "top-left subtexel", NOT an average and not the
    // last write to land in the block: at scale, subpixels other than the
    // top-left legitimately differ from their block's native value, and
    // discarding them is exactly what makes the exactness property a property.
    guard let v = makeScaledVram(2) else { return }
    var full = [UInt16](repeating: 0, count: v.pixelCount)
    for y in 0..<v.height {
        for x in 0..<v.width {
            // Top-left subpixels get 0x0101, every other subpixel 0xFFFF.
            full[y * v.width + x] = (x % 2 == 0 && y % 2 == 0) ? 0x0101 : 0xFFFF
        }
    }
    v.upload(full)
    #expect(v.readbackNative() == [UInt16](repeating: 0x0101,
                                           count: MetalVram.nativePixelCount))
}

@Test func aScaledTextureStartsBlankJustLikeAOneXOne() throws {
    guard let v = makeScaledVram(4) else { return }
    #expect(v.nativeHash == Fnv1a.hash(vram: [UInt16](repeating: 0,
                                                      count: MetalVram.nativePixelCount)))
    #expect(v.readback().allSatisfy { $0 == 0 })
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -30
```
Expected: **compile failure** — `MetalVram` has no member `nativeWidth`, `scale`, `uploadNative`, `readbackNative` or `nativeHash`, and no `scale:` initializer parameter.

- [ ] **Step 3: Make `MetalVram` scale-aware**

Replace the head of `ps1-macos/Sources/PS1/MetalVram.swift` from `final class MetalVram {` down to the end of `init`:

```swift
final class MetalVram {
    /// PS1 VRAM's own dimensions. Every `Ps1PrimInstance` field, every
    /// `VramRect`, every `.vram` dump and every fixture hash is in THESE units
    /// at every internal resolution — Phase C scales in the shader, at the
    /// point of use, and nowhere else. Nothing that clamps a record (the box
    /// clamp, the line's VRAM bounds check, `wrapRanges`' axis, the oversized
    /// refusal) may use the scaled ones.
    static let nativeWidth = 1024
    static let nativeHeight = 512
    static let nativePixelCount = nativeWidth * nativeHeight

    /// Internal resolution multiplier, 1...8. At 8 the render texture is
    /// 8192 x 4096 x 2 = 67 MB, and the scratch copy target is another 67 MB.
    let scale: Int
    var width: Int { Self.nativeWidth * scale }
    var height: Int { Self.nativeHeight * scale }
    var pixelCount: Int { width * height }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let texture: MTLTexture
    /// Staging for both directions. Shared storage, allocated once: readback
    /// runs per fixture frame and a per-frame allocation of up to 67 MB is
    /// pure waste.
    private let staging: MTLBuffer

    init?(device: MTLDevice, queue: MTLCommandQueue, scale: Int = 1) {
        precondition(scale >= 1 && scale <= 8, "internal resolution must be 1...8")
        // Locals, not `self.width`: a computed property cannot be read before
        // every stored property is initialized.
        let w = Self.nativeWidth * scale
        let h = Self.nativeHeight * scale

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: w, height: h, mipmapped: false)
        // .shaderRead as well as .renderTarget: the same texture is `read()`
        // at arbitrary coordinates by the fragment shader that is drawing into
        // it. That aliasing is legal only under the pass-splitting invariant —
        // nothing sampled during a render pass may have been written during
        // that pass — which the encoder's hazard tracking enforces.
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let staging = device.makeBuffer(length: w * h * 2, options: .storageModeShared)
        else { return nil }

        self.scale = scale
        self.device = device
        self.queue = queue
        self.texture = texture
        self.staging = staging
        clear()
    }
```

Replace the bodies of `upload` and `readback` with two private blit helpers plus the four public entry points (the `clear()` above them is unchanged):

```swift
    private func blitStagingToTexture() {
        guard let cmd = queue.makeCommandBuffer() else {
            preconditionFailure("MetalVram.upload: queue.makeCommandBuffer() returned nil")
        }
        guard let blit = cmd.makeBlitCommandEncoder() else {
            preconditionFailure("MetalVram.upload: makeBlitCommandEncoder() returned nil")
        }
        blit.copy(from: staging, sourceOffset: 0,
                  sourceBytesPerRow: width * 2, sourceBytesPerImage: pixelCount * 2,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func blitTextureToStaging() {
        guard let cmd = queue.makeCommandBuffer() else {
            preconditionFailure("MetalVram.readback: queue.makeCommandBuffer() returned nil")
        }
        guard let blit = cmd.makeBlitCommandEncoder() else {
            preconditionFailure("MetalVram.readback: makeBlitCommandEncoder() returned nil")
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: staging, destinationOffset: 0,
                  destinationBytesPerRow: width * 2,
                  destinationBytesPerImage: pixelCount * 2)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// A SCALED image: `pixelCount` entries. Identical to Phase B's at scale 1.
    func upload(_ pixels: [UInt16]) {
        precondition(pixels.count == pixelCount)
        pixels.withUnsafeBytes { src in
            staging.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
        blitStagingToTexture()
    }

    /// A NATIVE image, replicated N x N into the scaled texture.
    ///
    /// This is the resync path the parent spec's § Frame pacing requires when
    /// the frame queue or the stream buffer overflows and the software side's
    /// VRAM becomes the truth. It is built here, where it is a scale concern
    /// and headlessly testable; Phase D consumes it. CPU-side replication into
    /// the existing staging buffer is sufficient — the path is rare by
    /// construction, and a blit-and-blow-up render pass would need a pipeline
    /// and a pass boundary to save a copy nobody is waiting on.
    func uploadNative(_ pixels: [UInt16]) {
        precondition(pixels.count == Self.nativePixelCount)
        if scale == 1 { upload(pixels); return }
        let dst = staging.contents().bindMemory(to: UInt16.self, capacity: pixelCount)
        for y in 0..<Self.nativeHeight {
            let srcRow = y * Self.nativeWidth
            for sy in 0..<scale {
                var o = (y * scale + sy) * width
                for x in 0..<Self.nativeWidth {
                    let v = pixels[srcRow + x]
                    for _ in 0..<scale { dst[o] = v; o += 1 }
                }
            }
        }
        blitStagingToTexture()
    }

    /// The SCALED image: `pixelCount` entries.
    func readback() -> [UInt16] {
        blitTextureToStaging()
        var out = [UInt16](repeating: 0, count: pixelCount)
        out.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: staging.contents(), byteCount: dst.count)
        }
        return out
    }

    /// The NATIVE view: each N x N block's TOP-LEFT subtexel, `nativePixelCount`
    /// entries. Subpixels other than the top-left may legitimately differ from
    /// their block's native value — that is what supersampling is — and this
    /// discards them, which is what makes the exactness property checkable.
    ///
    /// Reads out of the staging buffer directly rather than through
    /// `readback()`: at scale 8 that would materialize a 67 MB array per frame
    /// to keep 1/64th of it, on the hottest path in Gate 2.
    func readbackNative() -> [UInt16] {
        blitTextureToStaging()
        let src = staging.contents().bindMemory(to: UInt16.self, capacity: pixelCount)
        var out = [UInt16](repeating: 0, count: Self.nativePixelCount)
        for y in 0..<Self.nativeHeight {
            let srcRow = y * scale * width
            let dstRow = y * Self.nativeWidth
            for x in 0..<Self.nativeWidth { out[dstRow + x] = src[srcRow + x * scale] }
        }
        return out
    }

    /// FNV-1a 64 over the full SCALED texture as little-endian u16 — the same
    /// convention `ShadowVram` and `fixture.hashVram` already use. At scale 1
    /// this is the value every Phase B gate compares.
    var hash: UInt64 { Fnv1a.hash(vram: readback()) }

    /// FNV-1a 64 over the native view. This is the Phase C gate's currency:
    /// at every scale it must equal the 1x `hash` of the same replay.
    var nativeHash: UInt64 { Fnv1a.hash(vram: readbackNative()) }
```

- [ ] **Step 4: Re-point every static call site**

The removed statics are now compile errors. Answer each with the native constant — **every one of these is native by definition**, which is the whole reason `PrimBuilder`/`PrimEncoders` change no logic:

- `PrimBuilder.swift`: `MetalVram.width` → `MetalVram.nativeWidth` (5 sites: the triangle box clamp, `conservativeRect`'s three, plus the rectangle clamp), `MetalVram.height` → `MetalVram.nativeHeight` (4 sites).
- `PrimEncoders.swift`: `MetalVram.width` → `MetalVram.nativeWidth` (3 sites: the line's bounds check, `clampBox`, `wrapRanges`' x axis), `MetalVram.height` → `MetalVram.nativeHeight` (4 sites).
- `VramDump.swift`: `MetalVram.width` → `MetalVram.nativeWidth` (2 sites, in `firstDifferences`), `MetalVram.pixelCount` → `MetalVram.nativePixelCount` (2 sites, in `read`). A `.vram` dump is a 1 MB native blob produced by `ps1-golden`; it never scales.
- `MetalRasterizerTests.swift`: `MetalVram.pixelCount` → `MetalVram.nativePixelCount` (1 site, in `aSpriteWrapsItsTexcoordsInEightBits`).
- `MetalMoverTests.swift`: `MetalVram.pixelCount` → `MetalVram.nativePixelCount` (1 site), `MetalVram.width` → `MetalVram.nativeWidth` (2 sites). These tests build a 1× vram, so native and scaled agree; the native constant is the honest one.

In `MetalRasterizer.swift`, the scratch texture and the snapshot blit follow the **scaled** size — scratch is a snapshot of the render texture, so it must match it exactly:

```swift
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: vram.width, height: vram.height,
            mipmapped: false)
```

```swift
                    blit.copy(from: vram.texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: vram.width,
                                                  height: vram.height, depth: 1),
                              to: scratch, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
```

- [ ] **Step 5: Run the tests to verify they pass, and that Gate 1 has not moved**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -30
```
Expected: the whole suite green, including every Phase B fixture test. The six new tests pass. **If any Phase B fixture hash moved, stop** — this task changes no rendering and cannot legitimately move one.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/MetalVram.swift ps1-macos/Sources/PS1/MetalRasterizer.swift \
        ps1-macos/Sources/PS1/PrimBuilder.swift ps1-macos/Sources/PS1/PrimEncoders.swift \
        ps1-macos/Sources/PS1/VramDump.swift ps1-macos/Tests/PS1Tests/MetalVramTests.swift \
        ps1-macos/Tests/PS1Tests/MetalRasterizerTests.swift ps1-macos/Tests/PS1Tests/MetalMoverTests.swift
git commit -m "$(cat <<'MSG'
feat(metal): scale-aware MetalVram with a native view

nativeWidth/nativeHeight/nativePixelCount as statics and width/height/
pixelCount as instance properties, so every record stays in native units
while the textures follow the internal resolution. Adds uploadNative
(1x image replicated NxN, the Phase D resync path), readbackNative (each
block's top-left subtexel) and nativeHash (the Phase C gate's currency).

The static width/height are REMOVED rather than kept as aliases: that
turns every call site into a compile error and forces each to be answered
with "native or scaled?". All of PrimBuilder, PrimEncoders and VramDump
answer native — the box clamp, the line bounds check, wrapRanges' axis,
the oversized refusal and a .vram dump are native by definition — which
is why neither encoder changes a line of logic.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 2: The `scale` uniform and `ps1_vertex`

The uniform is declared once in C, bound at index 2 for both stages, and consumed by the vertex shader only. After this task the **fill** mover is already complete at every scale — `ps1_fill_fragment` has no coverage test, no clip and no mask, so the region it paints *is* the quad the vertex shader emitted. That is what makes it the isolation gate for this task.

**Files:**
- Modify: `ps1-macos/Shaders/PrimInstance.h` (append the uniform struct)
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_vertex`, and one `static_assert`)
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift` (`ditherDisabled`; the binding in `openPass`)
- Modify: `ps1-macos/Tests/PS1Tests/MetalMoverTests.swift` (its hand-rolled encoder must bind the uniform)
- Create: `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift`
- Create: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`

**Interfaces:**
- Consumes: `MetalVram.init(device:queue:scale:)`, `readback()`, `readbackNative()`, `width`, `height`, `scale` (Task 1).
- Produces:
  - `Ps1RasterUniforms { unsigned int scale; unsigned int dither_off; }` in `PrimInstance.h`, 8 bytes, visible to Swift as `Ps1RasterUniforms(scale: UInt32, dither_off: UInt32)`.
  - `MetalRasterizer.ditherDisabled: Bool` (default `false`).
  - `MetalScaleHarness.Frame { scaled: [UInt16], native: [UInt16], instances: [Ps1PrimInstance], width: Int, height: Int, scale: Int }`
  - `MetalScaleHarness.frame(scale:payload:ditherDisabled:_:) throws -> Frame?` — builds a rasterizer at `scale`, replays ONE frame from a blank VRAM through the caller's closure, and returns both views plus the instances the encoder built.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift`:

```swift
import Foundation
import Metal
import CPs1
@testable import PS1

/// Phase C's replay helpers. Separate from `MetalFixtureHarness`, which
/// compares one rasterizer against a fixture's own Zig-produced hash; these
/// compare the backend against ITSELF at two internal resolutions, which is a
/// different question and needs both views of the result.
///
/// Every entry point returns nil rather than failing when there is no Metal
/// device, for the reason `MetalFixtureHarness` already documents: a headless
/// runner would otherwise turn the whole suite red for no signal.
enum MetalScaleHarness {
    struct Frame {
        let scaled: [UInt16]
        let native: [UInt16]
        /// The instances the encoder built, snapshotted BEFORE `endFrame`
        /// clears them. Gate 2b reads the boxes back out of these.
        let instances: [Ps1PrimInstance]
        let width: Int
        let height: Int
        let scale: Int
    }

    /// One frame, from a blank VRAM, at `scale`.
    ///
    /// Dithering is off by default: it is the single exception to exactness,
    /// and every caller here is checking exactness. Gate 1 is what checks the
    /// dithered 1x output, per frame, per fixture.
    static func frame(scale: Int, payload: [UInt32] = [], ditherDisabled: Bool = true,
                      _ body: (MetalRasterizer) -> Void) throws -> Frame? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
        let r = try MetalRasterizer(vram: vram)
        r.ditherDisabled = ditherDisabled

        var instances: [Ps1PrimInstance] = []
        payload.withUnsafeBufferPointer { buf in
            r.beginFrame(payload: buf)
            body(r)
            instances = r.instances
            r.endFrame()
        }
        return Frame(scaled: vram.readback(), native: vram.readbackNative(),
                     instances: instances, width: vram.width, height: vram.height,
                     scale: scale)
    }
}
```

Create `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`:

```swift
import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

// Phase C's gate ladder. Gate 1 (Metal == Zig at 1x) lives in
// MetalRasterizerTests and MetalMoverTests and is a FREEZE: nothing here may
// move it. What these tests add is Gate 2 (downsample-invariance), Gate 2b
// (bounds, the clip conversion and coverage density) and, at Task 6, Gates 3
// and 4.

/// The scales every sweep runs. 3 is in the list on purpose: `px / s` and
/// `px % s` compile to shifts and masks at every power of two, so a bug
/// written as `>> log2(s)`, or an assumption that `s` divides some extent, is
/// invisible at 2, 4 and 8 and fires at 3.
let scaleLadder = [2, 3, 4, 8]

@Test func theRasterUniformIsEightBytesOnBothSides() {
    // The Metal side carries `static_assert(sizeof(Ps1RasterUniforms) == 8)`.
    // This is the other half of that pair: a field added on one side only
    // shears `scale` and `dither_off` against each other, and the symptom
    // would be "scale 1 renders at scale 0", i.e. nothing drawn at all.
    #expect(MemoryLayout<Ps1RasterUniforms>.stride == 8)
    #expect(MemoryLayout<Ps1RasterUniforms>.size == 8)
}

@Test func aFillPaintsExactlyItsScaledBoxAndNothingElse() throws {
    // ps1_fill_fragment has no coverage test, no clip and no mask, so whatever
    // region it paints IS the quad ps1_vertex emitted. That isolates the
    // vertex shader: this test fails for a wrong box expansion and for nothing
    // else.
    let scale = 4
    guard let f = try MetalScaleHarness.frame(scale: scale, { r in
        var fill = Ps1GpuCommand()
        fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
        fill.x = 10; fill.y = 20; fill.w = 20; fill.h = 20
        fill.value = 0x7C1F
        r.apply(fill)
    }) else { return }

    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0
    for y in 0..<f.height {
        for x in 0..<f.width where f.scaled[y * f.width + x] != 0 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            count += 1
        }
    }
    // The box is INCLUSIVE (10,20)-(29,39), so the scaled span is
    // [10*s, (29+1)*s - 1] — the same +1 the vertex shader applies, and the
    // same one the drawing-area clip will need in Task 3.
    #expect(minX == 10 * scale)
    #expect(maxX == 30 * scale - 1)
    #expect(minY == 20 * scale)
    #expect(maxY == 40 * scale - 1)
    #expect(count == 20 * scale * 20 * scale)
    #expect(f.native.filter { $0 != 0 }.count == 20 * 20)
}

@Test func aFillIsDownsampleInvariantAtEveryScale() throws {
    // The first instance of the property the whole phase is built on, on the
    // one path that is already complete after this task. An odd, prime-ish
    // extent (33 x 17) so no scale divides it evenly.
    func draw(_ r: MetalRasterizer) {
        var fill = Ps1GpuCommand()
        fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
        fill.x = 7; fill.y = 11; fill.w = 33; fill.h = 17
        fill.value = 0x03E0
        r.apply(fill)
    }

    guard let one = try MetalScaleHarness.frame(scale: 1, draw) else { return }
    for scale in scaleLadder {
        guard let many = try MetalScaleHarness.frame(scale: scale, draw) else { return }
        #expect(many.native == one.native, "scale \(scale)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -30
```
Expected: **compile failure** — no `Ps1RasterUniforms`, no `MetalRasterizer.ditherDisabled`.

- [ ] **Step 3: Declare the uniform**

Append to `ps1-macos/Shaders/PrimInstance.h`, before the closing `#endif`:

```c
/* Per-DRAW state that is not per-primitive: the internal resolution, and one
 * debug switch. Bound at buffer index 2 for BOTH stages (index 0 is the
 * instance buffer, index 1 the upload payload).
 *
 * RUNTIME, not a function constant and not a build setting: one build then
 * runs the whole gate ladder, and Phase D gets a resolution picker without
 * rebuilding pipelines.
 *
 * `dither_off` is a TEST switch, and it lives here rather than in the instance
 * record for a specific reason. Dithering is the one thing that breaks
 * downsample-invariance, so Gate 2 must run with it off on both sides — but
 * clearing PS1_PRIM_DITHER in PrimBuilder instead would make the instance
 * bytes Gate 2 checks differ from the ones Gate 1 checks, and the whole point
 * of keeping records native is that those two are the same bytes. */
typedef struct {
    unsigned int scale;      /* internal resolution, 1...8 */
    unsigned int dither_off; /* force dithering off at EVERY scale */
} Ps1RasterUniforms;
```

- [ ] **Step 4: Scale the quad in `ps1_vertex`**

In `ps1-macos/Shaders/Rasterizer.metal`, add next to the existing instance assert:

```metal
static_assert(sizeof(Ps1RasterUniforms) == 8,
              "Ps1RasterUniforms layout changed — update the Swift stride test too");
```

and replace the body of `ps1_vertex` (its doc comment and the `[[instance_id]]` comment stay verbatim — that comment records a real bug and must not be lost):

```metal
vertex PrimVertexOut ps1_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device Ps1PrimInstance* prims [[buffer(0)]],
                                constant Ps1RasterUniforms& uni [[buffer(2)]]) {
    uint index = iid;
    const device Ps1PrimInstance& p = prims[index];

    // The box is in NATIVE units, like every other field of the record; the
    // quad is its image at the internal resolution. The far edge is +1 because
    // the box is inclusive, and that +1 happens BEFORE the scale — `(x1+1)*s`,
    // never `x1*s + 1`.
    float s = float(uni.scale);
    float x = (vid & 1u) ? float(p.box_x1 + 1) * s : float(p.box_x0) * s;
    float y = (vid & 2u) ? float(p.box_y1 + 1) * s : float(p.box_y0) * s;

    PrimVertexOut out;
    // The target is 1024s x 512s, so the divisors follow it. Metal's
    // framebuffer origin is top-left, so y is flipped relative to NDC.
    //
    // Exact at every s, including 3: IEEE division is correctly rounded, and
    // (k*s)/(512*s) has the exact value k/512, which is a dyadic rational for
    // every k <= 1024 and therefore representable. No epsilon can creep in to
    // flip a boundary pixel.
    out.position = float4(x / (512.0f * s) - 1.0f, 1.0f - y / (256.0f * s), 0.0f, 1.0f);
    out.iid = index;
    return out;
}
```

- [ ] **Step 5: Bind the uniform**

In `ps1-macos/Sources/PS1/MetalRasterizer.swift`, add the debug switch next to `passCount`:

```swift
    /// Test-only: forces dithering off at every scale, including 1x.
    ///
    /// Gate 2 (downsample-invariance) needs it on both sides of the comparison
    /// because dithering is the single exception to exactness. It is a UNIFORM,
    /// not a flag cleared in PrimBuilder, so the instance bytes stay identical
    /// to the ones Gate 1 checks. Never set on any shipping path.
    var ditherDisabled = false
```

and, in `endFrame`'s `openPass()`, after the payload binding:

```swift
            var uni = Ps1RasterUniforms(scale: UInt32(vram.scale),
                                        dither_off: ditherDisabled ? 1 : 0)
            e.setVertexBytes(&uni, length: MemoryLayout<Ps1RasterUniforms>.stride, index: 2)
            e.setFragmentBytes(&uni, length: MemoryLayout<Ps1RasterUniforms>.stride, index: 2)
```

Binding it for the fragment stage too, even though no fragment function reads it until Task 3, is deliberate: the alternative is a second binding site added three tasks later, in the one function whose omissions are invisible until a shader reads uninitialized memory.

- [ ] **Step 6: Fix the one hand-rolled encoder in the test suite**

`aTextureBoundAsAttachmentCanBeReadAtAnotherCoordinate` in `MetalMoverTests.swift` builds its own `MTLRenderCommandEncoder` rather than going through `MetalRasterizer`, so it does not inherit the binding. `ps1_vertex` now reads buffer 2 unconditionally, and an unbound buffer argument is undefined behaviour, not a zero. Add after `enc.setFragmentTexture(...)`:

```swift
    // ps1_vertex reads the raster uniforms; this encoder is hand-rolled and
    // does not go through MetalRasterizer.openPass, so it must bind them
    // itself. An unbound buffer argument is undefined, not zero.
    var uni = Ps1RasterUniforms(scale: 1, dither_off: 0)
    enc.setVertexBytes(&uni, length: MemoryLayout<Ps1RasterUniforms>.stride, index: 2)
    enc.setFragmentBytes(&uni, length: MemoryLayout<Ps1RasterUniforms>.stride, index: 2)
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
zig build metallib && ps1-macos/test.sh 2>&1 | tail -30
```
Expected: whole suite green. `aFillPaintsExactlyItsScaledBoxAndNothingElse` and `aFillIsDownsampleInvariantAtEveryScale` now pass; every Phase B gate is unchanged.

- [ ] **Step 8: Commit**

```bash
git add ps1-macos/Shaders/PrimInstance.h ps1-macos/Shaders/Rasterizer.metal \
        ps1-macos/Sources/PS1/MetalRasterizer.swift \
        ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift \
        ps1-macos/Tests/PS1Tests/MetalScaleTests.swift \
        ps1-macos/Tests/PS1Tests/MetalMoverTests.swift
git commit -m "$(cat <<'MSG'
feat(metal): the scale uniform and a scaled bounding-box quad

Ps1RasterUniforms {scale, dither_off}, declared in C and bound at buffer
index 2 for both stages. ps1_vertex sizes the quad from box_x0*s to
(box_x1+1)*s and divides by the scaled target — exact at every s
including 3, since IEEE division is correctly rounded and (k*s)/(512*s)
has the exact dyadic value k/512.

dither_off is a uniform rather than a flag cleared in PrimBuilder so the
instance bytes Gate 2 checks are the same bytes Gate 1 checks.

The fill mover is complete at every scale after this: ps1_fill_fragment
has no coverage test, no clip and no mask, so the region it paints is the
quad the vertex shader emitted, which is what the new tests pin.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 3: `ps1_prim_fragment` at scale

Coverage, interpolation, the fill rule, the mask, the blend and the drawing-area clip. After this task every **untextured** drawing primitive is exact at every scale, and the corpus's three untextured PL ROMs plus four frames of the synthetic fixture gate it.

The one thing here that no hash can see is the drawing-area clip's inclusive-bound conversion, `[x0, x1]` → `[x0·s, (x1+1)·s − 1]`. The plausible wrong answer, `x1·s`, agrees with the right one at every top-left subtexel (`p·s > x1·s` ⟺ `p > x1` ⟺ `p·s > (x1+1)·s − 1` for integer `p`), so it passes Gate 1 *and* Gate 2 and loses `s−1` pixel columns and rows off two edges of every clipped primitive. `theDrawingAreaClipScalesAsAnInclusiveBound` is aimed squarely at it.

**Files:**
- Modify: `ps1-macos/Shaders/Ps1Color.h` (`ps1_interp`)
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_triangle_coverage`, `ps1_prim_fragment`)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift` (`fixtureFrame`, `compare`)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`

**Interfaces:**
- Consumes: `Ps1RasterUniforms`, `MetalRasterizer.ditherDisabled`, `MetalScaleHarness.frame` (Task 2); `MetalVram.readbackNative`/`nativeHash` (Task 1).
- Produces:
  - `MetalScaleHarness.fixtureFrame(_ name: String, frame: Int, scale: Int) throws -> Frame?` — one fixture frame replayed **from a blank VRAM**.
  - `MetalScaleHarness.Divergence { frame: Int, message: String }`
  - `MetalScaleHarness.compare(_ name: String, scale: Int, upTo: Int?) throws -> Divergence?` — the same fixture replayed cumulatively at 1× and at `scale`, dithering off on both, compared per frame on the native view. `nil` means every frame agreed (or that there is no Metal device).
  - Shader: `ps1_triangle_coverage(p, s, px, py, w0, w1, w2, area)` — one more parameter, the scale.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`:

```swift
// MARK: - Gate 2b: bounds, the clip conversion, and coverage density

/// Gate 2b, bounds half. Every non-zero scaled pixel must lie inside some
/// instance's scaled box — intersected with that instance's scaled drawing
/// area for the seven DRAWING kinds. The three movers carry no clip: their
/// instances are zero-initialized by the encoder and the shader never applies
/// one to them.
private func assertNothingOutsideTheScaledBoxes(_ f: MetalScaleHarness.Frame,
                                                _ label: String) {
    let s = f.scale
    var allowed = [Bool](repeating: false, count: f.width * f.height)
    for inst in f.instances {
        var x0 = Int(inst.box_x0) * s, x1 = (Int(inst.box_x1) + 1) * s - 1
        var y0 = Int(inst.box_y0) * s, y1 = (Int(inst.box_y1) + 1) * s - 1
        if inst.kind <= Int32(PS1_PRIM_SHADED_LINE_PIXEL) {
            x0 = max(x0, Int(inst.clip_x0) * s)
            x1 = min(x1, (Int(inst.clip_x1) + 1) * s - 1)
            y0 = max(y0, Int(inst.clip_y0) * s)
            y1 = min(y1, (Int(inst.clip_y1) + 1) * s - 1)
        }
        guard x0 <= x1, y0 <= y1 else { continue }
        for y in y0...y1 {
            let row = y * f.width
            for x in x0...x1 { allowed[row + x] = true }
        }
    }
    var strays = 0
    var first = "none"
    for i in 0..<f.scaled.count where f.scaled[i] != 0 && !allowed[i] {
        if strays == 0 {
            first = String(format: "(%d,%d)=%04X", i % f.width, i / f.width, f.scaled[i])
        }
        strays += 1
    }
    #expect(strays == 0, Comment(rawValue: "\(label): \(strays) px outside every scaled box, first \(first)"))
}

/// Gate 2b, density half.
///
/// The spec proposes a tolerance of `perimeter * s`; that bound is not
/// provable — a native covered pixel on a primitive's boundary can have
/// anywhere from 1 to s*s of its subpixels covered, so the per-boundary-pixel
/// error is O(s^2), not O(s). What the check exists to catch is two gross
/// failures Gate 2 is blind to, because Gate 2 constrains only the top-left
/// subtexel of each block:
///
///   - every OTHER subpixel left black  -> ratio ~ 1/s^2, at most 0.25
///   - the whole bounding box painted    -> ratio well above 1.6
///
/// so a ratio band catches both with a wide margin on these three frames,
/// whose primitives are chunky triangles and exact-by-construction rectangles
/// and line pixels. `perimeter` is still computed and printed: it is the
/// number that says how much slack the band actually has.
private func assertCoverageDensity(oneX: [UInt16], _ f: MetalScaleHarness.Frame,
                                   _ label: String) {
    let n1 = oneX.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
    guard n1 > 0 else {
        #expect(Bool(false), Comment(rawValue: "\(label): the 1x replay drew nothing"))
        return
    }
    let w = MetalVram.nativeWidth, h = MetalVram.nativeHeight
    var perimeter = 0
    for y in 0..<h {
        for x in 0..<w where oneX[y * w + x] != 0 {
            let up = y == 0 || oneX[(y - 1) * w + x] == 0
            let down = y == h - 1 || oneX[(y + 1) * w + x] == 0
            let left = x == 0 || oneX[y * w + x - 1] == 0
            let right = x == w - 1 || oneX[y * w + x + 1] == 0
            if up || down || left || right { perimeter += 1 }
        }
    }
    let nN = f.scaled.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
    let expected = Double(n1 * f.scale * f.scale)
    let ratio = Double(nN) / expected
    print("[gate-2b] \(label): n1=\(n1) perimeter=\(perimeter) nN=\(nN) ratio=\(String(format: "%.4f", ratio))")
    #expect(ratio >= 0.6 && ratio <= 1.6,
            Comment(rawValue: "\(label): coverage ratio \(ratio) outside [0.6, 1.6]"))
}

/// Gate 2b runs at these scales only. The bounds half allocates and scans one
/// Bool per scaled pixel, which is 33.5M at scale 8 — for three frames on
/// every run of the suite. Scale 8's bounds are covered instead by
/// `theDrawingAreaClipScalesAsAnInclusiveBound` (the specific off-by-one this
/// gate exists for) and by Gate 2 at scale 8 in Task 6.
private let gate2bScales = [2, 3, 4]

@Test func theDrawingAreaClipScalesAsAnInclusiveBound() throws {
    // The native drawing area is INCLUSIVE, so the scaled test is
    // `px > (x1 + 1) * s - 1`, not `px > x1 * s`. The two agree at every
    // top-left subtexel — which is exactly the set Gate 1 and Gate 2 compare —
    // so neither can see the difference; the wrong form silently drops the
    // last (s - 1) columns and rows of every clipped primitive.
    //
    // A flat rectangle is the subject because it is covered by construction:
    // no edge function participates, so the extent of what lands in VRAM is
    // decided by the clip and by nothing else.
    let scale = 4
    guard let f = try MetalScaleHarness.frame(scale: scale, { r in
        func env(_ op: UInt8, _ v: UInt32) -> Ps1GpuCommand {
            var c = Ps1GpuCommand()
            c.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
            c.opcode = op
            c.value = v
            return c
        }
        r.apply(env(0xE3, (100 << 10) | 100))   // top-left  (100, 100)
        r.apply(env(0xE4, (130 << 10) | 140))   // bottom-right (140, 130), INCLUSIVE

        var rect = Ps1GpuCommand()
        rect.kind = UInt8(PS1_GPU_DRAW_RECTANGLE.rawValue)
        rect.x = 90; rect.y = 90; rect.w = 80; rect.h = 80   // overflows all four sides
        rect.value = 0x7FFF
        r.apply(rect)
    }) else { return }

    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    for y in 0..<f.height {
        for x in 0..<f.width where f.scaled[y * f.width + x] != 0 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    #expect(minX == 100 * scale)          // 400
    #expect(maxX == (140 + 1) * scale - 1) // 563, NOT 140 * 4 == 560
    #expect(minY == 100 * scale)          // 400
    #expect(maxY == (130 + 1) * scale - 1) // 523, NOT 130 * 4 == 520
}

@Test func aFullVramGouraudTriangleDoesNotOverflowTheInterpolator() throws {
    // ps1_interp's numerator is bounded by area * 255, and BOTH the weights
    // and the area scale by s^2. An oversized-capped primitive reaches about
    // 2.13e9 at s = 4 — 1% under int32's ceiling — and goes over it at s = 5.
    // This triangle is 1022 x 510, the largest the oversized refusal admits,
    // with the full 0..255 colour range, so a shader that kept `int`
    // intermediates wraps here and nowhere else in the corpus.
    func draw(_ r: MetalRasterizer) {
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)

        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
        tri.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0x00FF_FFFF)
        tri.v.1 = Ps1GpuVertex(x: 1022, y: 0, u: 0, v: 0, _pad: 0, color: 0x0000_00FF)
        tri.v.2 = Ps1GpuVertex(x: 0, y: 510, u: 0, v: 0, _pad: 0, color: 0x00FF_0000)
        r.apply(tri)
    }

    guard let one = try MetalScaleHarness.frame(scale: 1, draw) else { return }
    for scale in [4, 8] {
        guard let many = try MetalScaleHarness.frame(scale: scale, draw) else { return }
        #expect(many.native == one.native, "scale \(scale)")
    }
}

// MARK: - Gate 2: downsample-invariance, untextured

/// The three PL ROMs that draw without sampling: 18 flat + 6 Gouraud
/// triangles, 18 rectangles, and 60 mono + 20 shaded lines. `pl-hello-world`
/// and `pl-cpu-add` are NOT here — measured, they carry zero draw records and
/// are pure GP0(A0) upload fixtures, so they gate at Task 5.
private let untexturedPlFixtures = ["pl-render-polygon", "pl-render-rectangle", "pl-render-line"]

@Test(.enabled(if: untexturedPlFixtures.contains(where: generatedFixtureExists),
               "pl-*.p1fx are build artifacts — run `zig build fixtures -Doptimize=ReleaseFast`"))
func theUntexturedPeterLemonRomsAreDownsampleInvariant() throws {
    var checked = 0
    for name in untexturedPlFixtures {
        guard generatedFixtureExists(name) else { continue }
        for scale in scaleLadder {
            guard let d = try MetalScaleHarness.compare(name, scale: scale) else { continue }
            #expect(Bool(false), Comment(rawValue: "\(name) @\(scale)x: \(d.message)"))
        }
        checked += 1
    }
    #expect(checked > 0)
}

@Test func theUntexturedSyntheticFramesAreDownsampleInvariant() throws {
    // Frames 0 and 1 are flat and Gouraud triangles and can be replayed
    // cumulatively. Frame 2 uploads three texture pages and a CLUT, so the
    // cumulative replay stops before it: uploads scale in Task 5.
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("synthetic-primitives", scale: scale, upTo: 2)
        else { continue }
        #expect(Bool(false), Comment(rawValue: "synthetic-primitives @\(scale)x: \(d.message)"))
    }

    // Frames 3 (rectangles) and 5 (lines) each open with their own E3/E4/E5,
    // so a from-blank single-frame replay of either is well defined and skips
    // the upload frames between them.
    for frame in [3, 5] {
        guard let one = try MetalScaleHarness.fixtureFrame("synthetic-primitives",
                                                           frame: frame, scale: 1) else { return }
        for scale in scaleLadder {
            guard let many = try MetalScaleHarness.fixtureFrame("synthetic-primitives",
                                                                frame: frame, scale: scale)
            else { return }
            #expect(many.native == one.native, "frame \(frame) @\(scale)x")
        }
    }
}

@Test func theUntexturedSyntheticFramesRespectTheirScaledBoxesAndCoverTheirBlocks() throws {
    // Gate 2 constrains only the top-left subtexel of each block, so a bug
    // that left every other subpixel black would pass it and look
    // catastrophic. This is what catches that mechanically.
    for frame in [0, 3, 5] {
        guard let one = try MetalScaleHarness.fixtureFrame("synthetic-primitives",
                                                           frame: frame, scale: 1) else { return }
        for scale in gate2bScales {
            guard let f = try MetalScaleHarness.fixtureFrame("synthetic-primitives",
                                                             frame: frame, scale: scale)
            else { return }
            assertNothingOutsideTheScaledBoxes(f, "frame \(frame) @\(scale)x")
            assertCoverageDensity(oneX: one.native, f, "frame \(frame) @\(scale)x")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: **compile failure** first (`MetalScaleHarness` has no `fixtureFrame` or `compare`). After Step 3 adds them and before Steps 4–5 change the shader, the same run fails on assertions instead: the clip test reports `maxX == 560`-style values or nothing drawn at all, and every invariance check reports a mismatch, because the fragment shader is still reading `px`/`py` as native coordinates.

- [ ] **Step 3: Add the two harness entry points**

Append to `MetalScaleHarness`:

```swift
    /// One fixture frame, replayed from a BLANK VRAM.
    ///
    /// Not equivalent to the cumulative replay `compare` runs — a frame that
    /// depends on an earlier frame's VRAM or drawing environment will differ.
    /// It is used only on frames that open with their own E3/E4/E5 and sample
    /// nothing, which is what lets Gate 2b index into the middle of a fixture
    /// without dragging the upload frames along.
    static func fixtureFrame(_ name: String, frame i: Int, scale: Int) throws -> Frame? {
        let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        return try withExtendedLifetime(file) {
            let payload = Array(file.payload(for: i))
            return try frame(scale: scale, payload: payload) { r in
                for cmd in file.records(for: i) { r.apply(cmd) }
            }
        }
    }

    struct Divergence {
        let frame: Int
        let message: String
    }

    /// Gate 2. The same fixture replayed cumulatively at 1x and at `scale`,
    /// dithering forced off on both sides, compared per frame on the NATIVE
    /// view. Returns the first frame that disagrees, or nil if every frame
    /// agreed — or if there is no Metal device.
    ///
    /// The reference side is the backend's own 1x output, NOT the fixture's
    /// Zig hash: that comparison is Gate 1's job and it runs with dithering
    /// on, where it belongs.
    static func compare(_ name: String, scale: Int, upTo: Int? = nil) throws -> Divergence? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let oneVram = MetalVram(device: device, queue: queue, scale: 1),
              let manyVram = MetalVram(device: device, queue: queue, scale: scale)
        else { return nil }
        let one = try MetalRasterizer(vram: oneVram)
        let many = try MetalRasterizer(vram: manyVram)
        one.ditherDisabled = true
        many.ditherDisabled = true

        let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        let count = min(upTo ?? file.frames.count, file.frames.count)
        var out: Divergence?
        withExtendedLifetime(file) {
            for i in 0..<count {
                let payload = file.payload(for: i)
                for r in [one, many] {
                    r.beginFrame(payload: payload)
                    for cmd in file.records(for: i) { r.apply(cmd) }
                    r.endFrame()
                }
                guard oneVram.hash != manyVram.nativeHash else { continue }
                let want = oneVram.readback()
                let got = manyVram.readbackNative()
                let diffs = VramDump.firstDifferences(want, got, limit: 6)
                let total = zip(want, got).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
                let lines = diffs.map {
                    String(format: "  (%4d,%4d) 1x %04X %dx %04X", $0.x, $0.y, $0.want, scale, $0.got)
                }
                out = Divergence(frame: i,
                                 message: "frame \(i): \(total) native px differ\n"
                                     + lines.joined(separator: "\n"))
                return
            }
        }
        return out
    }
```

- [ ] **Step 4: Widen `ps1_interp` to 64-bit**

In `ps1-macos/Shaders/Ps1Color.h`, replace `ps1_interp` and its doc comment:

```metal
/// Exact barycentric interpolation of one integer attribute.
///
/// `renderer.zig:82-90` does this in i64 because the EXPANDED plane equation's
/// constant term exceeds i32. Nothing is expanded here — the weights are
/// evaluated at the pixel — but at internal resolution s BOTH the weights and
/// the area scale by s^2, so the numerator, bounded by area * 255, does too.
/// An oversized-capped primitive (1023 x 511) reaches about 2.13e9 at s = 4,
/// roughly 1% under int32's ceiling, and passes it at s = 5. The intermediate
/// is therefore `long`: the supported scale range should be decided by what
/// looks good, not by where an overflow lands.
///
/// The DIVISION is still exact and still scale-invariant: numerator and
/// denominator both carry the same s^2 factor, and integer division satisfies
/// floor(s^2*num / s^2*den) == floor(num/den). Plain `/` rather than a floor
/// because on a covered pixel num >= 0 and area > 0, exactly as
/// `renderer.zig`'s own comment says.
inline int ps1_interp(int w0, int w1, int w2, int area, int a0, int a1, int a2) {
    long num = long(w0) * long(a0) + long(w1) * long(a1) + long(w2) * long(a2);
    return int(num / long(area));
}
```

`ps1_orient` stays `int` and needs no widening: the oversized refusal bounds every vertex to within 1024 columns and 512 rows of the visible box, so at s = 8 neither product exceeds about 1.0e8.

- [ ] **Step 5: Scale coverage, the clip and the dither decision**

In `ps1-macos/Shaders/Rasterizer.metal`, give `ps1_triangle_coverage` the scale (its doc comment is unchanged):

```metal
inline bool ps1_triangle_coverage(const device Ps1PrimInstance& p, int s, int px, int py,
                                  thread int& w0, thread int& w1, thread int& w2,
                                  thread int& area) {
    // The vertices are native; the sample point is already scaled. Multiplying
    // the vertices by s is what puts both in the same space — and it leaves
    // every sign unchanged at a top-left subtexel, where each edge function
    // becomes exactly s^2 times its native value.
    int ax = p.x0 * s, ay = p.y0 * s;
    int bx = p.x1 * s, by = p.y1 * s;
    int cx = p.x2 * s, cy = p.y2 * s;

    int area_signed = ps1_orient(ax, ay, bx, by, cx, cy);
    // Normalize to a positive area by flipping the sign of every edge function
    // rather than by swapping two vertices: a swap would permute the
    // attributes the shader indexes by vertex number.
    int sgn = area_signed < 0 ? -1 : 1;
    area = area_signed * sgn;

    // The fill rule reads only the SIGN of each edge delta, and s > 0, so the
    // scaled deltas classify identically to the native ones.
    int bias0 = ps1_top_left(sgn * (cx - bx), sgn * (cy - by)) ? -1 : 0;
    int bias1 = ps1_top_left(sgn * (ax - cx), sgn * (ay - cy)) ? -1 : 0;
    int bias2 = ps1_top_left(sgn * (bx - ax), sgn * (by - ay)) ? -1 : 0;

    int b0 = sgn * ps1_orient(bx, by, cx, cy, px, py) + bias0;
    int b1 = sgn * ps1_orient(cx, cy, ax, ay, px, py) + bias1;
    int b2 = sgn * ps1_orient(ax, ay, bx, by, px, py) + bias2;

    // Avocado's coverage test verbatim: a negative term sets the sign bit of
    // the OR, so this means "all three non-negative, and not all three zero".
    if ((b0 | b1 | b2) <= 0) return false;

    w0 = b0 - bias0;
    w1 = b1 - bias1;
    w2 = b2 - bias2;
    return true;
}
```

Note the rename `s` → `sgn` for the winding sign: `s` is the scale everywhere else in this file, and two meanings for one letter in the one function that uses both is how an off-by-a-factor-of-s survives review.

Then, in `ps1_prim_fragment`, add the uniform parameter and the native-coordinate recovery at the top:

```metal
fragment ushort ps1_prim_fragment(PrimVertexOut in [[stage_in]],
                                  ushort dst [[color(0)]],
                                  const device Ps1PrimInstance* prims [[buffer(0)]],
                                  constant Ps1RasterUniforms& uni [[buffer(2)]],
                                  texture2d<ushort, access::read> vram [[texture(0)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int s = int(uni.scale);
    // [[position]] in a fragment shader is the pixel CENTRE (px+0.5, py+0.5),
    // so this truncation is exact.
    int px = int(in.position.x);
    int py = int(in.position.y);
    // The NATIVE pixel this subpixel belongs to. Every field of the record is
    // in native units, so anything indexed by a record — a transfer's pixel
    // index, a sprite's texcoord origin, a copy's source — uses these, never
    // px/py.
    int nx = px / s;
    int ny = py / s;

    // Dithering is decided HERE, not in PrimBuilder: clearing the flag on the
    // CPU would make the instance record differ between s == 1 and s > 1 and
    // forfeit the byte-identical-records property the phase rests on. It is
    // also the single exception to downsample-invariance, which is why it is
    // off above 1x at all.
    bool dither = (p.flags & PS1_PRIM_DITHER) && s == 1 && uni.dither_off == 0u;
```

Then, mechanically through the body:

- every `ps1_triangle_coverage(p, px, py, ...)` becomes `ps1_triangle_coverage(p, s, px, py, ...)` (three sites).
- both `if (p.flags & PS1_PRIM_DITHER) { int o = ps1_dither(px, py); ... }` blocks become `if (dither) { int o = ps1_dither(px, py); ... }` (the Gouraud arm and the shaded-line arm). `px`/`py` stay: `dither` is only ever true at `s == 1`, where `px == nx`.
- the `PS1_PRIM_TEXTURED_RECT` arm keeps `px`/`py` for now; Task 4 moves it to `nx`/`ny` together with the rest of the sampling path.
- the drawing-area clip becomes:

```metal
    // The native drawing area is INCLUSIVE, so the scaled right/bottom bound
    // is (x1 + 1) * s - 1, NOT x1 * s. The wrong form agrees with this one at
    // every top-left subtexel — `p*s > x1*s` and `p*s > (x1+1)*s - 1` are the
    // same predicate for integer p — so Gate 1 and Gate 2 both pass with it,
    // and it silently drops the last (s-1) columns and rows of every clipped
    // primitive. Gate 2b's clip test is what catches it.
    if (px < p.clip_x0 * s || px > (p.clip_x1 + 1) * s - 1 ||
        py < p.clip_y0 * s || py > (p.clip_y1 + 1) * s - 1) {
        discard_fragment();
        return 0;
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: whole suite green, `[gate-2b]` lines printed for nine frame/scale pairs. **If a Phase B fixture hash moved, stop and fix it here** — at `s == 1` every expression this task touched is arithmetically identical to what it replaced (`* 1`, `(x1+1)*1-1 == x1`), so a moved 1× hash means a transcription error, not a design question.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Shaders/Ps1Color.h ps1-macos/Shaders/Rasterizer.metal \
        ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift \
        ps1-macos/Tests/PS1Tests/MetalScaleTests.swift
git commit -m "$(cat <<'MSG'
feat(metal): coverage, interpolation and the clip at internal resolution

ps1_prim_fragment recovers nx/ny from the scaled sample point and scales
the triangle vertices and the drawing area at the point of use.
ps1_interp widens its intermediate to `long`: weights and area both grow
by s^2, so an oversized-capped primitive's numerator (area * 255) passes
int32 at s = 5 — the range is a design choice, not an overflow artifact.

The clip conversion is [x0*s, (x1+1)*s - 1], and the wrong form (x1*s)
is invisible to both existing gates: it agrees at every top-left
subtexel, which is the only set they compare. Hence a targeted test that
reads back the exact extent of a clipped rectangle at 4x.

Dithering is gated on scale == 1 in the shader rather than cleared in
PrimBuilder, so the instance bytes stay identical at every scale.

Gate 2 (downsample-invariance) now covers the three untextured PL ROMs
in full plus four frames of synthetic-primitives; Gate 2b covers bounds
and coverage density on three of them.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 4: The samplers at scale

Three reads move: the VRAM fetch (linearize natively, *then* scale), the texel fetch at all three depths, and the sprite path's 8-bit texcoord wrap. Nothing is upscaled — at scale N a texel at `(u, v)` reads the block's **top-left** subtexel, which is what today's code already does at N = 1 and what DuckStation's hardware renderer does at every N.

The spec's task table gates this on `pl-render-texture-polygon` and the geometry fixtures. Measured, that is not reachable here: `pl-render-texture-polygon` carries its texture in four GP0(A0) uploads **in the same frame** as the draws that sample it, and uploads scale in Task 5. It moves to Task 5, and this task gates instead on hand-built textured draws over a texture placed with `uploadNative` — earlier, sharper coverage of the same three shader paths — plus `tr1-usa-v1-1`, which the census shows carries no uploads and no copies at all.

**Files:**
- Modify: `ps1-macos/Shaders/Ps1Color.h` (`ps1_vram_read`, `ps1_fetch_texel`)
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_sample`, the two textured arms)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift` (a `preload:` parameter)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces:
  - `MetalScaleHarness.frame(scale:payload:preload:ditherDisabled:_:)` — `preload: [UInt16]? = nil`, a **native** 1024×512 image pushed through `uploadNative` before the frame runs. Every existing call site is unaffected (defaulted parameter).
  - Shader: `ps1_vram_read(vram, x, y, s)`, `ps1_fetch_texel(vram, s, depth, …)`, `ps1_sample(p, vram, s, u, v, px, py, dither)`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`:

```swift
// MARK: - Gate 2: the sampling paths

/// A native VRAM holding one texture page at each depth plus a CLUT, laid out
/// the way `synthetic_prims.zig` lays its own out: 4bpp at (0,0), 8bpp at
/// (128,0), 16bpp at (256,0), CLUT row at (0,240). Entry 0 of the CLUT is
/// deliberately 0 — a texel of 0 is a HOLE, discarded rather than drawn.
private func texturedVram() -> [UInt16] {
    var v = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for i in 0..<256 {
        v[240 * MetalVram.nativeWidth + i] = i == 0 ? 0 : UInt16(truncatingIfNeeded: i &* 0x0123)
    }
    for y in 0..<64 {
        for x in 0..<64 {
            let row = y * MetalVram.nativeWidth
            v[row + x] = UInt16(truncatingIfNeeded: (x &+ y) &* 0x1111 &+ 0x1234)
            v[row + 128 + x] = UInt16(truncatingIfNeeded: (x &* 7 &+ y) &* 0x0303 &+ 0x0A1B)
            // 16bpp texels must not be zero anywhere, or the hole discard
            // hides the comparison instead of making it.
            v[row + 256 + x] = UInt16(truncatingIfNeeded: (x &+ y &* 64) &| 0x0421)
        }
    }
    return v
}

@Test func texturedTrianglesAreDownsampleInvariantAtAllThreeDepths() throws {
    // tpage bits: low 4 are the page X in 64-pixel units, bit 4 the page Y,
    // bits 7-8 the depth. Pages at x = 0 / 128 / 256 are units 0 / 2 / 4.
    let pages: [(String, UInt16)] = [("4bpp", 0x0000), ("8bpp", 0x0082), ("16bpp", 0x0104)]
    let clut: UInt16 = UInt16(0) | (240 << 6)   // clut_x = 0, clut_y = 240

    for (label, tpage) in pages {
        func draw(_ r: MetalRasterizer) {
            var env = Ps1GpuCommand()
            env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
            env.opcode = 0xE4
            env.value = (511 << 10) | 1023
            r.apply(env)

            var tri = Ps1GpuCommand()
            tri.kind = UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue)
            tri.opcode = 0x25            // bit 0 SET: raw, no modulation
            tri.tpage = tpage
            tri.clut = clut
            // Destination well clear of the pages this samples, so the draw
            // cannot feed itself.
            tri.v.0 = Ps1GpuVertex(x: 400, y: 300, u: 0, v: 0, _pad: 0, color: 0)
            tri.v.1 = Ps1GpuVertex(x: 460, y: 305, u: 60, v: 4, _pad: 0, color: 0)
            tri.v.2 = Ps1GpuVertex(x: 405, y: 360, u: 2, v: 58, _pad: 0, color: 0)
            r.apply(tri)
        }

        let vram = texturedVram()
        guard let one = try MetalScaleHarness.frame(scale: 1, preload: vram, draw) else { return }
        // The draw must actually paint, or "invariant" is a statement about
        // two blank images.
        #expect(one.native.filter { $0 != 0 }.count > 500, "\(label) drew nothing")

        for scale in scaleLadder {
            guard let many = try MetalScaleHarness.frame(scale: scale, preload: vram, draw)
            else { return }
            #expect(many.native == one.native, "\(label) @\(scale)x")
        }
    }
}

@Test func aSpriteWrapsItsTexcoordsInEightBitsAtEveryScale() throws {
    // `tu +% @truncate(xx)` on u8 is a WRAP, and it is in TEXEL units: it must
    // be computed from the native pixel, never from the subpixel. Computed
    // from px, an 8x sprite would wrap every 32 output pixels instead of every
    // 256 texels.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for u in 0..<256 { vram[256 + u] = UInt16(0x0100 + u) }

    func draw(_ r: MetalRasterizer) {
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)

        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = 0x65                 // RAW: no modulation
        spr.tpage = 0x0104                // page x 4 (-> 256), 16bpp
        spr.x = 0; spr.y = 300; spr.w = 8; spr.h = 1
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 252, v: 0, _pad: 0, color: 0)
        r.apply(spr)
    }

    let scale = 3
    guard let one = try MetalScaleHarness.frame(scale: 1, preload: vram, draw),
          let many = try MetalScaleHarness.frame(scale: scale, preload: vram, draw) else { return }

    let row = 300 * MetalVram.nativeWidth
    #expect(one.native[row + 3] == 0x01FF)   // u = 255
    #expect(one.native[row + 4] == 0x0100)   // u wrapped to 0 — a clamp would repeat 0x01FF
    #expect(many.native == one.native)

    // And texture data is NEVER upscaled: each native output pixel is a solid
    // s x s block of one texel, not a window into a finer texture.
    for x in 0..<8 {
        let want = one.native[row + x]
        for sy in 0..<scale {
            for sx in 0..<scale {
                let i = (300 * scale + sy) * many.width + (x * scale + sx)
                #expect(many.scaled[i] == want, "sprite texel \(x) subpixel (\(sx),\(sy))")
            }
        }
    }
}

@Test func aClutIndexPastTheRowEndReadsIntoTheNextRowAtEveryScale() throws {
    // `Vram.index(x, y)` is `y * 1024 + x` with NO masking, so a CLUT whose
    // clut_x + index runs past 1023 reads into the NEXT ROW. That linearize
    // must happen in NATIVE space and only then be scaled: linearizing at
    // scale (`y*1024*s + x*s`) invents a different wrap, and no fixture in the
    // corpus exercises the case.
    //
    // 8bpp page at (256, 0) whose texel 0 is index 20, CLUT at x = 1008:
    // 1008 + 20 = 1028, past the row end, so the read lands at
    // (1028 - 1024, 100 + 1) = (4, 101).
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    vram[0 * MetalVram.nativeWidth + 256] = 0x0014          // idx 20 in the low byte
    vram[100 * MetalVram.nativeWidth + 4] = 0x5678          // the SAME-ROW answer
    vram[101 * MetalVram.nativeWidth + 4] = 0x1234          // the correct one

    func draw(_ r: MetalRasterizer) {
        var env = Ps1GpuCommand()
        env.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        env.opcode = 0xE4
        env.value = (511 << 10) | 1023
        r.apply(env)

        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = 0x65                                   // RAW
        spr.tpage = 0x0084                                  // page x 4 (-> 256), 8bpp
        spr.clut = UInt16(63) | (100 << 6)                  // clut_x = 1008, clut_y = 100
        spr.x = 10; spr.y = 300; spr.w = 1; spr.h = 1
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        r.apply(spr)
    }

    for scale in [1] + scaleLadder {
        guard let f = try MetalScaleHarness.frame(scale: scale, preload: vram, draw) else { return }
        #expect(f.native[300 * MetalVram.nativeWidth + 10] == 0x1234, "scale \(scale)")
    }
}

@Test(.enabled(if: generatedFixtureExists("tr1-usa-v1-1"),
               "geometry fixtures are generated from games/ — run `zig build fixtures -Doptimize=ReleaseFast`"))
func theTombRaiderFixtureIsDownsampleInvariant() throws {
    // 12,440 textured triangles, 979 textured rectangles and 50 fills over 100
    // frames of real gameplay — and, measured, zero uploads and zero copies,
    // which is what makes it the one geometry fixture reachable at this task.
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("tr1-usa-v1-1", scale: scale) else { continue }
        #expect(Bool(false), Comment(rawValue: "tr1-usa-v1-1 @\(scale)x: \(d.message)"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: a compile failure on the `preload:` argument first; after Step 3, assertion failures on every scaled comparison — the fragment shader is still fetching texels at native coordinates out of a texture that is N× the size, so a scaled draw samples the top-left 1/N² corner of VRAM.

- [ ] **Step 3: Let the harness preload a native VRAM**

In `MetalScaleHarness.frame`, add the parameter and the upload:

```swift
    static func frame(scale: Int, payload: [UInt32] = [], preload: [UInt16]? = nil,
                      ditherDisabled: Bool = true,
                      _ body: (MetalRasterizer) -> Void) throws -> Frame? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
        // A NATIVE image, replicated N x N — the state a 1x replay would have
        // reached, expressed at this scale. Uploading it any other way would
        // seed a difference the comparison would then attribute to the shader.
        if let preload { vram.uploadNative(preload) }
        let r = try MetalRasterizer(vram: vram)
        ...
```

- [ ] **Step 4: Linearize natively, then scale**

In `ps1-macos/Shaders/Ps1Color.h`, replace `ps1_vram_read`'s signature and body (its long doc comment about the row-crossing and the `& 0x7FFFF` bound stays, with the paragraph below appended):

```metal
/// At internal resolution the LINEARIZE STAYS NATIVE and only the resulting
/// 2D address is scaled. `y * 1024 + x` reproduces `Vram.index`, which does no
/// masking; doing the same arithmetic in scaled units would invent a different
/// wrap — a row would be 1024*s wide and an overflowing CLUT would land
/// somewhere else entirely. The scaled read then takes the block's TOP-LEFT
/// subtexel, which is the whole of "texture data is never upscaled".
inline ushort ps1_vram_read(texture2d<ushort, access::read> vram,
                            uint x, uint y, uint s) {
    uint lin = (y * 1024u + x) & 0x7FFFFu;
    return vram.read(uint2((lin & 1023u) * s, (lin >> 10) * s)).r;
}
```

and thread the scale through `ps1_fetch_texel`, whose body is otherwise unchanged:

```metal
inline ushort ps1_fetch_texel(texture2d<ushort, access::read> vram, uint s, uint depth,
                              uint tpage_x, uint tpage_y,
                              uint clut_x, uint clut_y, uint u, uint v) {
    uint py = tpage_y + v;
    if (depth == 0u) {
        ushort word = ps1_vram_read(vram, tpage_x + (u >> 2), py, s);
        uint idx = (uint(word) >> ((u & 3u) * 4u)) & 0xFu;
        return ps1_vram_read(vram, clut_x + idx, clut_y, s);
    }
    if (depth == 1u) {
        ushort word = ps1_vram_read(vram, tpage_x + (u >> 1), py, s);
        uint idx = (uint(word) >> ((u & 1u) * 8u)) & 0xFFu;
        return ps1_vram_read(vram, clut_x + idx, clut_y, s);
    }
    return ps1_vram_read(vram, tpage_x + u, py, s);
}
```

Every coordinate reaching these two functions is a **native texel address**: `tpage_x`, `tpage_y`, `clut_x`, `clut_y` come straight out of the instance record, and `u`/`v` are 8-bit texel indices. None of them is ever pre-multiplied by `s`.

- [ ] **Step 5: Give `ps1_sample` the scale and the dither decision**

In `ps1-macos/Shaders/Rasterizer.metal`:

```metal
inline ushort ps1_sample(const device Ps1PrimInstance& p,
                         texture2d<ushort, access::read> vram, uint s,
                         uint u, uint v, int px, int py, bool dither) {
    uint mask_x   = (p.tex_window & 0x1Fu) * 8u;
    uint mask_y   = ((p.tex_window >> 5) & 0x1Fu) * 8u;
    uint offset_x = ((p.tex_window >> 10) & 0x1Fu) * 8u;
    uint offset_y = ((p.tex_window >> 15) & 0x1Fu) * 8u;

    // The texture window is in TEXEL units, like u and v — nothing here scales.
    uint final_u = (u & ~mask_x) | (offset_x & mask_x);
    uint final_v = (v & ~mask_y) | (offset_y & mask_y);

    ushort texel = ps1_fetch_texel(vram, s, p.tex_depth, p.tpage_x, p.tpage_y,
                                   p.clut_x, p.clut_y, final_u, final_v);
    if (texel == 0) return 0;
    if (p.flags & PS1_PRIM_MODULATE) {
        return ps1_modulate(texel, ushort(p.color), px, py, dither);
    }
    return texel;
}
```

In the textured-triangle arm, the interpolated `u`/`v` are already native texel indices (Task 3's `ps1_interp` is scale-invariant in value at a top-left subtexel and is genuine supersampling elsewhere), so only the call changes:

```metal
        src = ps1_sample(p, vram, uint(s), u, v, px, py, dither);
```

In the textured-rectangle arm, the origin is a native pixel and the wrap is in texel units, so both come off `nx`/`ny`:

```metal
    } else if (p.kind == PS1_PRIM_TEXTURED_RECT) {
        // `tu +% @truncate(xx)` on u8 — a WRAP, not the triangle path's
        // interpolate-and-clamp. This is why the sprite path is a separate
        // shader path rather than a special case of the triangle one. It is
        // computed from the NATIVE pixel: the wrap is in texel units and has
        // nothing to do with internal resolution.
        uint u = uint((nx - p.x0) + p.u0) & 0xFFu;
        uint v = uint((ny - p.y0) + p.v0) & 0xFFu;
        src = ps1_sample(p, vram, uint(s), u, v, px, py, dither);
        if (src == 0u) { discard_fragment(); return 0; }
        transparent = transparent && (src & 0x8000) != 0;
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: whole suite green. `theTombRaiderFixtureIsDownsampleInvariant` runs 4 × 100 frames and is the slowest test in the file so far; if it is absent the suite says so through the `.enabled(if:)` trait rather than passing silently.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Shaders/Ps1Color.h ps1-macos/Shaders/Rasterizer.metal \
        ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift \
        ps1-macos/Tests/PS1Tests/MetalScaleTests.swift
git commit -m "$(cat <<'MSG'
feat(metal): the sampling paths at internal resolution

ps1_vram_read linearizes y*1024+x in NATIVE space and scales only the
resulting 2D address, so the CLUT row-crossing that reproduces Vram.index
survives unchanged; linearizing in scaled units would invent a different
wrap. ps1_fetch_texel and ps1_sample thread the scale through, and a
textured rectangle's 8-bit texcoord wrap is computed from the native
pixel, since it is in texel units.

Texture data is never upscaled: a texel at (u,v) reads the block's
top-left subtexel at every depth. The parent spec's "render-to-texture
sampled at scale" checklist item is struck (Phase C spec, § What the
parent spec got wrong) — it contradicts that rule, and sampling a CLUT
index at a sub-position is not a meaningful operation.

Gated on hand-built draws at all three depths over an uploadNative-placed
texture, the CLUT row-crossing case (which no fixture covers), and
tr1-usa-v1-1 in full: 100 frames, 12,440 textured triangles, 979 sprites,
and — measured — no uploads or copies, which is what makes it reachable
before the movers scale.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 5: The movers at scale

Fill was finished by Task 2. Upload maps each subpixel back to the payload word through its **native** index, so N×N replication falls out with no replication code. Copy is the one mover that carries the subpixel offset — the destination wrap stays native while the source read is `scratch[((src_x + xx) & 0x3FF) * s + sub_x, …]`, so a VRAM→VRAM blit **preserves scaled detail** instead of flattening it. At a top-left subtexel `sub_x == sub_y == 0`, so that term vanishes and exactness is unaffected: it is exactly the term the exactness proof needs to disappear and the picture needs to be there.

After this task the whole corpus is reachable, and every remaining fixture joins Gate 2.

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_upload_fragment`, `ps1_copy_fragment`)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–4. `MetalRasterizer`'s scratch texture is already scaled (Task 1) and the snapshot blit already covers the scaled size.
- Produces: no new Swift symbol. Both mover fragment shaders take `constant Ps1RasterUniforms& uni [[buffer(2)]]`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`:

```swift
// MARK: - Gate 2: the memory movers

@Test func anUploadReplicatesEachPayloadPixelIntoAnNbyNBlock() throws {
    // Every subpixel of a block resolves to the same payload word, because
    // `pix` is computed from the NATIVE pixel. There is no replication code
    // and there must not be any: a second path would be a second thing to get
    // wrong at the one place where the CPU's bytes enter VRAM.
    let words: [UInt32] = [0xBBBB_AAAA, 0xDDDD_CCCC]   // 4 pixels, 2x2
    func upload(_ r: MetalRasterizer) {
        var setup = Ps1GpuCommand()
        setup.kind = UInt8(PS1_GPU_VRAM_WRITE_SETUP.rawValue)
        setup.x = 40; setup.y = 50; setup.w = 2; setup.h = 2
        r.apply(setup)

        var data = Ps1GpuCommand()
        data.kind = UInt8(PS1_GPU_VRAM_WRITE_DATA.rawValue)
        data.x = 0; data.y = 2         // off, len — in WORDS
        r.apply(data)
    }

    let scale = 3
    guard let one = try MetalScaleHarness.frame(scale: 1, payload: words, upload),
          let many = try MetalScaleHarness.frame(scale: scale, payload: words, upload)
    else { return }

    let w = MetalVram.nativeWidth
    #expect(one.native[50 * w + 40] == 0xAAAA)
    #expect(one.native[50 * w + 41] == 0xBBBB)
    #expect(one.native[51 * w + 40] == 0xCCCC)
    #expect(one.native[51 * w + 41] == 0xDDDD)
    #expect(many.native == one.native)

    for (nx, ny, want) in [(40, 50, UInt16(0xAAAA)), (41, 50, 0xBBBB),
                           (40, 51, 0xCCCC), (41, 51, 0xDDDD)] {
        for sy in 0..<scale {
            for sx in 0..<scale {
                let i = (ny * scale + sy) * many.width + (nx * scale + sx)
                #expect(many.scaled[i] == want, "block (\(nx),\(ny)) subpixel (\(sx),\(sy))")
            }
        }
    }
}

@Test func aCopyPreservesScaledDetailRatherThanReplicatingTheNativePixel() throws {
    // The ONE mover that reads the scaled source. Its destination wrap is
    // native — the encoder has already split the rect into up to four boxes on
    // that basis — but the source read carries sub_x/sub_y, so content a game
    // moves around VRAM stays sharp instead of being flattened to its blocks'
    // top-left subtexels. Dropping those two terms still passes Gate 2, since
    // they are zero at every top-left subtexel; this is what catches it.
    let scale = 2
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: scale) else { return }
    let r = try MetalRasterizer(vram: vram)

    // A scaled source with a DIFFERENT value in every subpixel of every block.
    var scaled = [UInt16](repeating: 0, count: vram.pixelCount)
    for y in 0..<(4 * scale) {
        for x in 0..<(4 * scale) { scaled[y * vram.width + x] = UInt16(0x0100 + y * 16 + x) }
    }
    vram.upload(scaled)

    var copy = Ps1GpuCommand()
    copy.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    copy.x = 0; copy.y = 0            // source origin
    copy.x2 = 100; copy.y2 = 200      // destination origin
    copy.w = 4; copy.h = 4
    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(copy)
    r.endFrame()

    let out = vram.readback()
    for y in 0..<(4 * scale) {
        for x in 0..<(4 * scale) {
            let want = scaled[y * vram.width + x]
            let got = out[(200 * scale + y) * vram.width + (100 * scale + x)]
            #expect(got == want, "subpixel (\(x),\(y)): a replicating copy gives the block's top-left")
        }
    }
}

@Test func theWholeSyntheticPrimitivesFixtureIsDownsampleInvariant() throws {
    // All seven frames now, including 2 and 4 (uploads feeding textured draws
    // in the same frame) and 6 (the feedback loop: a draw sampling a page this
    // very frame drew into, which is what makes pass splitting load-bearing).
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("synthetic-primitives", scale: scale)
        else { continue }
        #expect(Bool(false), Comment(rawValue: "synthetic-primitives @\(scale)x: \(d.message)"))
    }
}

@Test func theCommittedMoverFixtureIsDownsampleInvariant() throws {
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("synthetic-movers", scale: scale) else { continue }
        #expect(Bool(false), Comment(rawValue: "synthetic-movers @\(scale)x: \(d.message)"))
    }
}

/// The three generated fixtures whose content is movers: 26 and 432 uploads
/// with zero draw records, and 1,014 uploads at real FMV payload sizes.
/// `pl-render-texture-polygon` is here rather than with the textured tests
/// because its texture ARRIVES by upload, in the same frame as the 48
/// triangles that sample it.
private let moverFixtures = ["pl-hello-world", "pl-cpu-add",
                             "pl-render-texture-polygon", "croc-legend-of-the-gobbos"]

@Test(.enabled(if: moverFixtures.contains(where: generatedFixtureExists),
               "generated fixtures are absent — run `zig build fixtures -Doptimize=ReleaseFast`"))
func theMoverFixturesAreDownsampleInvariant() throws {
    var checked = 0
    for name in moverFixtures {
        guard generatedFixtureExists(name) else { continue }
        checked += 1
        for scale in scaleLadder {
            guard let d = try MetalScaleHarness.compare(name, scale: scale) else { continue }
            #expect(Bool(false), Comment(rawValue: "\(name) @\(scale)x: \(d.message)"))
        }
    }
    #expect(checked > 0)
}

@Test(.enabled(if: generatedFixtureExists("silent-hill-usa"),
               "geometry fixtures are generated from games/ — run `zig build fixtures -Doptimize=ReleaseFast`"))
func theSilentHillFixtureIsDownsampleInvariant() throws {
    // 100 frames of real gameplay: 55,793 textured triangles, 28,120 Gouraud
    // triangles, 132 sprites, 100 copies and 50 fills. The copies are why it
    // waits for this task.
    for scale in scaleLadder {
        guard let d = try MetalScaleHarness.compare("silent-hill-usa", scale: scale) else { continue }
        #expect(Bool(false), Comment(rawValue: "silent-hill-usa @\(scale)x: \(d.message)"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: the new tests fail on assertions. The upload one reports the payload landing in the top-left corner of each destination block instead of filling it; the copy one reports every subpixel equal to its block's top-left; the fixture comparisons report large native pixel counts differing.

- [ ] **Step 3: Map an upload back through its native pixel index**

In `ps1-macos/Shaders/Rasterizer.metal`:

```metal
fragment ushort ps1_upload_fragment(PrimVertexOut in [[stage_in]],
                                    ushort dst [[color(0)]],
                                    const device Ps1PrimInstance* prims [[buffer(0)]],
                                    constant Ps1RasterUniforms& uni [[buffer(2)]],
                                    const device uint* words [[buffer(1)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int s = int(uni.scale);
    int nx = int(in.position.x) / s;
    int ny = int(in.position.y) / s;

    // The box spans whole rows, so the first and last rows of a run are
    // partial and are trimmed here rather than by more instances.
    //
    // `pix` is a NATIVE pixel index into the transfer, so every subpixel of a
    // block resolves to the same payload word and the N x N replication falls
    // out. There is no replication code, deliberately.
    int pix = (ny - p.y0) * p.w + (nx - p.x0);
    if (pix < p.pixel_first || pix > p.pixel_last) { discard_fragment(); return 0; }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return 0; }

    uint word = words[p.word_base + (pix >> 1)];
    ushort v = ushort((pix & 1) ? (word >> 16) : word);
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    return v;
}
```

- [ ] **Step 4: Carry the subpixel offset through the copy**

```metal
fragment ushort ps1_copy_fragment(PrimVertexOut in [[stage_in]],
                                  ushort dst [[color(0)]],
                                  const device Ps1PrimInstance* prims [[buffer(0)]],
                                  constant Ps1RasterUniforms& uni [[buffer(2)]],
                                  texture2d<ushort, access::read> scratch [[texture(0)]]) {
    const device Ps1PrimInstance& p = prims[in.iid];
    int s = int(uni.scale);
    int px = int(in.position.x);
    int py = int(in.position.y);
    int nx = px / s, ny = py / s;
    int sub_x = px % s, sub_y = py % s;

    // The destination wraps, so the encoder splits it into up to four boxes
    // and this recovers the in-rect offset by the same modular arithmetic —
    // in NATIVE units, which is the space the encoder split in.
    int xx = (nx - p.x0) & 0x3FF;
    int yy = (ny - p.y0) & 0x1FF;
    if (xx >= p.w || yy >= p.h) { discard_fragment(); return 0; }
    if ((p.flags & PS1_PRIM_CHECK_MASK) && (dst & 0x8000)) { discard_fragment(); return 0; }

    // The ONE read in this backend that is not reduced to native. The source
    // address is native and wrapping; the subpixel offset is added after the
    // scale, so a blit MOVES scaled detail rather than flattening it to each
    // block's top-left subtexel. At a top-left subtexel both offsets are 0, so
    // the exactness property is untouched — which is exactly why a shader that
    // dropped them would still pass Gate 2.
    ushort v = scratch.read(uint2(uint(((p.src_x + xx) & 0x3FF) * s + sub_x),
                                  uint(((p.src_y + yy) & 0x1FF) * s + sub_y))).r;
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    return v;
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
zig build metallib && ps1-macos/test.sh 2>&1 | tail -60
```
Expected: whole suite green. This is the first run where every fixture in the corpus is under Gate 2 at four scales, so it is also the first run long enough to be worth timing — note the wall clock, Task 6 needs it.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Shaders/Rasterizer.metal ps1-macos/Tests/PS1Tests/MetalScaleTests.swift
git commit -m "$(cat <<'MSG'
feat(metal): the memory movers at internal resolution

Upload maps each subpixel back to its payload word through the NATIVE
pixel index, so N x N replication falls out with no replication code.
Copy keeps its destination wrap native — the encoder split the rect in
that space — while the source read adds sub_x/sub_y after the scale, so a
VRAM->VRAM blit preserves scaled detail instead of flattening it. Those
two terms are zero at every top-left subtexel, so a shader that dropped
them would still pass Gate 2; the new copy test is what catches it.

Every fixture in the corpus is now under Gate 2: synthetic-primitives in
full (including the feedback frame), synthetic-movers, pl-hello-world,
pl-cpu-add, pl-render-texture-polygon, croc and silent-hill-usa.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Task 6: Images, cost, and the corpus sweep

Gates 3 and 4 are the two that need a human to read them, plus the one decision this plan deliberately left to a measurement: whether the N=8 sweep over the two 100-frame geometry fixtures is cheap enough to run habitually.

**Files:**
- Create: `ps1-macos/Sources/PS1/VramImage.swift`
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift` (`replayTo`)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`
- Modify: `ps1-macos/Tests/PS1Tests/MetalVramTests.swift` (the `VramImage` round trip)
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces:
  - `VramImage.write(_ pixels: [UInt16], width: Int, height: Int, to url: URL) -> Bool`
  - `VramImage.url(fixture: String, frame: Int, scale: Int) -> URL`
  - `MetalScaleHarness.replayTo(_ name: String, frame: Int, scale: Int, ditherDisabled: Bool) throws -> Frame?`
  - `corpusScales: [Int]` in `MetalScaleTests.swift`, if Step 3's measurement calls for it.

- [ ] **Step 1: Write the failing `VramImage` test**

Append to `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`:

```swift
@Test func vramImageWritesAPngWhoseChannelsAreTheFiveBitOnesExpanded() throws {
    // ABGR1555 -> 8 bits per channel is `(c << 3) | (c >> 2)`, so 31 becomes
    // 255 and 0 becomes 0 — a plain `<< 3` would top out at 248 and every
    // dumped image would be subtly dark, which is exactly the kind of thing
    // an eyeball gate would rationalize away.
    let pixels: [UInt16] = [
        0x001F,             // red   = 31
        0x03E0,             // green = 31
        0x7C00,             // blue  = 31
        0x8000,             // all channels 0, mask bit set (and ignored)
    ]
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vramimage-test.png")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(VramImage.write(pixels, width: 2, height: 2, to: url))

    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        #expect(Bool(false), "the PNG did not read back")
        return
    }
    #expect(image.width == 2)
    #expect(image.height == 2)

    var back = [UInt8](repeating: 0, count: 2 * 2 * 4)
    back.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: 2, height: 2,
                            bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    #expect(back[0] == 255 && back[1] == 0 && back[2] == 0)     // red
    #expect(back[4] == 0 && back[5] == 255 && back[6] == 0)     // green
    #expect(back[8] == 0 && back[9] == 0 && back[10] == 255)    // blue
    #expect(back[12] == 0 && back[13] == 0 && back[14] == 0)    // mask bit only
}
```

Add `import CoreGraphics` and `import ImageIO` to the top of `MetalVramTests.swift`.

- [ ] **Step 2: Implement `VramImage`**

Create `ps1-macos/Sources/PS1/VramImage.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// ABGR1555 -> PNG, for the one Phase C gate a machine cannot run: seams along
/// quad diagonals, texture bleeding, and gaps between adjacent primitives are
/// all things you see in an image and none of them move a hash.
///
/// A sibling of `VramDump`, not a replacement: a `.vram` blob is the exact
/// bytes and is what a diff is taken against; a PNG is lossy about the mask bit
/// and is for looking at.
enum VramImage {
    /// Sits next to the fixtures, which are already build artifacts.
    static func url(fixture: String, frame: Int, scale: Int) -> URL {
        FixtureFile.repoURL
            .appendingPathComponent("zig-out/fixtures")
            .appendingPathComponent("\(fixture)-frame\(frame)-\(scale)x.png")
    }

    /// Bit 15 (mask/STP) is DROPPED, not rendered as alpha: an image whose
    /// alpha varied with the mask bit would show masked regions as holes and
    /// invite exactly the wrong conclusion about a picture that is correct.
    static func write(_ pixels: [UInt16], width: Int, height: Int, to url: URL) -> Bool {
        precondition(pixels.count == width * height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let p = pixels[i]
            let r = Int(p & 0x1F), g = Int((p >> 5) & 0x1F), b = Int((p >> 10) & 0x1F)
            // 5 -> 8 bits by replicating the high bits, so 31 maps to 255.
            // A plain << 3 tops out at 248 and darkens every dump.
            rgba[i * 4 + 0] = UInt8((r << 3) | (r >> 2))
            rgba[i * 4 + 1] = UInt8((g << 3) | (g >> 2))
            rgba[i * 4 + 2] = UInt8((b << 3) | (b >> 2))
            rgba[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
```

Run the suite; the new test passes.

- [ ] **Step 3: Add `replayTo`, then Gate 3 and Gate 4**

Append to `MetalScaleHarness`:

```swift
    /// Cumulative replay through `frame`, returning that frame's result.
    ///
    /// Dithering defaults to SHIPPING behaviour here, not to off: Gate 3 is
    /// about how the picture looks, and at 1x that includes the dither
    /// pattern. Gate 2's comparisons pass `ditherDisabled: true` instead.
    static func replayTo(_ name: String, frame last: Int, scale: Int,
                         ditherDisabled: Bool = false) throws -> Frame? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
        let r = try MetalRasterizer(vram: vram)
        r.ditherDisabled = ditherDisabled

        let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        var instances: [Ps1PrimInstance] = []
        withExtendedLifetime(file) {
            for i in 0...min(last, file.frames.count - 1) {
                r.beginFrame(payload: file.payload(for: i))
                for cmd in file.records(for: i) { r.apply(cmd) }
                instances = r.instances
                r.endFrame()
            }
        }
        return Frame(scaled: vram.readback(), native: vram.readbackNative(),
                     instances: instances, width: vram.width, height: vram.height,
                     scale: scale)
    }
```

Append to `MetalScaleTests.swift`:

```swift
// MARK: - Gate 3: images
//
// Seams along quad diagonals, texture bleeding and gaps between adjacent
// primitives are visible in an image and move no hash. Opt-in, because it
// writes ~50 MB of PNG and nothing asserts on it.

/// The densest frame of each geometry fixture by draw-record count, measured
/// 2026-08-29 over `zig-out/fixtures/`: Silent Hill frame 74 carries 1,694
/// draws and Tomb Raider frame 58 carries 281.
private let gate3Frames: [(String, Int)] = [("silent-hill-usa", 74), ("tr1-usa-v1-1", 58)]

@Test(.enabled(if: ProcessInfo.processInfo.environment["PS1_DUMP_SCALED"] != nil,
               "set PS1_DUMP_SCALED=<N> to write the comparison PNGs"))
func dumpsScaledImagesForEyeballing() throws {
    guard let n = Int(ProcessInfo.processInfo.environment["PS1_DUMP_SCALED"] ?? ""),
          n >= 1, n <= 8 else {
        #expect(Bool(false), "PS1_DUMP_SCALED must be 1...8")
        return
    }
    for (name, frame) in gate3Frames {
        guard generatedFixtureExists(name) else { continue }
        for scale in Set([1, n]).sorted() {
            guard let f = try MetalScaleHarness.replayTo(name, frame: frame, scale: scale)
            else { return }
            let url = VramImage.url(fixture: name, frame: frame, scale: scale)
            #expect(VramImage.write(f.scaled, width: f.width, height: f.height, to: url))
            // Neither geometry fixture uploads a texture — their windows start
            // from a blank VRAM, so their textured draws sample whatever the
            // fills and copies left behind and a texel of 0 is a discarded
            // HOLE. This number is how much picture there actually is to read.
            let painted = f.native.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            print("[gate-3] \(name) frame \(frame) @\(scale)x -> \(url.path) "
                  + "(\(painted) of \(MetalVram.nativePixelCount) native px painted)")
        }
    }
}

// MARK: - Gate 4: cost
//
// The bounding-box overdraw Phase B accepted deliberately costs s^2 more
// fragments, and it had never been measured at any scale. Opt-in: it is a
// measurement, not an assertion, and it replays the whole corpus four times.

@Test(.enabled(if: ProcessInfo.processInfo.environment["PS1_SCALE_TIMING"] != nil,
               "set PS1_SCALE_TIMING=1 to measure per-scale replay cost"))
func measuresReplayCostAtEachScale() throws {
    let corpus = ["synthetic-primitives", "synthetic-movers"] + untexturedPlFixtures
        + moverFixtures + ["silent-hill-usa", "tr1-usa-v1-1"]
    for name in corpus {
        // `generatedFixtureExists` covers the committed synthetics too:
        // FixtureFile.url(named:) resolves those out of
        // ps1-core/tests/goldens/fixtures before falling back to zig-out.
        guard generatedFixtureExists(name) else { continue }
        for scale in [1, 2, 4, 8] {
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let frames = try replayForTiming(name, scale: scale) else { continue }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let label = name.padding(toLength: 30, withPad: " ", startingAt: 0)
            print("[gate-4] \(label) @\(scale)x  "
                  + String(format: "%8.1f ms", ms) + "  (\(frames) frames)")
        }
    }
}

/// Replays a fixture at one scale and returns the frame count — no comparison,
/// no readback, so the number Gate 4 prints is render cost and not the cost of
/// moving 67 MB back over the bus per frame.
private func replayForTiming(_ name: String, scale: Int) throws -> Int? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: scale) else { return nil }
    let r = try MetalRasterizer(vram: vram)
    let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
    var frames = 0
    withExtendedLifetime(file) {
        for i in 0..<file.frames.count {
            r.beginFrame(payload: file.payload(for: i))
            for cmd in file.records(for: i) { r.apply(cmd) }
            r.endFrame()
            frames += 1
        }
    }
    return frames
}
```

- [ ] **Step 4: Run Gate 4 and Gate 3, and read them**

```bash
zig build metallib && ps1-macos/test.sh   # confirm green first
PS1_SCALE_TIMING=1 xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  SYMROOT="$PWD/.build/xcode" -only-testing:PS1Tests/measuresReplayCostAtEachScale \
  test 2>&1 | grep '\[gate-4\]'

PS1_DUMP_SCALED=4 xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  SYMROOT="$PWD/.build/xcode" -only-testing:PS1Tests/dumpsScaledImagesForEyeballing \
  test 2>&1 | grep '\[gate-3\]'
```

Then **open the four PNGs** in `zig-out/fixtures/` and compare 1× against 4×, looking for exactly the three things a hash cannot see: a seam along a quad's diagonal (the two halves are separate triangles and the top-left rule must paint the shared edge once), texture bleeding at a page or CLUT boundary, and a gap between primitives that abut at 1×. Record what you saw in the commit message — "no seams, no bleeding, no gaps at 4× on both frames" is a finding, and so is anything else.

If the 4× image is largely empty, check the printed painted-pixel count before concluding anything: these two fixtures upload no textures, so much of their geometry samples holes.

- [ ] **Step 5: Apply the sweep policy the measurement implies**

Add the timings to the plan's own record by putting them in the commit message, then apply the rule:

- **If the N=8 pass over `silent-hill-usa` + `tr1-usa-v1-1` together took under 120 s** (Gate 4's two `@8x` lines, plus roughly the same again for the 1× reference side and the readbacks Gate 2 adds), leave every call site on `scaleLadder` and add one line to `MetalScaleTests.swift` recording the measurement:

```swift
// Measured 2026-08-29 (Gate 4): the full four-scale sweep over the geometry
// fixtures costs <fill in> s, so scale 8 stays in the habitual suite.
```

- **Otherwise**, introduce the narrowing the spec's § Risks pre-authorizes and point the three large-fixture tests at it:

```swift
/// Gate 2's sweep over the fixtures with 100+ frames. Scale 8 reads back 67 MB
/// per frame, and measured (Gate 4, 2026-08-29) the full sweep over the two
/// geometry fixtures costs <fill in> s — too slow to run on every suite
/// invocation. Scale 8 stays unconditional on the synthetics and the PL ROMs,
/// which is where the primitive-by-primitive coverage is; PS1_SCALE_FULL=1
/// restores it everywhere. What must NOT be dropped is scale 3, or the
/// geometry fixtures themselves — they are the only real-game coverage there
/// is.
let corpusScales: [Int] = ProcessInfo.processInfo.environment["PS1_SCALE_FULL"] != nil
    ? scaleLadder : [2, 3, 4]
```

and change `scaleLadder` to `corpusScales` in exactly three tests: `theTombRaiderFixtureIsDownsampleInvariant`, `theSilentHillFixtureIsDownsampleInvariant` and `theMoverFixturesAreDownsampleInvariant` (croc is the 200-frame one in that list). Everything else stays on `scaleLadder`.

- [ ] **Step 6: Run the whole suite one final time**

```bash
zig build capi-lib && zig build metallib && ps1-macos/test.sh 2>&1 | tail -40
```
Expected: green. Also re-run the Zig gates once, since this is the phase's last commit and they are cheap insurance that nothing leaked out of `ps1-macos/`:

```bash
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- stream-verify
```
Expected: all green, all ten workloads OK. Phase C touches no Zig, so a red one here means something was edited that this phase forbids.

- [ ] **Step 7: Update `CLAUDE.md`**

In the `## Per-subsystem cheat-sheet` section, replace the opening sentence of the Metal-backend paragraph:

> **The Metal backend runs at 1x and is fixture-driven only.**

with:

> **The Metal backend renders at an internal resolution of 1-8x and is fixture-driven only.**

and append this paragraph immediately after that block:

```markdown
**Internal resolution is a runtime uniform, and every RECORD stays native.**
`Ps1PrimInstance` is in 1024x512 units at every scale — the vertex shader
sizes the quad to `box * s` and each fragment shader recovers
`nx = px / s`, `sub_x = px % s` and multiplies by `s` at the point of use.
That is a testability decision: the 1x gate compares literally the same
instance bytes Phase B pinned, and the oversized-primitive refusal and the
hazard rectangles never need a second coordinate space. Three rules are
load-bearing and each has a test aimed at it alone: **the drawing-area clip
is inclusive**, so it scales to `[x0*s, (x1+1)*s - 1]` and the plausible
wrong form (`x1*s`) is invisible to both the 1x gate and the
downsample-invariance gate, because they agree at every top-left subtexel;
**`ps1_vram_read` linearizes `y*1024+x` in NATIVE space and scales only the
resulting address**, since that row-crossing reproduces `Vram.index` and
linearizing at scale would invent a different wrap; and **`ps1_copy_fragment`
is the one read that is not reduced to native** — it carries `sub_x`/`sub_y`
so a VRAM->VRAM blit preserves scaled detail, and those terms are zero at a
top-left subtexel, so dropping them would pass every hash. Texture data is
never upscaled: a texel at `(u, v)` reads its block's top-left subtexel at
all three depths. **Dithering is on at 1x and off above it**, decided in the
shader (`scale == 1`) and never by clearing the flag in `PrimBuilder`, which
would make the record differ between scales. The gate is
**downsample-invariance**: taking each block's top-left subtexel reproduces
the 1x image byte-for-byte over the whole 1024x512, on every frame of all
eleven fixtures, at N in {2,3,4,8} — **3 is in that list on purpose**, since
`/ s` and `% s` are shifts and masks at every power of two and a
`>> log2(s)` bug is invisible at 2, 4 and 8. Nothing display-side scales yet
(the scanout wrap, 24bpp, the scale picker); that is Phase D.
```

- [ ] **Step 8: Commit**

```bash
git add ps1-macos/Sources/PS1/VramImage.swift \
        ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift \
        ps1-macos/Tests/PS1Tests/MetalScaleTests.swift \
        ps1-macos/Tests/PS1Tests/MetalVramTests.swift CLAUDE.md
git commit -m "$(cat <<'MSG'
feat(metal): scaled image dumps, the cost measurement, and the Phase C gate

VramImage writes ABGR1555 to PNG through ImageIO (5 -> 8 bits by
replicating the high bits, so 31 maps to 255 and not 248), and
PS1_DUMP_SCALED=<N> dumps the densest Silent Hill and Tomb Raider frames
at 1x and N for the one gate a machine cannot run: seams, bleeding, gaps.
PS1_SCALE_TIMING=1 prints the per-scale replay cost that the s^2
bounding-box overdraw had never been measured against.

Gate 3 (read by eye): <fill in what the images showed>
Gate 4 (measured): <fill in the per-scale timings>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## Definition of done

- Gate 1 — every Phase B test green at 1×, no fixture hash moved anywhere in the phase.
- Gate 2 — `readbackNative()` at N equals the 1× VRAM byte-for-byte on **every frame of all eleven fixtures**, at N ∈ {2,3,4,8} (with the Step 5 narrowing applied only if the measurement demanded it, and N=3 never dropped).
- Gate 2b — nothing written outside `box*s` ∩ `clip*s`, the clip's inclusive bound pinned directly, and coverage density inside the ratio band on `synthetic-primitives` frames 0, 3 and 5.
- Gate 3 — PNGs produced and read; what they showed is written down in the Task 6 commit message.
- Gate 4 — per-fixture, per-scale wall clock printed and recorded.
- `zig build test`, `trace-golden -- verify` and `trace-golden -- stream-verify` green — Phase C adds no Zig, so these are unchanged by construction and are checked to prove it.
- `Ps1PrimInstance` still 42 words on both sides; `ps1-core/src`, `ps1-capi`, `ps1-golden`, `build.zig` and `DisplayShader.metal` untouched.
- `CLAUDE.md` updated.
