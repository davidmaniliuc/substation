# True Colour Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Metal renderer eight bits per colour channel on screen — closing
the banding gap against DuckStation on Crash Bandicoot's sand — without moving a
single byte of the `.r16Uint` VRAM every gate reads.

**Architecture:** VRAM stays `.r16Uint` and stays the authority. Beside it sits a
second scaled texture, `.rgba8Uint`, written by the *same* fragment shader
invocation as a second colour attachment and read only by the display shader.
Its alpha channel is per-pixel presence: 255 where it holds a real eight-bit
colour, 0 where the display falls back to expanding VRAM. A fourth `DitherMode`
case, `.trueColor`, decides whether a shaded fragment writes its eight-bit value
there or merely the expansion of the five-bit one.

**Tech Stack:** Swift 6 / SwiftUI (`ps1-macos`), Metal Shading Language
(`ps1-macos/Shaders/`), swift-testing. No Zig changes, no C ABI changes, no
golden recapture.

**Spec:** `docs/superpowers/specs/2026-09-12-true-colour-rendering-design.md`

---

## Global Constraints

Copied verbatim from the spec and from CLAUDE.md's rules for this area. Every
task's requirements implicitly include this section.

- **Scope is the macOS Metal renderer only.** No changes to `ps1-core`,
  `ps1-capi`, `ps1-golden`, the C ABI, or any `.p1fx` fixture. No
  `trace-golden -- capture`, no pixel-floor re-pin, no fixture regeneration.
- **VRAM stays `.r16Uint` and stays the authority.** `MetalVram.texture` keeps
  its format, its contents and its hashes. Adopting `RGBA8` for VRAM surrenders
  Gate 1's fixture hashes, Gate 2's downsample-invariance and `PS1_LIVE_DIFF`
  at once, and is the approach this design rejects.
- **The sidecar is display-only.** Never sampled as a texel, never read back by
  the game, never hashed by a gate, never compared by `PS1_LIVE_DIFF`.
- **The coherence invariant:** *for every VRAM pixel, the sidecar either holds
  the eight-bit colour whose five-bit truncation that VRAM pixel is, or is
  marked absent.*
- **The copy must be one pass, two attachments, one ordering.** A sidecar
  copied in a second pass can resolve a self-overlap differently from the VRAM
  copy beside it.
- **The mask bit belongs to VRAM alone.** The sidecar has no bit 15 — its alpha
  is presence, not mask.
- **`ps1_blend` gains an eight-bit sibling rather than being replaced** (and not
  until milestone 2). VRAM's value must keep coming from the existing five-bit
  integer expression, because that is what `PS1_LIVE_DIFF` and `renderer.zig`
  agree on.
- **`DitherMode` gains a case rather than a second setting appearing beside it.**
  True colour and dithering are mutually exclusive by construction; two controls
  that cannot both be on is a control that silently no-ops.
- **The mode stays a runtime UNIFORM.** `Ps1RasterUniforms` is 8 bytes and does
  not grow; `dither_mode` carries the new value. A flag cleared in `PrimBuilder`
  would make the instance bytes differ between modes and forfeit the
  byte-identical-records property Phases B and C rest on. `Ps1PrimInstance`
  stays 4 * 48 bytes.
- **`.trueColor` is not part of `ContentView`'s `.id()`.** Like the other dither
  modes it rides `updateNSView` down to `LiveRenderer`; only a scale change
  rebuilds the coordinator.
- **Milestone 1 only.** The blend path keeps reading VRAM and expanding. The
  spec gates milestone 2 on evidence of a scene that bands *because of* layered
  blending, and that evidence does not exist yet.
- **No file in `ps1-core/src` over ~600 lines** (not touched here, but the
  house style for the Swift sources is the same: split by responsibility).
- Run `zig fmt` before committing if any `.zig` file is touched (none should be).

### Running the tests

```bash
cd /Users/david/Documents/develop/substation
pkill -x Substation            # a running app shares the bundle id and fails the run
zig build capi-lib
zig build metallib             # needs full Xcode, not just CLT
ps1-macos/test.sh              # the 352 Swift tests, ~2.5 min
```

A single test: `ps1-macos/test.sh` takes no filter, so use xcodebuild directly —

```bash
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/theSidecarStartsAbsent 2>&1 | tail -20
```

**`Failing tests:` with zero `✘` lines is the sustained-GPU-load crash, not a
real failure — re-run before believing it.**

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `ps1-macos/Sources/PS1/MetalVram.swift` | owns both textures, clears them, invalidates the sidecar, reads both back | **Modify** (Task 1) |
| `ps1-macos/Shaders/Ps1Color.h` | integer colour helpers shared with `renderer.zig` | **Modify** — `ps1_expand`, `ps1_pack8`, `ps1_modulate`'s out-param (Tasks 2, 4) |
| `ps1-macos/Shaders/Rasterizer.metal` | the four fragment shaders | **Modify** — `Ps1FragOut`, the sidecar write per path (Tasks 2, 4) |
| `ps1-macos/Sources/PS1/MetalRasterizer.swift` | pipelines, passes, the scratch pair | **Modify** (Task 2) |
| `ps1-macos/Shaders/DisplayShader.metal` | scanout | **Modify** — prefer the sidecar, unify the expansion (Task 3) |
| `ps1-macos/Sources/PS1/MetalDisplayView.swift` | MTKView plumbing | **Modify** — bind the sidecar at texture(2) (Task 3) |
| `ps1-macos/Shaders/PrimInstance.h` | the shared C declarations | **Modify** — `PS1_DITHER_TRUE_COLOR` (Task 4) |
| `ps1-macos/Sources/PS1/DitherMode.swift` | the enum and its persistence | **Modify** — the fourth case, the new default (Tasks 4, 6) |
| `ps1-macos/Sources/PS1App/VideoCommands.swift` | the Video menu | **No change needed** — the picker is built from `allCases` (verified in Task 6) |
| `ps1-macos/Sources/PS1/VramImage.swift` | ABGR1555 -> PNG for Gate 3 | **Modify** — an RGBA8 sibling (Task 7) |
| `ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift` | Gate 1 | **Modify** — pin its own dither mode (Task 5) |
| `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift` | Gates 2/3 | **Modify** — optional sidecar readback (Task 2) |
| `ps1-macos/Tests/PS1Tests/DisplayPassHarness.swift` | offscreen display pass | **Modify** — a third texture (Task 3) |
| `ps1-macos/Tests/PS1Tests/TrueColourTests.swift` | the mode's own gates | **Create** (Task 4) |
| `CLAUDE.md`, `.claude/skills/ps1-gpu-metal/SKILL.md` | the rules and their reasoning | **Modify** (Task 8) |

---

### Task 1: The sidecar texture on `MetalVram`

**Files:**
- Modify: `ps1-macos/Sources/PS1/MetalVram.swift:7-13` (the type comment), `:44-48`
  (stored properties), `:50-91` (`init`/`clear`), after `:198` (readback)
- Test: `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `MetalVram.sidecar: MTLTexture` — `.rgba8Uint`, `width` x `height` (scaled),
    `[.renderTarget, .shaderRead]`, `.private`.
  - `MetalVram.readbackSidecar() -> [UInt8]` — the SCALED image, `pixelCount * 4`
    bytes, R,G,B,A per pixel.
  - `MetalVram.readbackSidecarNative() -> [UInt8]` — each N x N block's top-left
    subtexel, `nativePixelCount * 4` bytes.
  - `MetalVram.clearSidecar()` — alpha 0 everywhere, VRAM untouched.

Nothing writes the sidecar yet, so it reads back all-zero (absent) for the whole
of this task. That is why the invalidation rules land in Task 2: before a draw
can make a pixel present, "invalidated" and "never written" are the same bytes
and no test can tell them apart.

- [ ] **Step 1: Write the failing test**

Append to `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`:

```swift
@Test func theSidecarStartsAbsentAndIsScaledLikeTheRenderTexture() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: 3) else { return }

    // The sidecar is a SECOND attachment on the same passes, so it must match
    // the render texture pixel for pixel at every internal resolution — a
    // mismatched size is a render-pass validation failure, not a wrong pixel.
    #expect(vram.sidecar.width == vram.width)
    #expect(vram.sidecar.height == vram.height)
    #expect(vram.sidecar.pixelFormat == .rgba8Uint)

    // Alpha is PRESENCE. A .private texture's initial contents are
    // unspecified, so a blank VRAM must come with a blank sidecar or the very
    // first frame displays whatever the allocator handed back.
    let side = vram.readbackSidecar()
    #expect(side.count == vram.pixelCount * 4)
    #expect(side.allSatisfy { $0 == 0 })

    let native = vram.readbackSidecarNative()
    #expect(native.count == MetalVram.nativePixelCount * 4)
    #expect(native.allSatisfy { $0 == 0 })
}

@Test func clearSidecarLeavesTheRenderTextureAlone() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    var pixels = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    pixels[7] = 0x1234
    vram.upload(pixels)

    // The invalidation path: the sidecar is cleared through a pass that LOADS
    // and STORES attachment 0. Clearing both would silently wipe VRAM on every
    // resync, which at 1x is every dropped frame.
    vram.clearSidecar()
    #expect(vram.readback()[7] == 0x1234)
    #expect(vram.readbackSidecar().allSatisfy { $0 == 0 })
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/theSidecarStartsAbsentAndIsScaledLikeTheRenderTexture 2>&1 | tail -20
```

Expected: compile failure — `value of type 'MetalVram' has no member 'sidecar'`.

- [ ] **Step 3: Add the texture, the clear and the readbacks**

In `ps1-macos/Sources/PS1/MetalVram.swift`, extend the type comment at the top
(after the existing "R16Uint and NOT RGBA8" paragraph, before the
"This is a DIFFERENT texture" line):

```swift
/// Beside it — NOT instead of it — sits `sidecar`, an RGBA8 texture holding the
/// eight-bit colour of every pixel a draw has touched. It is written by the same
/// fragment shader invocation as a second colour attachment and read only by the
/// display shader. It is never sampled as a texel, never read back by the game,
/// never hashed by a gate and never compared by `PS1_LIVE_DIFF`; VRAM is
/// unchanged in every mode, which is why true colour needs no gate exemption.
/// DuckStation samples indexed texture data out of its RGBA8 target and converts
/// back down — on this axis the sidecar is more accurate than the reference, not
/// less.
///
/// Its ALPHA is per-pixel presence: 255 where it holds a real eight-bit colour,
/// 0 where the display falls back to `c << 3 | c >> 2` over VRAM. Per-pixel
/// rather than CPU-side dirty rectangles because it costs no bookkeeping, cannot
/// go stale, and is exact at rect boundaries — DuckStation needs two dirty rects
/// (`m_vram_dirty_draw_rect`, `m_vram_dirty_write_rect`) to answer the same
/// question.
```

Add the stored property beside `texture` (line 44):

```swift
    let texture: MTLTexture
    /// The display-only eight-bit sidecar — see the type comment. Always
    /// allocated, at every dither mode: the mode is a runtime uniform on an
    /// already-built pipeline, and making the allocation conditional would put
    /// a texture rebuild behind a setting that deliberately has none.
    let sidecar: MTLTexture
```

In `init`, after the existing `texture`/`staging` guard, add:

```swift
        let sideDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Uint, width: w, height: h, mipmapped: false)
        // .shaderRead as well as .renderTarget for the same reason the render
        // texture needs it: the copy path samples a frozen snapshot of it, and
        // the display pass reads it every frame.
        sideDesc.usage = [.renderTarget, .shaderRead]
        sideDesc.storageMode = .private
        guard let sidecar = device.makeTexture(descriptor: sideDesc) else { return nil }
```

…and assign `self.sidecar = sidecar` alongside `self.texture = texture`, before
the trailing `clear()`.

**`.rgba8Uint` and not `.rgba8Unorm`:** a unorm attachment takes a float from the
fragment shader and converts, so an exact eight-bit value has to survive a
round trip through `float`. Every colour expression in this backend is integer
arithmetic on purpose (see `Ps1Color.h`'s header); a Uint attachment keeps it
that way and makes the stored byte the value the shader computed.

Replace `clear()`'s pass construction so it clears both attachments, and add the
sidecar-only sibling below it:

```swift
    func clear() {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        // Alpha 0 is ABSENT, so a cleared sidecar is the correct starting
        // state: the display expands VRAM, which is blank too.
        pass.colorAttachments[1].texture = sidecar
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[1].storeAction = .store
        runClearPass(pass, label: "MetalVram.clear")
    }

    /// Marks the WHOLE sidecar absent without touching VRAM.
    ///
    /// The invalidation half of the coherence rules: a resync from a software
    /// frame (`LiveRenderer`'s `uploadNative`) carries a 5551 picture with no
    /// extra precision in it, so there is nothing to keep and claiming
    /// otherwise would display stale eight-bit colour under a new frame.
    ///
    /// Attachment 0 LOADS and STORES rather than being left off the
    /// descriptor: a pass with a hole at index 0 is a shape Metal validation
    /// has opinions about, and load/store says exactly what is meant — VRAM
    /// survives this.
    func clearSidecar() {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = sidecar
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[1].storeAction = .store
        runClearPass(pass, label: "MetalVram.clearSidecar")
    }

    /// The encode-and-wait both clears above share. Traps rather than degrades,
    /// for the reason `clear()`'s comment gives: a silently-skipped clear is
    /// indistinguishable from a correct blank.
    private func runClearPass(_ pass: MTLRenderPassDescriptor, label: String) {
        guard let cmd = queue.makeCommandBuffer() else {
            preconditionFailure("\(label): queue.makeCommandBuffer() returned nil")
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            preconditionFailure("\(label): makeRenderCommandEncoder(descriptor:) returned nil")
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }
```

Add the readback pair after `readbackNative()`:

```swift
    /// Staging for the sidecar, allocated on FIRST USE and then kept.
    ///
    /// Lazy because the app never takes this path: the display samples the
    /// sidecar on the GPU and `PS1_LIVE_DIFF` reads VRAM. Only tests and Gate 3
    /// pull it back over the bus, and at scale 8 an eager allocation is 134 MB
    /// that a shipped build would never touch.
    private var sidecarStaging: MTLBuffer?

    private func sidecarStagingBuffer() -> MTLBuffer {
        if let b = sidecarStaging { return b }
        guard let b = device.makeBuffer(length: pixelCount * 4, options: .storageModeShared) else {
            preconditionFailure("MetalVram.readbackSidecar: makeBuffer returned nil")
        }
        sidecarStaging = b
        return b
    }

    private func blitSidecarToStaging() -> MTLBuffer {
        let buffer = sidecarStagingBuffer()
        guard let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else {
            preconditionFailure("MetalVram.readbackSidecar: blit encoder returned nil")
        }
        blit.copy(from: sidecar, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: width * 4,
                  destinationBytesPerImage: pixelCount * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return buffer
    }

    /// The SCALED sidecar: `pixelCount * 4` bytes, R, G, B, A per pixel.
    func readbackSidecar() -> [UInt8] {
        let buffer = blitSidecarToStaging()
        var out = [UInt8](repeating: 0, count: pixelCount * 4)
        out.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: buffer.contents(), byteCount: dst.count)
        }
        return out
    }

    /// The NATIVE view of the sidecar: each N x N block's TOP-LEFT subtexel,
    /// `nativePixelCount * 4` bytes. The same view — and the same reasoning —
    /// as `readbackNative()`.
    func readbackSidecarNative() -> [UInt8] {
        let buffer = blitSidecarToStaging()
        let src = buffer.contents().bindMemory(to: UInt8.self, capacity: pixelCount * 4)
        var out = [UInt8](repeating: 0, count: MetalVram.nativePixelCount * 4)
        for y in 0..<Self.nativeHeight {
            let srcRow = y * scale * width * 4
            let dstRow = y * Self.nativeWidth * 4
            for x in 0..<Self.nativeWidth {
                let s = srcRow + x * scale * 4
                let d = dstRow + x * 4
                out[d] = src[s]; out[d + 1] = src[s + 1]
                out[d + 2] = src[s + 2]; out[d + 3] = src[s + 3]
            }
        }
        return out
    }
```

`sidecarStaging` is a `var` on a class, mutated from `sidecarStagingBuffer()` —
keep `MetalVram` a `final class` (it already is) so this needs no `mutating`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/theSidecarStartsAbsentAndIsScaledLikeTheRenderTexture \
  -only-testing:PS1Tests/clearSidecarLeavesTheRenderTextureAlone 2>&1 | tail -20
```

Expected: both pass.

- [ ] **Step 5: Run the whole suite**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation && ps1-macos/test.sh 2>&1 | tail -20
```

Expected: 354 tests, all passing. Nothing else reads the sidecar yet, so no
existing gate can move.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/MetalVram.swift ps1-macos/Tests/PS1Tests/MetalVramTests.swift
git commit -m "$(cat <<'MSG'
feat(gpu): the true-colour sidecar texture

An RGBA8 texture beside VRAM, same dimensions at every internal
resolution, with alpha as per-pixel presence. Nothing writes it yet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014Kcgw8AXvMh8ZFNjtU5xFS
MSG
)"
```

---

### Task 2: Every VRAM path maintains or invalidates the sidecar

The whole coherence table, at five-bit precision. After this task the sidecar is
an exact mirror of `expand(VRAM)` wherever it is present, and absent exactly
where the spec says it must be. Nothing displays it yet, so the picture cannot
change — which is what makes the mirror property checkable in isolation.

**Files:**
- Modify: `ps1-macos/Shaders/Ps1Color.h` (add `ps1_expand`, `ps1_pack8`)
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (all four fragment shaders)
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift:38` (scratch), `:128-145`
  (pipelines + scratch alloc), `:170-184` (`makePipeline`), `:241-256`
  (`openPass`), `:266-277` (`.snapshot`), `:278-285` (the draw case)
- Modify: `ps1-macos/Sources/PS1/MetalVram.swift` (`upload`, `uploadNative`)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift` (optional sidecar)
- Modify: `ps1-macos/Tests/PS1Tests/MetalVramTests.swift:56-68`
  (`theRasterizerVertexFunctionAndFillPipelineBuild`)
- Test: `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`

**Interfaces:**
- Consumes: `MetalVram.sidecar`, `.clearSidecar()`, `.readbackSidecar()`,
  `.readbackSidecarNative()` from Task 1.
- Produces:
  - MSL: `ushort3 ps1_expand(ushort c)`, `ushort3 ps1_pack8(int r, int g, int b)`.
  - MSL: `struct Ps1FragOut { ushort vram [[color(0)]]; ushort4 side [[color(1)]]; }`,
    `Ps1FragOut ps1_out(ushort, ushort3)`, `Ps1FragOut ps1_out_absent(ushort)`,
    `Ps1FragOut ps1_discarded()`.
  - Swift: `MetalScaleHarness.frame(scale:payload:preload:dither:wantSidecar:_:)`
    and `MetalScaleHarness.Frame.sidecar: [UInt8]?` (the SCALED bytes).

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`:

```swift
/// The coherence invariant, asserted directly: wherever the sidecar is
/// present, it is the eight-bit expansion of the VRAM pixel beside it.
///
/// At five-bit precision that is all the sidecar can be, and checking it here —
/// before `.trueColor` exists — is what separates "the plumbing is right" from
/// "the new mode is right". Every later test in this feature rests on it.
@Test func theSidecarMirrorsVramWhereverItIsPresent() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)

    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.x = 8; fill.y = 8; fill.w = 32; fill.h = 32
    fill.value = 0x2955          // low bits set in all three channels

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
    tri.v.0 = Ps1GpuVertex(x: 100, y: 100, u: 0, v: 0, _pad: 0, color: 0x0020_4060)
    tri.v.1 = Ps1GpuVertex(x: 300, y: 110, u: 0, v: 0, _pad: 0, color: 0x00C0_8040)
    tri.v.2 = Ps1GpuVertex(x: 110, y: 260, u: 0, v: 0, _pad: 0, color: 0x0040_C080)

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(area); r.apply(fill); r.apply(tri)
    r.endFrame()

    let pixels = vram.readback()
    let side = vram.readbackSidecar()
    var present = 0
    for i in 0..<pixels.count {
        let a = side[i * 4 + 3]
        if a == 0 {
            // Absent means nothing has drawn here, so VRAM is still blank.
            #expect(pixels[i] == 0, "pixel \(i) is drawn but absent from the sidecar")
            continue
        }
        #expect(a == 255, "alpha is presence: only 0 or 255 are legal")
        present += 1
        let p = pixels[i]
        let want = [UInt16(p & 0x1F), UInt16((p >> 5) & 0x1F), UInt16((p >> 10) & 0x1F)]
            .map { UInt8(($0 << 3) | ($0 >> 2)) }
        #expect(side[i * 4] == want[0] && side[i * 4 + 1] == want[1]
                && side[i * 4 + 2] == want[2],
                "pixel \(i) sidecar disagrees with the expansion of VRAM")
    }
    // Guards the whole loop against passing vacuously.
    #expect(present > 20_000)
}

/// GP0(A0). The payload is genuine 5551 from the game and no extra precision
/// exists, so the destination rect goes ABSENT — exactly the rect, which is
/// what per-pixel presence buys over a dirty rectangle.
@Test func theSidecarIsAbsentWhereVramWasUploaded() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.x = 0; fill.y = 0; fill.w = 64; fill.h = 64
    fill.value = 0x7FFF

    var setup = Ps1GpuCommand()
    setup.kind = UInt8(PS1_GPU_VRAM_WRITE_SETUP.rawValue)
    setup.x = 16; setup.y = 16; setup.w = 8; setup.h = 4

    var data = Ps1GpuCommand()
    data.kind = UInt8(PS1_GPU_VRAM_WRITE_DATA.rawValue)
    data.x = 0                      // payload word offset
    data.y = 16                     // 8 * 4 pixels / 2 per word

    let payload = [UInt32](repeating: 0x1234_1234, count: 16)
    payload.withUnsafeBufferPointer { buf in
        r.beginFrame(payload: buf)
        r.apply(fill); r.apply(setup); r.apply(data)
        r.endFrame()
    }

    let side = vram.readbackSidecar()
    func alpha(_ x: Int, _ y: Int) -> UInt8 { side[(y * 1024 + x) * 4 + 3] }
    // Inside the destination rect: absent.
    #expect(alpha(16, 16) == 0)
    #expect(alpha(23, 19) == 0)
    // One pixel outside it on each axis: still present from the fill.
    #expect(alpha(15, 16) == 255)
    #expect(alpha(24, 16) == 255)
    #expect(alpha(16, 15) == 255)
    #expect(alpha(16, 20) == 255)
}

/// GP0(80). The sidecar is copied alongside VRAM, alpha included, in the SAME
/// shader pass — so an absent source yields an absent destination and the
/// invariant carries itself with no extra rule.
@Test func aCopyCarriesPresenceWithThePixels() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.x = 0; fill.y = 0; fill.w = 32; fill.h = 32
    fill.value = 0x7FFF

    // Present -> absent region.
    var down = Ps1GpuCommand()
    down.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    down.x = 0; down.y = 0          // source: the fill
    down.x2 = 200; down.y2 = 200    // destination: never drawn
    down.w = 16; down.h = 16

    // Absent -> present region.
    var up = Ps1GpuCommand()
    up.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    up.x = 500; up.y = 400          // source: never drawn
    up.x2 = 0; up.y2 = 0            // destination: the fill
    up.w = 8; up.h = 8

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(fill); r.apply(down); r.apply(up)
    r.endFrame()

    let side = vram.readbackSidecar()
    func alpha(_ x: Int, _ y: Int) -> UInt8 { side[(y * 1024 + x) * 4 + 3] }
    #expect(alpha(205, 205) == 255)   // carried presence into a blank region
    #expect(alpha(4, 4) == 0)         // carried absence over a drawn one
    #expect(alpha(20, 20) == 255)     // the rest of the fill is untouched
}

/// A resync from a software frame is 5551 with no extra precision in it, so
/// both upload paths invalidate the WHOLE sidecar. Keeping presence across one
/// would display last frame's eight-bit colour under this frame's picture.
@Test func bothUploadPathsInvalidateTheWholeSidecar() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: 2) else { return }
    let r = try MetalRasterizer(vram: vram)

    var fill = Ps1GpuCommand()
    fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    fill.x = 0; fill.y = 0; fill.w = 64; fill.h = 64
    fill.value = 0x7FFF

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(fill)
    r.endFrame()
    #expect(vram.readbackSidecar().contains { $0 == 255 })

    vram.uploadNative([UInt16](repeating: 0x1234, count: MetalVram.nativePixelCount))
    #expect(vram.readbackSidecar().allSatisfy { $0 == 0 })

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(fill)
    r.endFrame()
    #expect(vram.readbackSidecar().contains { $0 == 255 })

    vram.upload([UInt16](repeating: 0x1234, count: vram.pixelCount))
    #expect(vram.readbackSidecar().allSatisfy { $0 == 0 })
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/theSidecarMirrorsVramWhereverItIsPresent 2>&1 | tail -20
```

Expected: FAIL — every pixel's alpha is still 0, so the `present > 20_000`
expectation fails (and the "drawn but absent" one fires thousands of times).

- [ ] **Step 3: Add the two colour helpers**

In `ps1-macos/Shaders/Ps1Color.h`, directly after `ps1_pack`:

```c
/// The five-bit-to-eight-bit expansion, `c << 3 | c >> 2`, per channel.
///
/// Replicating the high bits rather than a plain `<< 3`, which tops out at 248
/// and darkens everything it touches. This is the SAME expression the display
/// falls back to for an absent sidecar pixel and the same one `VramImage.write`
/// uses for a dump — and their agreeing is what makes an invalidated rect
/// invisible rather than a visible seam against the drawn pixels beside it.
///
/// Bit 15 is ignored, not carried: the sidecar has no mask bit and needs none.
inline ushort3 ps1_expand(ushort c) {
    ushort r = c & 0x1F, g = (c >> 5) & 0x1F, b = (c >> 10) & 0x1F;
    return ushort3((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2));
}

/// ps1_pack's eight-bit sibling: the same three channels, the same clamp, and
/// no `>> 3`.
///
/// The sidecar is its ONLY consumer. VRAM's value must keep coming from
/// ps1_pack, because that five-bit integer expression is what `PS1_LIVE_DIFF`
/// and `renderer.zig` agree on.
inline ushort3 ps1_pack8(int r, int g, int b) {
    return ushort3(ushort(clamp(r, 0, 255)),
                   ushort(clamp(g, 0, 255)),
                   ushort(clamp(b, 0, 255)));
}
```

- [ ] **Step 4: Give every fragment shader a second output**

In `ps1-macos/Shaders/Rasterizer.metal`, after the `Ps1RasterUniforms`
`static_assert` and before `struct PrimVertexOut`, add:

```c
/// The two colour attachments every fragment in this file writes.
///
/// color(0) is VRAM: ABGR1555, hardware-exact, the authority, and what every
/// gate reads. color(1) is the display-only sidecar: eight bits per channel,
/// with ALPHA AS PRESENCE — 255 where it holds a real colour, 0 where the
/// display must expand VRAM instead.
///
/// `ushort4` and not `uchar4`: MSL's render-target and texture data types are
/// half/float/short/ushort/int/uint, so a uchar vector is not a portable
/// spelling for an .rgba8Uint attachment. Every value here is 0...255 anyway —
/// ps1_pack8 clamps before this struct is ever built.
///
/// A fragment that discards writes NEITHER attachment, which is why the mask
/// bit needs no special case: a check-mask rejection leaves both alone and a
/// set-mask write writes both.
struct Ps1FragOut {
    ushort  vram [[color(0)]];
    ushort4 side [[color(1)]];
};

/// PRESENT: this pixel's eight-bit colour.
inline Ps1FragOut ps1_out(ushort v, ushort3 rgb8) {
    return Ps1FragOut{ v, ushort4(rgb8, 255) };
}

/// ABSENT: VRAM is written and the sidecar says "no extra precision here", so
/// the display expands VRAM. Every invalidation degrades to today's picture
/// rather than to a visible defect.
inline Ps1FragOut ps1_out_absent(ushort v) {
    return Ps1FragOut{ v, ushort4(0, 0, 0, 0) };
}

/// The return value of a discarded fragment: neither attachment is written, so
/// only the type matters.
inline Ps1FragOut ps1_discarded() { return Ps1FragOut{ 0, ushort4(0) }; }
```

If `xcrun metal` rejects `ushort4` for an `.rgba8Uint` attachment on this
toolchain, the fallback spelling is `uchar4` — change the struct member and
`ps1_out`/`ps1_out_absent`/`ps1_discarded` together, leave `ps1_pack8` returning
`ushort3` (it is clamped to 0...255 already) and cast at the one construction
site. Do NOT switch the attachment to `.rgba8Unorm` to make a float return type
work: every colour expression in this backend is integer arithmetic on purpose,
and a unorm round trip would put the sidecar's exactness at the mercy of float
conversion.

Change `ps1_fill_fragment` (line 70) to:

```c
fragment Ps1FragOut ps1_fill_fragment(PrimVertexOut in [[stage_in]],
                                      const device Ps1PrimInstance* prims [[buffer(0)]]) {
    ushort v = ushort(prims[in.iid].color);
    // MAINTAIN, at five bits. A fill's colour is a flat 5-bit value that
    // expands exactly, so there is no extra precision to keep — the same
    // reasoning as the flat-colour carve-out in ps1_prim_fragment.
    return ps1_out(v, ps1_expand(v));
}
```

In `ps1_prim_fragment`: change the return type to `Ps1FragOut`, replace every
`{ discard_fragment(); return 0; }` with
`{ discard_fragment(); return ps1_discarded(); }`, and replace the final two
lines with:

```c
    if (p.flags & PS1_PRIM_SET_MASK) out |= 0x8000;
    // MAINTAIN, at five bits for now. Task 4 replaces the second argument with
    // the eight-bit shade in `.trueColor`; until then the sidecar is an exact
    // mirror of VRAM and the picture cannot move.
    return ps1_out(out, ps1_expand(out));
```

In `ps1_upload_fragment`: change the return type to `Ps1FragOut`, the two
discards as above, and the tail to:

```c
    uint word = words[p.word_base + (pix >> 1)];
    ushort v = ushort((pix & 1) ? (word >> 16) : word);
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    // INVALIDATE. The payload is genuine 5551 from the game; no extra
    // precision exists for this pixel and claiming any would show the pixel
    // that USED to be here.
    return ps1_out_absent(v);
```

In `ps1_copy_fragment`: change the return type, add the second scratch texture,
and carry the sidecar:

```c
fragment Ps1FragOut ps1_copy_fragment(PrimVertexOut in [[stage_in]],
                                      ushort dst [[color(0)]],
                                      const device Ps1PrimInstance* prims [[buffer(0)]],
                                      constant Ps1RasterUniforms& uni [[buffer(2)]],
                                      texture2d<ushort, access::read> scratch [[texture(0)]],
                                      texture2d<ushort, access::read> side_scratch [[texture(1)]]) {
```

…with the two discards changed, and the tail:

```c
    uint2 src = uint2(uint(((p.src_x + xx) & 0x3FF) * s + sub_x),
                      uint(((p.src_y + yy) & 0x1FF) * s + sub_y));
    ushort v = scratch.read(src).r;
    if (p.flags & PS1_PRIM_SET_MASK) v |= 0x8000;
    // CARRY, in THIS pass and from the same frozen snapshot. A VRAM->VRAM copy
    // wraps at the VRAM edges and may overlap itself; a sidecar copied in a
    // second pass can resolve that overlap differently from the VRAM copy
    // beside it, and the two pictures then disagree about which source row won.
    // One pass, two attachments, one ordering — so an absent source yields an
    // absent destination with no rule of its own.
    return Ps1FragOut{ v, side_scratch.read(src) };
```

- [ ] **Step 5: Attach the sidecar to every pipeline and pass**

In `ps1-macos/Sources/PS1/MetalRasterizer.swift`:

`makePipeline` (line ~181) gains the second format:

```swift
        desc.colorAttachments[0].pixelFormat = .r16Uint
        // Every fragment in Rasterizer.metal writes Ps1FragOut, and a
        // [[color(1)]] output with no attachment behind it is a pipeline
        // creation error — not a wrong pixel. All four pipelines, always.
        desc.colorAttachments[1].pixelFormat = .rgba8Uint
```

The scratch pair (replace the single `scratch` property and its allocation):

```swift
    private let scratch: MTLTexture
    /// The sidecar's half of the copy snapshot. Blitted in the SAME `.snapshot`
    /// step as `scratch`, so both halves of a VRAM->VRAM copy read a source
    /// frozen at the same instant.
    private let sidecarScratch: MTLTexture
```

```swift
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: vram.width, height: vram.height,
            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let scratch = device.makeTexture(descriptor: desc) else {
            throw Error.missingFunction("scratch texture")
        }
        self.scratch = scratch

        let sideDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Uint, width: vram.width, height: vram.height,
            mipmapped: false)
        sideDesc.usage = .shaderRead
        sideDesc.storageMode = .private
        guard let sidecarScratch = device.makeTexture(descriptor: sideDesc) else {
            throw Error.missingFunction("sidecar scratch texture")
        }
        self.sidecarScratch = sidecarScratch
```

`openPass()` attaches both:

```swift
            pass.colorAttachments[0].texture = vram.texture
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            // .load here too: the sidecar persists across frames and across
            // passes exactly as VRAM does, and every pass after the first in a
            // frame must see the previous one's presence flags.
            pass.colorAttachments[1].texture = vram.sidecar
            pass.colorAttachments[1].loadAction = .load
            pass.colorAttachments[1].storeAction = .store
```

The `.snapshot` case blits both, inside the one blit encoder:

```swift
            case .snapshot:
                closePass()
                if let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(from: vram.texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: vram.width,
                                                  height: vram.height, depth: 1),
                              to: scratch, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.copy(from: vram.sidecar, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: vram.width,
                                                  height: vram.height, depth: 1),
                              to: sidecarScratch, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
```

The draw case binds the second texture:

```swift
                e.setFragmentTexture(kind == .copy ? scratch : vram.texture, index: 0)
                // Bound for every kind, like the display pass's two: only
                // ps1_copy_fragment declares it, and a declared-but-unbound
                // texture2d is a validation failure rather than a black pixel.
                e.setFragmentTexture(sidecarScratch, index: 1)
```

**The coherence table's "None" rows need no code, and that is worth checking
rather than assuming.** `vram_read_setup` (GP0 0xC0) reads VRAM only and is
already a documented no-op in `MetalRasterizer.apply`; the sidecar must never
influence what the game reads back, and nothing here lets it.
`set_draw_env`, `latch_texpage`, `set_texture_disable_allowed`,
`reset_draw_env`, `vram_write_setup` and `vram_write_abort` change no VRAM
pixel, so they encode no instance and reach no fragment shader. Confirm by
inspection that none of those arms in `apply` gained anything in this task.

In `ps1-macos/Sources/PS1/MetalVram.swift`, make both upload paths invalidate.
`upload` ends with `blitStagingToTexture()`; append `clearSidecar()` after it,
and note in `uploadNative` that its `scale == 1` short-circuit into `upload`
already covers it:

```swift
    func upload(_ pixels: [UInt16]) {
        precondition(pixels.count == pixelCount)
        pixels.withUnsafeBytes { src in
            staging.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
        blitStagingToTexture()
        // INVALIDATE WHOLE. The incoming picture is 5551 with no extra
        // precision, and it replaces everything — so does its presence.
        clearSidecar()
    }
```

```swift
    func uploadNative(_ pixels: [UInt16]) {
        precondition(pixels.count == Self.nativePixelCount)
        // `upload` invalidates the sidecar, which covers the scale == 1 case
        // below as well as this one.
        if scale == 1 { upload(pixels); return }
        ...
        blitStagingToTexture()
        clearSidecar()
    }
```

- [ ] **Step 6: Update the pipeline-builds test and the scale harness**

In `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`, the hand-built pipeline in
`theRasterizerVertexFunctionAndFillPipelineBuild` now needs the second
attachment or it fails to build:

```swift
    desc.colorAttachments[0].pixelFormat = .r16Uint
    // ps1_fill_fragment returns Ps1FragOut, so a descriptor with only
    // attachment 0 no longer builds — which is the pipeline-side half of the
    // "every fragment writes both" rule.
    desc.colorAttachments[1].pixelFormat = .rgba8Uint
    _ = try device.makeRenderPipelineState(descriptor: desc)
```

In `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift`, add the optional sidecar
readback to `Frame` and to `frame(...)`:

```swift
    struct Frame {
        let scaled: [UInt16]
        let native: [UInt16]
        /// The SCALED sidecar, RGBA, four bytes per pixel — nil unless the
        /// caller asked for it. At scale 8 it is 134 MB to materialise, and
        /// every Gate 2 comparison is about VRAM.
        let sidecar: [UInt8]?
        let instances: [Ps1PrimInstance]
        let width: Int
        let height: Int
        let scale: Int
    }
```

```swift
    static func frame(scale: Int, payload: [UInt32] = [], preload: [UInt16]? = nil,
                      dither: DitherMode = .off, wantSidecar: Bool = false,
                      _ body: (MetalRasterizer) -> Void) throws -> Frame? {
```

…and in its `return`, plus the two other `Frame(...)` constructions in this file
(`fixtureFrame` returns `frame`'s value unchanged; `replayTo` builds its own):

```swift
        return Frame(scaled: vram.readback(), native: vram.readbackNative(),
                     sidecar: wantSidecar ? vram.readbackSidecar() : nil,
                     instances: instances, width: vram.width, height: vram.height,
                     scale: scale)
```

`replayTo` gains the same `wantSidecar: Bool = false` parameter and passes it
through the same way — Gate 3 in Task 7 is its caller.

- [ ] **Step 7: Run the new tests**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
zig build metallib && \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/theSidecarMirrorsVramWhereverItIsPresent \
  -only-testing:PS1Tests/theSidecarIsAbsentWhereVramWasUploaded \
  -only-testing:PS1Tests/aCopyCarriesPresenceWithThePixels \
  -only-testing:PS1Tests/bothUploadPathsInvalidateTheWholeSidecar 2>&1 | tail -20
```

Expected: four passes. `zig build metallib` first — the shaders are compiled
offline, so an MSL error must surface here rather than at the first frame.

- [ ] **Step 8: Run the whole suite — the primary assertion of this phase**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: all passing. **Gate 1's fixture hashes and Gate 2's
downsample-invariance must be green and unmodified.** VRAM's value is produced
by exactly the expressions it was before; if a hash moved, a fragment path
changed its first output and that is the bug — do not touch a fixture.

- [ ] **Step 9: Commit**

```bash
git add ps1-macos/Shaders/Ps1Color.h ps1-macos/Shaders/Rasterizer.metal \
        ps1-macos/Sources/PS1/MetalRasterizer.swift ps1-macos/Sources/PS1/MetalVram.swift \
        ps1-macos/Tests/PS1Tests/MetalVramTests.swift \
        ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift
git commit -m "$(cat <<'MSG'
feat(gpu): maintain the sidecar from every VRAM path

Second colour attachment on all four pipelines. Draws and fills maintain
it at five-bit precision, A0 uploads invalidate their destination rect,
an 80 copy carries it in the same pass, and both whole-texture uploads
clear it. No hash moves: VRAM's value comes from the same expressions.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014Kcgw8AXvMh8ZFNjtU5xFS
MSG
)"
```

---

### Task 3: The display reads the sidecar

Still no visible change — the sidecar is a mirror of `expand(VRAM)` until Task 4
— but this is where that mirror becomes load-bearing, so it is where the two
expansions have to be made the same expression.

**Files:**
- Modify: `ps1-macos/Shaders/DisplayShader.metal:46-52` (`unpack1555`), `:54-57`
  (the signature), `:118-124` (the 15bpp return)
- Modify: `ps1-macos/Sources/PS1/MetalDisplayView.swift:229-232` (bindings)
- Modify: `ps1-macos/Sources/PS1/LiveRenderer.swift:33` (expose the texture)
- Modify: `ps1-macos/Tests/PS1Tests/DisplayPassHarness.swift`
- Test: `ps1-macos/Tests/PS1Tests/DisplayRenderTests.swift`

**Interfaces:**
- Consumes: `MetalVram.sidecar` (Task 1); the presence semantics (Task 2).
- Produces:
  - MSL: `display_fragment` takes `texture2d<uint, access::read> sidecar [[texture(2)]]`.
  - Swift: `LiveRenderer.sidecarTexture: MTLTexture`.
  - Swift: `renderDisplayPass(device:queue:vram:shadow:sidecar:params:width:height:)`
    — the `sidecar` argument is new and sits after `shadow`.

- [ ] **Step 1: Write the failing tests**

In `ps1-macos/Tests/PS1Tests/DisplayRenderTests.swift`, add a sidecar builder
beside `makeVramTexture`:

```swift
private func makeSidecarTexture(_ device: MTLDevice,
                                fill: (UInt8, UInt8, UInt8, UInt8)) -> MTLTexture? {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Uint, width: 1024, height: 512, mipmapped: false)
    desc.usage = .shaderRead
    desc.storageMode = .managed
    guard let tex = device.makeTexture(descriptor: desc) else { return nil }
    var bytes = [UInt8](repeating: 0, count: 1024 * 512 * 4)
    for i in 0..<(1024 * 512) {
        bytes[i * 4] = fill.0; bytes[i * 4 + 1] = fill.1
        bytes[i * 4 + 2] = fill.2; bytes[i * 4 + 3] = fill.3
    }
    bytes.withUnsafeBytes { buf in
        tex.replace(region: MTLRegionMake2D(0, 0, 1024, 512), mipmapLevel: 0,
                    withBytes: buf.baseAddress!, bytesPerRow: 1024 * 4)
    }
    return tex
}
```

…extend `render(...)` with a `sidecar` parameter (default absent, so every
existing test keeps its current meaning):

```swift
private func render(width: Int, height: Int,
                    depth24: Bool = false,
                    softwareDisplay: Bool = false,
                    vramFill: UInt16 = 0x7FFF,
                    sidecar: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) throws -> Rendered? {
```

…building `makeVramTexture(device, fill: vramFill)` and
`makeSidecarTexture(device, fill: sidecar)` and passing the latter to
`renderDisplayPass`. Then append the tests:

```swift
@Test func theDisplayPrefersTheSidecarWherePresent() throws {
    // Alpha 255: the sidecar holds a real eight-bit colour and the display
    // shows it rather than the five-bit VRAM pixel beneath. The render
    // texture is white, so anything but this exact triple means the fallback
    // ran instead.
    guard let r = try render(width: 320, height: 240,
                             sidecar: (10, 20, 30, 255)) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr == 10)
    #expect(g == 20)
    #expect(b == 30)
}

@Test func theDisplayFallsBackToVramWhereTheSidecarIsAbsent() throws {
    // Alpha 0: whatever the sidecar's colour bytes happen to hold is ignored.
    // Every invalidation degrades to today's picture, which is the whole
    // reason presence is a channel rather than a dirty rectangle.
    guard let r = try render(width: 320, height: 240,
                             sidecar: (10, 20, 30, 0)) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr > 240 && g > 240 && b > 240)
}

@Test func anAbsentPixelExpandsByReplicationJustLikeASidecarPixel() throws {
    // The fallback and the sidecar must be the SAME expansion, or the boundary
    // of an invalidated rect shows as a seam — one level of difference along a
    // hard edge is exactly the kind of artifact this feature exists to remove.
    //
    // Red = 3: `c << 3 | c >> 2` is 24, which is what the sidecar would hold
    // for that pixel. The old `c / 31.0` is 24.67 and rounds to 25.
    guard let r = try render(width: 320, height: 240, vramFill: 0x0003) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr == 24)
    #expect(g == 0)
    #expect(b == 0)
}

@Test func twentyFourBppIgnoresTheSidecar() throws {
    // FMV scans out of the 1x shadow permanently: it byte-packs across
    // adjacent 16-bit words, arithmetic N x N replication destroys. A present
    // sidecar must not divert it — Croc and Silent Hill both depend on this.
    guard let r = try render(width: 320, height: 240, depth24: true,
                             sidecar: (10, 20, 30, 255)) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr == 0x1F)
    #expect(g == 0x00)
    #expect(b == 0x1F)
}

@Test func theSoftwareDisplaySeamIgnoresTheSidecar() throws {
    // PS1_SOFTWARE_DISPLAY exists to A/B a suspect frame against the software
    // rasterizer. A sidecar read here would be comparing the new path against
    // itself.
    guard let r = try render(width: 320, height: 240, softwareDisplay: true,
                             sidecar: (10, 20, 30, 255)) else { return }
    let (b, g, rr) = r.pixel(160, 120)
    #expect(rr > 240)
    #expect(g < 16)
    #expect(b < 16)
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/theDisplayPrefersTheSidecarWherePresent 2>&1 | tail -20
```

Expected: compile failure — `renderDisplayPass` has no `sidecar:` argument.

- [ ] **Step 3: Teach the display shader to read it**

In `ps1-macos/Shaders/DisplayShader.metal`, replace `unpack1555`:

```c
/// ABGR1555 -> linear float, with the five-bit channels expanded by
/// REPLICATION (`c << 3 | c >> 2`) rather than divided by 31.
///
/// The two must be the same expansion. This is the fallback for a pixel the
/// sidecar has marked absent, and the sidecar itself holds `c << 3 | c >> 2`
/// for every five-bit-derived pixel — so a different expression here would
/// draw a one-level seam along the boundary of every invalidated rect. It is
/// also what `VramImage.write` has always used for a dump, for the reason its
/// own comment gives.
static float4 unpack1555(uint texel) {
    uint r = texel & 0x1F, g = (texel >> 5) & 0x1F, b = (texel >> 10) & 0x1F;
    return float4(float((r << 3) | (r >> 2)) / 255.0,
                  float((g << 3) | (g >> 2)) / 255.0,
                  float((b << 3) | (b >> 2)) / 255.0,
                  1.0);
}
```

Add the third texture to the signature:

```c
fragment float4 display_fragment(VertexOut in [[stage_in]],
                                 texture2d<uint, access::read> vram [[texture(0)]],
                                 texture2d<uint, access::read> shadow [[texture(1)]],
                                 texture2d<uint, access::read> sidecar [[texture(2)]],
                                 constant Params& p [[buffer(0)]]) {
```

…and replace the final 15bpp return:

```c
    // The eight-bit sidecar where it has something to say, VRAM expanded where
    // it does not. Alpha is PRESENCE, not opacity: 255 means this pixel's
    // eight-bit colour was written by the draw that produced the VRAM pixel
    // beneath it. Nothing here consults the dither mode — the sidecar's
    // CONTENT is what the mode decides, in Rasterizer.metal.
    uint2 addr = uint2(col * p.scale + sub_x, row * p.scale + sub_y);
    uint4 side = sidecar.read(addr);
    if (side.a != 0) {
        return float4(float(side.r) / 255.0, float(side.g) / 255.0,
                      float(side.b) / 255.0, 1.0);
    }
    // The wrap is NATIVE, then scaled. A scaled mask `& (1024 * s - 1)` -- the
    // form the parent spec specifies -- is a modulo only at power-of-two s and
    // samples the wrong column at s = 3.
    return unpack1555(vram.read(addr).r);
```

- [ ] **Step 4: Bind it from the app and from the harness**

In `ps1-macos/Sources/PS1/LiveRenderer.swift`, beside `var texture`:

```swift
    var texture: MTLTexture { vram.texture }
    /// The display-only eight-bit sidecar. Exposed the same way `texture` is:
    /// the coordinator binds it, and nothing else in the app reads it.
    var sidecarTexture: MTLTexture { vram.sidecar }
```

In `ps1-macos/Sources/PS1/MetalDisplayView.swift`'s `draw(in:)`:

```swift
            // ALL THREE bindings, always: an unbound texture2d is a Metal
            // validation failure, not a black pixel.
            enc.setFragmentTexture(live.texture, index: 0)
            enc.setFragmentTexture(shadowTexture, index: 1)
            enc.setFragmentTexture(live.sidecarTexture, index: 2)
```

In `ps1-macos/Tests/PS1Tests/DisplayPassHarness.swift`, add the parameter and
the binding:

```swift
func renderDisplayPass(device: MTLDevice, queue: MTLCommandQueue,
                       vram: MTLTexture, shadow: MTLTexture, sidecar: MTLTexture,
                       params: DisplayParams, width: Int, height: Int)
    throws -> [UInt8]?
```

```swift
    enc.setFragmentTexture(vram, index: 0)
    enc.setFragmentTexture(shadow, index: 1)
    enc.setFragmentTexture(sidecar, index: 2)
```

Update every other call site of `renderDisplayPass` — `grep -rn
"renderDisplayPass" ps1-macos/Tests` — to pass an absent sidecar
(`makeSidecarTexture(device, fill: (0, 0, 0, 0))`), which preserves each
existing test's meaning exactly.

- [ ] **Step 5: Run the display tests**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
zig build metallib && \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests 2>&1 | grep -E "DisplayRender|Display.*Tests|✘|Failing" | head -30
```

Expected: every `DisplayRenderTests` case passes, the five new ones included.
`fifteenBppScansOutOfTheRenderTextureNotTheShadow` still asserts `> 240` and 31
expands to 255 under either expression, so it is unaffected.

- [ ] **Step 6: Run the whole suite**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: all passing.

- [ ] **Step 7: Look at it**

```bash
zig build capi-lib && zig build metallib && zig build macos
open zig-out/Substation.app
```

Boot any game. The picture must be **indistinguishable** from before this
branch: the sidecar still holds `expand(VRAM)` everywhere it is present, and
the fallback is now the same expansion. This is the last point at which "no
visible change" is the correct outcome; note in the commit that it was checked.

- [ ] **Step 8: Commit**

```bash
git add ps1-macos/Shaders/DisplayShader.metal ps1-macos/Sources/PS1/MetalDisplayView.swift \
        ps1-macos/Sources/PS1/LiveRenderer.swift \
        ps1-macos/Tests/PS1Tests/DisplayPassHarness.swift \
        ps1-macos/Tests/PS1Tests/DisplayRenderTests.swift
git commit -m "$(cat <<'MSG'
feat(gpu): the display reads the sidecar where it is present

Alpha is presence; an absent pixel falls back to VRAM expanded by
replication — now the same expression on both sides, so the boundary of
an invalidated rect cannot show a seam. 24bpp and PS1_SOFTWARE_DISPLAY
still scan out of the shadow. Verified by eye: no visible change yet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014Kcgw8AXvMh8ZFNjtU5xFS
MSG
)"
```

---

### Task 4: `.trueColor` — eight bits into the sidecar

The spec's four named gates map onto this plan's tests as:
`theSidecarIsAbsentWhereVramWasUploaded` (Task 2, same name),
`aCopiedGradientKeepsItsPrecision` (below, same name),
`theSidecarNeverReachesTexelFetch` (below, same name), and the spec's
`trueColourAndDitheringAreMutuallyExclusive` is written here as
**`trueColourNeverAppliesADitherOffset`** — the same assertion, named for what
is checked (no offset reaches VRAM) rather than for the property it
establishes, because the property is a design fact and the offset is the thing a
regression would move.

**Files:**
- Modify: `ps1-macos/Shaders/PrimInstance.h` (the `PS1_DITHER_*` enum and its comment)
- Modify: `ps1-macos/Shaders/Ps1Color.h` (`ps1_modulate`'s out-param)
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_sample`, `ps1_prim_fragment`)
- Modify: `ps1-macos/Sources/PS1/DitherMode.swift` (the fourth case — NOT the default yet)
- Test: `ps1-macos/Tests/PS1Tests/TrueColourTests.swift` (create)

**Interfaces:**
- Consumes: `Ps1FragOut`, `ps1_out`, `ps1_expand`, `ps1_pack8` (Task 2);
  `MetalScaleHarness.frame(..., wantSidecar:)` (Task 2).
- Produces:
  - C: `PS1_DITHER_TRUE_COLOR = 3` in `PrimInstance.h`.
  - Swift: `DitherMode.trueColor` (raw value 3), `title` == `"True Colour"`.
  - MSL: `ushort ps1_modulate(ushort texel, ushort color, int dither_o, thread ushort3& out8)`
    — the return value is unchanged (the 5-bit ABGR1555 result); `out8` is the
    eight-bit triple the same expression was built from.
  - MSL: `bool ps1_sample(const device Ps1PrimInstance& p, texture2d<ushort, access::read> vram,
    uint s, uint u, uint v, int dither_o, ushort shade, bool true_colour,
    thread ushort& out, thread ushort3& out8)`.

**The default does not move in this task.** `DitherSetting.defaultMode` stays
`.scaled` until Task 6, so every existing gate keeps running at exactly the mode
it runs at today while the new mode is built and tested explicitly.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/TrueColourTests.swift`:

```swift
import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

/// True colour's own gates.
///
/// The primary assertion of the whole feature is negative: a rendering change
/// that moves no hash. VRAM in `.trueColor` is byte-identical to VRAM in
/// `.off`, which is a mode every existing gate already covers; the difference
/// lives entirely in the sidecar, which no gate reads.

/// Draws a shallow Gouraud ramp with GP0(E1) bit 9 set — a channel that changes
/// by well under one 8-bit step per pixel, which is where a ±4 dither offset
/// decides the output and a 5-bit truncation bands. The same geometry
/// `scaledDitheringActuallyChangesThePictureAboveOneX` uses, for the same
/// reason.
private func ditheredRamp(_ r: MetalRasterizer) {
    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023
    r.apply(area)

    var mode = Ps1GpuCommand()
    mode.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    mode.opcode = 0xE1
    mode.value = 1 << 9
    r.apply(mode)

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
    tri.v.0 = Ps1GpuVertex(x: 4, y: 4, u: 0, v: 0, _pad: 0, color: 0x0040_4040)
    tri.v.1 = Ps1GpuVertex(x: 500, y: 8, u: 0, v: 0, _pad: 0, color: 0x0050_5050)
    tri.v.2 = Ps1GpuVertex(x: 8, y: 300, u: 0, v: 0, _pad: 0, color: 0x0048_4848)
    r.apply(tri)
}

@Test func trueColourNeverAppliesADitherOffset() throws {
    // Mutually exclusive BY CONSTRUCTION: DuckStation asserts the same thing
    // (gpu_hw_shadergen.cpp:2479), and it is why this is a fourth case of
    // DitherMode rather than a second control beside it. Two controls that
    // cannot both be on is a control that silently no-ops.
    guard let off = try MetalScaleHarness.frame(scale: 1, dither: .off, ditheredRamp),
          let tc = try MetalScaleHarness.frame(scale: 1, dither: .trueColor, ditheredRamp),
          let nat = try MetalScaleHarness.frame(scale: 1, dither: .native, ditheredRamp)
    else { return }
    #expect(tc.native == off.native, "a dither offset reached VRAM in .trueColor")
    // The control: without this the test passes for a mode that does nothing.
    #expect(nat.native != off.native, "the ramp carries no dithered primitive")
}

@Test func theCorpusRendersIdenticalVramInTrueColourAndOff() throws {
    // The "moves no hash" claim, over real recorded streams rather than one
    // hand-built triangle. `.off` is a mode every existing gate already runs
    // at, so equality with it is what lets true colour ship as the default
    // without a gate exemption.
    for name in ["synthetic-primitives", "synthetic-movers"] {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let a = MetalVram(device: device, queue: queue),
              let b = MetalVram(device: device, queue: queue) else { return }
        let offR = try MetalRasterizer(vram: a)
        let tcR = try MetalRasterizer(vram: b)
        offR.ditherMode = .off
        tcR.ditherMode = .trueColor

        let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
        withExtendedLifetime(file) {
            for i in 0..<file.frames.count {
                for r in [offR, tcR] {
                    r.beginFrame(payload: file.payload(for: i))
                    for cmd in file.records(for: i) { r.apply(cmd) }
                    r.endFrame()
                }
                #expect(a.hash == b.hash,
                        Comment(rawValue: "\(name) frame \(i): VRAM differs between .off and .trueColor"))
            }
        }
    }
}

@Test func aGouraudRampKeepsMoreThanThirtyTwoLevelsInTheSidecar() throws {
    // The reported defect, stated as a number. Dithering redistributes
    // quantisation error; it cannot add levels, and a 5-bit channel has 32 of
    // them at every internal resolution. This is what the sidecar buys.
    guard let tc = try MetalScaleHarness.frame(scale: 1, dither: .trueColor,
                                               wantSidecar: true, ditheredRamp),
          let side = tc.sidecar else { return }

    var vramLevels = Set<UInt16>()
    var sideLevels = Set<UInt8>()
    for i in 0..<tc.scaled.count where side[i * 4 + 3] == 255 {
        vramLevels.insert(tc.scaled[i] & 0x1F)
        sideLevels.insert(side[i * 4])
    }
    #expect(vramLevels.count <= 32)
    #expect(sideLevels.count > 32,
            "the sidecar has \(sideLevels.count) red levels — it is still five-bit data")
}

@Test func aFlatUntexturedDrawKeepsTheFiveBitCarveOut() throws {
    // DuckStation's ShouldTruncate32To16 (gpu_hw.cpp:167) still truncates a
    // draw that is untextured, unshaded AND undithered, with per-game traits
    // overriding it both ways. We adopt the carve-out and not the second menu
    // entry: a flat draw has no extra precision to carry, so it writes the
    // expansion of its own five-bit colour and there is nothing to choose.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    r.ditherMode = .trueColor

    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
    tri.value = 0x2955
    tri.v.0 = Ps1GpuVertex(x: 10, y: 10, u: 0, v: 0, _pad: 0, color: 0)
    tri.v.1 = Ps1GpuVertex(x: 200, y: 10, u: 0, v: 0, _pad: 0, color: 0)
    tri.v.2 = Ps1GpuVertex(x: 10, y: 200, u: 0, v: 0, _pad: 0, color: 0)

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(area); r.apply(tri)
    r.endFrame()

    let side = vram.readbackSidecar()
    let i = 50 * 1024 + 50
    #expect(side[i * 4 + 3] == 255)
    // 0x2955 is r = 21, g = 10, b = 5.
    #expect(side[i * 4] == UInt8((21 << 3) | (21 >> 2)))
    #expect(side[i * 4 + 1] == UInt8((10 << 3) | (10 >> 2)))
    #expect(side[i * 4 + 2] == UInt8((5 << 3) | (5 >> 2)))
}

@Test func theSidecarNeverReachesTexelFetch() throws {
    // DuckStation samples indexed texture data out of its RGBA8 target and
    // converts back down. Ours keeps reading r16Uint, so on this axis the
    // sidecar is MORE accurate than the reference — and the way to prove it is
    // that a draw which samples a true-colour region produces the same VRAM as
    // the same draw in `.off`, where the sidecar holds nothing extra.
    func draw(_ r: MetalRasterizer) {
        var area = Ps1GpuCommand()
        area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        area.opcode = 0xE4
        area.value = (511 << 10) | 1023
        r.apply(area)

        // A ramp into the 16bpp texture page at (256, 0) — the region the
        // sprite below samples. Its low three bits per channel are exactly
        // what the sidecar keeps and VRAM does not.
        var ramp = Ps1GpuCommand()
        ramp.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
        ramp.v.0 = Ps1GpuVertex(x: 256, y: 0, u: 0, v: 0, _pad: 0, color: 0x0011_2233)
        ramp.v.1 = Ps1GpuVertex(x: 500, y: 4, u: 0, v: 0, _pad: 0, color: 0x00AA_BBCC)
        ramp.v.2 = Ps1GpuVertex(x: 260, y: 60, u: 0, v: 0, _pad: 0, color: 0x0055_6677)
        r.apply(ramp)

        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = 0x65                 // RAW: no modulation
        spr.tpage = 0x0104                // page x 4 (-> 256), 16bpp
        spr.x = 0; spr.y = 300; spr.w = 32; spr.h = 16
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        r.apply(spr)
    }

    guard let off = try MetalScaleHarness.frame(scale: 1, dither: .off, draw),
          let tc = try MetalScaleHarness.frame(scale: 1, dither: .trueColor, draw)
    else { return }
    #expect(tc.native == off.native, "the sidecar leaked into a texel fetch")
    // The control: the ramp really does have sub-five-bit detail to leak.
    guard let side = try MetalScaleHarness.frame(scale: 1, dither: .trueColor,
                                                 wantSidecar: true, draw)?.sidecar
    else { return }
    let i = 30 * 1024 + 300
    #expect(side[i * 4 + 3] == 255)
    let vramR = Int(tc.native[i] & 0x1F)
    #expect(Int(side[i * 4]) != ((vramR << 3) | (vramR >> 2)),
            "the ramp carries no sub-five-bit detail at this pixel")
}

@Test func aCopiedGradientKeepsItsPrecision() throws {
    // GP0(80) carries the sidecar in the same pass as VRAM, so an eight-bit
    // gradient survives a VRAM->VRAM blit — which is how a game's own
    // double-buffering or scroll does not silently re-quantise the picture.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    r.ditherMode = .trueColor

    var copy = Ps1GpuCommand()
    copy.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    copy.x = 4; copy.y = 4          // source: inside the ramp
    copy.x2 = 600; copy.y2 = 400    // destination: blank
    copy.w = 64; copy.h = 64

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    ditheredRamp(r)
    r.apply(copy)
    r.endFrame()

    let side = vram.readbackSidecar()
    // Hoisted: `readback()` is a synchronous blit plus a 1 MB array, and
    // calling it per pixel turns this test into 4,096 round trips to the GPU.
    let pixels = vram.readback()
    var compared = 0
    var extra = 0
    for dy in 0..<64 {
        for dx in 0..<64 {
            let s = ((4 + dy) * 1024 + 4 + dx) * 4
            let d = ((400 + dy) * 1024 + 600 + dx) * 4
            guard side[s + 3] == 255 else { continue }
            compared += 1
            #expect(side[d] == side[s] && side[d + 1] == side[s + 1]
                    && side[d + 2] == side[s + 2] && side[d + 3] == 255,
                    "the copy re-quantised (\(dx), \(dy))")
            let r5 = Int(pixels[(400 + dy) * 1024 + 600 + dx] & 0x1F)
            if Int(side[d]) != ((r5 << 3) | (r5 >> 2)) { extra += 1 }
        }
    }
    #expect(compared > 1000)
    #expect(extra > 0, "the copied region carries no sub-five-bit detail to keep")
}

@Test func aBlendedDrawStillFallsBackToFiveBitsInMilestoneOne() throws {
    // The milestone boundary, pinned so milestone 2 has a test to CHANGE
    // rather than a silent gap to fill. The blend path still reads VRAM and
    // writes the expansion of its five-bit result: a 5-bit blend is not the
    // truncation of an 8-bit blend, so carrying precision across a composite
    // is its own piece of work, and the spec gates it on finding a scene that
    // bands BECAUSE of layered blending.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    r.ditherMode = .trueColor

    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023

    var tri = Ps1GpuCommand()
    tri.kind = UInt8(PS1_GPU_DRAW_SHADED_TRIANGLE.rawValue)
    tri.transparent = 1
    tri.v.0 = Ps1GpuVertex(x: 10, y: 10, u: 0, v: 0, _pad: 0, color: 0x0011_2233)
    tri.v.1 = Ps1GpuVertex(x: 200, y: 14, u: 0, v: 0, _pad: 0, color: 0x00AA_BBCC)
    tri.v.2 = Ps1GpuVertex(x: 14, y: 200, u: 0, v: 0, _pad: 0, color: 0x0055_6677)

    r.beginFrame(payload: UnsafeBufferPointer(start: nil, count: 0))
    r.apply(area); r.apply(tri)
    r.endFrame()

    let pixels = vram.readback()
    let side = vram.readbackSidecar()
    let i = 60 * 1024 + 60
    #expect(side[i * 4 + 3] == 255)
    let p = pixels[i]
    for (c, ch) in [(Int(p & 0x1F), 0), (Int((p >> 5) & 0x1F), 1), (Int((p >> 10) & 0x1F), 2)] {
        #expect(side[i * 4 + ch] == UInt8((c << 3) | (c >> 2)))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/trueColourNeverAppliesADitherOffset 2>&1 | tail -20
```

Expected: compile failure — `type 'DitherMode' has no member 'trueColor'`.

- [ ] **Step 3: Declare the mode on both sides**

In `ps1-macos/Shaders/PrimInstance.h`, extend the enum and its comment block:

```c
 * TRUE_COLOR turns the dithering off and writes the pre-truncation EIGHT-BIT
 * value to the display sidecar instead. Dithering redistributes quantisation
 * error; it cannot add levels, and a 5-bit channel has 32 of them at every
 * internal resolution — which is the ceiling the other three modes work under.
 * VRAM is written exactly as it is at OFF, so no hash moves and the mode needs
 * no gate exemption. It is mutually exclusive with dithering by construction,
 * which is why it is a fourth case here rather than a second setting beside
 * this one: two controls that cannot both be on is a control that silently
 * no-ops.
 */
enum {
    PS1_DITHER_OFF = 0,
    PS1_DITHER_NATIVE = 1,
    PS1_DITHER_SCALED = 2,
    PS1_DITHER_TRUE_COLOR = 3
};
```

In `ps1-macos/Sources/PS1/DitherMode.swift`, add the case, its title and the
doc bullet (leave `DitherSetting.defaultMode` at `.scaled` — Task 6 moves it):

```swift
    case off = 0
    case native = 1
    case scaled = 2
    case trueColor = 3
```

```swift
        case .trueColor: return "True Colour"
```

In `ps1-macos/Tests/PS1Tests/DitherModeTests.swift`, `allCases` grows here, so
bump the one assertion that counts it (the default-related cases move in Task 6):

```swift
@Test func everyModeHasADistinctMenuTitle() {
    // `DitherMode.allCases` is what builds the Video menu picker, so a missing
    // case is a mode the player cannot select and a duplicated title is two
    // menu items that read the same.
    let titles = DitherMode.allCases.map(\.title)
    #expect(titles.count == 4)
    #expect(Set(titles).count == titles.count)
}
```

…and in the type comment, after the `.off` bullet:

```swift
/// - `.trueColor` turns dithering off and keeps the pre-truncation eight-bit
///   colour in a display-only sidecar texture, so a Gouraud ramp has 256 levels
///   per channel instead of 32. VRAM is written exactly as it is at `.off`, so
///   nothing a gate reads can move — which is what lets this be the default at
///   every internal resolution, 1x included. DuckStation has to rebuild
///   pipelines for the equivalent setting and gives up bit-exactness to get the
///   smoothness; we give up neither.
```

- [ ] **Step 4: Carry eight bits through the shader**

In `ps1-macos/Shaders/Ps1Color.h`, give `ps1_modulate` the out-param:

```c
/// color.zig's `modulate`: texel * vertex-colour at 8-bit scale, i.e.
/// `(t << 3) * (c << 3) >> 7` == `(t * c) >> 1`. Working at 8-bit scale is
/// what makes the dither offsets mean what they say. Keeps `texel & 0x8000` —
/// a textured primitive's semi-transparency bit lives there.
///
/// `dither_o` is the offset already resolved by the caller, which picks the
/// coordinate the pattern is indexed by; 0 is the no-op, so there is no branch.
///
/// `out8` hands back the three channels BEFORE the `>> 3`, which is what the
/// true-colour sidecar stores. The shade is still truncated to five bits first
/// — a knowing divergence from hardware (which modulates an 8-bit shade against
/// a 5-bit texel, `>> 7`) that the flat path has always had. Do NOT "fix" it
/// here: it would move every textured pixel in every game, and it is VRAM's
/// value that every gate reads.
inline ushort ps1_modulate(ushort texel, ushort color, int dither_o,
                           thread ushort3& out8) {
    int tr = texel & 0x1F, tg = (texel >> 5) & 0x1F, tb = (texel >> 10) & 0x1F;
    int cr = color & 0x1F, cg = (color >> 5) & 0x1F, cb = (color >> 10) & 0x1F;
    int r = ((tr * cr) >> 1) + dither_o;
    int g = ((tg * cg) >> 1) + dither_o;
    int b = ((tb * cb) >> 1) + dither_o;
    out8 = ps1_pack8(r, g, b);
    return ps1_pack(r, g, b) | (texel & 0x8000);
}
```

In `ps1-macos/Shaders/Rasterizer.metal`, give `ps1_sample` the flag and the
out-param:

```c
inline bool ps1_sample(const device Ps1PrimInstance& p,
                       texture2d<ushort, access::read> vram, uint s,
                       uint u, uint v, int dither_o,
                       ushort shade, bool true_colour,
                       thread ushort& out, thread ushort3& out8) {
    ...
    ushort texel = ps1_fetch_texel(vram, s, p.tex_depth, p.tpage_x, p.tpage_y,
                                   p.clut_x, p.clut_y, final_u, final_v);
    if (texel == 0) return false;
    if (p.flags & PS1_PRIM_MODULATE) {
        ushort3 mod8;
        out = ps1_modulate(texel, shade, dither_o, mod8);
        out8 = true_colour ? mod8 : ps1_expand(out);
    } else {
        // A RAW texel is genuine five-bit data out of VRAM — there is no extra
        // precision anywhere to carry, in any mode.
        out = texel;
        out8 = ps1_expand(texel);
    }
    return true;
}
```

In `ps1_prim_fragment`, after `bool transparent = ...`:

```c
    bool transparent = (p.flags & PS1_PRIM_TRANSPARENT) != 0;
    // True colour and dithering are mutually exclusive by construction: the
    // dither_o chain above matches only SCALED and NATIVE, so dither_o is
    // already 0 here and the shaded paths simply keep their eight bits.
    bool true_colour = (uni.dither_mode == PS1_DITHER_TRUE_COLOR);
    ushort src;
    ushort3 src8;
```

Then in each branch:

```c
    if (p.kind == PS1_PRIM_FLAT_TRI) {
        ...
        src = ushort(p.color);
        // The flat-colour carve-out: untextured, unshaded and undithered, so
        // its five-bit colour expands exactly and there is no eight-bit value
        // it could have written instead.
        src8 = ps1_expand(src);
    } else if (p.kind == PS1_PRIM_GOURAUD_TRI) {
        ...
        src = ps1_pack(r + dither_o, g + dither_o, b + dither_o);
        src8 = true_colour ? ps1_pack8(r, g, b) : ps1_expand(src);
    } else if (p.kind == PS1_PRIM_TEXTURED_TRI) {
        ...
        if (!ps1_sample(p, vram, uint(s), u, v, dither_o, shade, true_colour, src, src8)) {
            discard_fragment(); return ps1_discarded();
        }
        transparent = transparent && (src & 0x8000) != 0;
    } else if (p.kind == PS1_PRIM_RECT) {
        src = ushort(p.color);
        src8 = ps1_expand(src);              // the carve-out again
    } else if (p.kind == PS1_PRIM_LINE_PIXEL) {
        src = ushort(p.color);
        src8 = ps1_expand(src);              // a mono line never dithers either
    } else if (p.kind == PS1_PRIM_SHADED_LINE_PIXEL) {
        ...
        src = ps1_pack(r + dither_o, g + dither_o, b + dither_o);
        src8 = true_colour ? ps1_pack8(r, g, b) : ps1_expand(src);
    } else if (p.kind == PS1_PRIM_TEXTURED_RECT) {
        ...
        if (!ps1_sample(p, vram, uint(s), u, v, dither_o, ushort(p.color),
                        true_colour, src, src8)) {
            discard_fragment(); return ps1_discarded();
        }
        transparent = transparent && (src & 0x8000) != 0;
    } else {
        discard_fragment();
        return ps1_discarded();
    }
```

…and the tail:

```c
    ushort out = transparent ? ps1_blend(dst, src, p.blend_mode) : src;
    // MILESTONE 1: a blend re-quantises, and the sidecar says so by holding the
    // expansion of the five-bit result. A 5-bit blend is NOT the truncation of
    // an 8-bit blend — ps1_blend's integer halving differs from the same
    // operation at eight bits by up to an LSB per layer — so carrying precision
    // across a composite needs an eight-bit sibling of ps1_blend and an
    // eight-bit background, which is milestone 2 and is gated on finding a
    // scene that bands because of layered blending.
    ushort3 out8 = transparent ? ps1_expand(out) : src8;

    if (p.flags & PS1_PRIM_SET_MASK) out |= 0x8000;
    return ps1_out(out, out8);
```

- [ ] **Step 5: Run the new tests**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
zig build metallib && \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/trueColourNeverAppliesADitherOffset \
  -only-testing:PS1Tests/theCorpusRendersIdenticalVramInTrueColourAndOff \
  -only-testing:PS1Tests/aGouraudRampKeepsMoreThanThirtyTwoLevelsInTheSidecar \
  -only-testing:PS1Tests/aFlatUntexturedDrawKeepsTheFiveBitCarveOut \
  -only-testing:PS1Tests/theSidecarNeverReachesTexelFetch \
  -only-testing:PS1Tests/aCopiedGradientKeepsItsPrecision \
  -only-testing:PS1Tests/aBlendedDrawStillFallsBackToFiveBitsInMilestoneOne 2>&1 | tail -25
```

Expected: seven passes.

- [ ] **Step 6: Run the whole suite**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: all passing — including `everyModeHasADistinctMenuTitle`, whose count
is bumped in Step 3 above. `DitherMode.allCases` grows in THIS task, so the
assertion that counts it belongs here; Task 6 changes only the default.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Shaders/PrimInstance.h ps1-macos/Shaders/Ps1Color.h \
        ps1-macos/Shaders/Rasterizer.metal ps1-macos/Sources/PS1/DitherMode.swift \
        ps1-macos/Tests/PS1Tests/TrueColourTests.swift
git commit -m "$(cat <<'MSG'
feat(gpu): .trueColor writes eight bits to the sidecar

Gouraud triangles, shaded lines and modulated texels keep their
pre-truncation channels; flat and raw-textured draws keep the five-bit
carve-out, which is all they ever had. VRAM is byte-identical to .off on
the whole fixture corpus. Blending still re-quantises — milestone 2.

Not the default yet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014Kcgw8AXvMh8ZFNjtU5xFS
MSG
)"
```

---

### Task 5: Gate 1 pins its own dither mode

`MetalFixtureHarness.replay` has never set `ditherMode`, so Gate 1 has always
inherited `DitherSetting.defaultMode`. That was harmless while the default was
`.scaled` — at 1x it is the same expression as `.native`, which is what the
dithering software rasterizer produces. It stops being harmless the moment the
default becomes a mode that does not dither, and the failure would present as
"every fixture hash moved", which is the most alarming possible symptom for a
change that moves no hash at all.

**Files:**
- Modify: `ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift:22-28`
- Test: `ps1-macos/Tests/PS1Tests/TrueColourTests.swift`

**Interfaces:**
- Consumes: `DitherMode.trueColor` (Task 4).
- Produces: `MetalFixtureHarness.replay(_:upTo:dither:)` — `dither` defaults to
  `.native` and is no longer taken from the player's setting.

- [ ] **Step 1: Write the failing test**

Append to `ps1-macos/Tests/PS1Tests/TrueColourTests.swift`:

```swift
@Test func gateOneRunsAtADitheringModeRatherThanThePlayersDefault() throws {
    // Gate 1 compares against the fixture's own Zig hash, and `renderer.zig`
    // dithers whenever GP0(E1) bit 9 is set. The mode the harness runs at is
    // therefore part of the gate, not a preference — and it had been inherited
    // from DitherSetting.defaultMode, which is about to stop dithering.
    //
    // The divergence below is not a bug. It is the evidence that the pin is
    // load-bearing: without it, flipping the default turns every fixture hash
    // red and reads as a rendering regression.
    guard let tc = try MetalFixtureHarness.replay("synthetic-primitives",
                                                   upTo: 2, dither: .trueColor)
    else { return }
    #expect(tc.firstDivergence != nil,
            "frame 1 carries no dithered primitive — pin the gate with a frame that does")

    guard let nat = try MetalFixtureHarness.replay("synthetic-primitives",
                                                    upTo: 2, dither: .native)
    else { return }
    #expect(nat.firstDivergence == nil, Comment(rawValue: nat.message))
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/gateOneRunsAtADitheringModeRatherThanThePlayersDefault 2>&1 | tail -20
```

Expected: compile failure — `replay` has no `dither:` argument.

- [ ] **Step 3: Pin the mode in the harness**

In `ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift`:

```swift
    /// `upTo` bounds the replay to the first N frames — the gate ladder in
    /// Tasks 6-10 walks `synthetic-primitives` one frame at a time, because a
    /// hash is cumulative and a later frame's mismatch would otherwise mask an
    /// earlier feature that already works.
    ///
    /// `dither` is PINNED here rather than inherited from
    /// `DitherSetting.defaultMode`, and the default is `.native` rather than
    /// whatever ships. This gate's reference is the software rasterizer, which
    /// dithers whenever GP0(E1) bit 9 is set, so a mode is part of the gate;
    /// `.scaled` is the same expression at 1x and `.trueColor` deliberately is
    /// not. Inheriting the player's setting made the shipped default decide
    /// what every fixture hash was compared against.
    static func replay(_ name: String, upTo: Int? = nil,
                       dither: DitherMode = .native) throws -> ReplayResult? {
        ...
        let renderer = try MetalRasterizer(vram: vram)
        renderer.ditherMode = dither
```

- [ ] **Step 4: Run the test and the gate ladder**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/gateOneRunsAtADitheringModeRatherThanThePlayersDefault \
  -only-testing:PS1Tests/flatTrianglesMatchTheSoftwareRasterizer \
  -only-testing:PS1Tests/gouraudTrianglesAndDitherMatchTheSoftwareRasterizer \
  -only-testing:PS1Tests/texturedTrianglesMatchTheSoftwareRasterizer \
  -only-testing:PS1Tests/rectanglesAndSpritesMatchTheSoftwareRasterizer \
  -only-testing:PS1Tests/linesMatchTheSoftwareRasterizer 2>&1 | tail -20
```

Expected: all pass. The four ladder tests are unchanged in behaviour — at 1x
`.native` and `.scaled` are the same expression, which is exactly why this pin
can be made before the default moves rather than after.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift ps1-macos/Tests/PS1Tests/TrueColourTests.swift
git commit -m "$(cat <<'MSG'
test(gpu): Gate 1 pins its dither mode instead of inheriting it

The fixture hashes are compared against a software rasterizer that
dithers, so the mode is part of the gate rather than a preference. It had
been reading DitherSetting.defaultMode, which is about to stop dithering.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014Kcgw8AXvMh8ZFNjtU5xFS
MSG
)"
```

---

### Task 6: True colour becomes the default, and reaches the menu

**Files:**
- Modify: `ps1-macos/Sources/PS1/DitherMode.swift` (`DitherSetting.defaultMode`)
- Modify: `ps1-macos/Tests/PS1Tests/DitherModeTests.swift`
- Verify (expected: no change): `ps1-macos/Sources/PS1App/VideoCommands.swift:39-45`

**Interfaces:**
- Consumes: `DitherMode.trueColor` (Task 4), the pinned Gate 1 (Task 5).
- Produces: `DitherSetting.defaultMode == .trueColor`, which
  `MetalRasterizer.ditherMode` and `MetalScaleHarness.replayTo` both read.

- [ ] **Step 1: Write the failing tests**

In `ps1-macos/Tests/PS1Tests/DitherModeTests.swift`, update three cases and add
one:

```swift
@Test func ditherModeRawValuesMatchTheShaderHeader() {
    #expect(DitherMode.off.uniformValue == UInt32(PS1_DITHER_OFF))
    #expect(DitherMode.native.uniformValue == UInt32(PS1_DITHER_NATIVE))
    #expect(DitherMode.scaled.uniformValue == UInt32(PS1_DITHER_SCALED))
    #expect(DitherMode.trueColor.uniformValue == UInt32(PS1_DITHER_TRUE_COLOR))
}

@Test func anUnusedKeyLoadsAsTheDefaultRatherThanAsOff() {
    // Still `object(forKey:)` and not `integer(forKey:)`: 0 is a VALID mode
    // (`.off`, the worst-looking of the four), so a missing key read as an
    // integer reports every fresh install as having deliberately chosen it.
    #expect(DitherSetting(key: uniqueKey()).mode == .trueColor)
    #expect(DitherSetting.defaultMode == .trueColor)
}

@Test func aFreshRasterizerCarriesTheShippedMode() throws {
    // The seam between the setting and the uniform. `MetalRasterizer.ditherMode`
    // is initialised from `DitherSetting.defaultMode`, so a rasterizer built
    // before any coordinator assigns one — every test harness, and the first
    // frame after a scale change — must already be in the shipped mode.
    //
    // The shipped default must also not opt the player out of an oracle:
    // `.scaled` breaks downsample-invariance above 1x knowingly, and
    // `.trueColor` writes VRAM exactly as `.off` does, so nothing a gate reads
    // moves at any scale. That is why this default could move at all.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    #expect(r.ditherMode == .trueColor)
    #expect(DitherSetting.defaultMode == .trueColor)
}
```

`DitherModeTests.swift` needs `import Metal` and `@testable import PS1` for that
one — it already has the latter.

Also update `anUnrecognisedPersistedValueFallsBackToTheDefault` to expect
`.trueColor`, and keep the stored value it writes at `7` — still outside the
enum with four cases.

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/anUnusedKeyLoadsAsTheDefaultRatherThanAsOff 2>&1 | tail -20
```

Expected: FAIL — `.scaled` is still the default.

- [ ] **Step 3: Move the default**

In `ps1-macos/Sources/PS1/DitherMode.swift`:

```swift
    /// Eight bits per channel, and no dither pattern at all.
    ///
    /// It can be the default at every internal resolution — 1x included —
    /// because VRAM is written exactly as it is at `.off`: no fixture hash
    /// moves, downsample-invariance is untouched, and `PS1_LIVE_DIFF` compares
    /// the same bytes it always did. `.scaled`, the previous default, knowingly
    /// traded downsample-invariance above 1x for its smoother pattern; this
    /// trades nothing.
    ///
    /// What it DOES change is which divergence class `PS1_LIVE_DIFF` reports:
    /// the software shadow dithers and this does not, so at the shipped default
    /// the oracle is as loud as it is at `.off`. Switch to `.native` before
    /// reading anything into a run.
    static let defaultMode = DitherMode.trueColor
```

- [ ] **Step 4: Verify the menu needs no change**

```bash
grep -n "DitherMode.allCases" ps1-macos/Sources/PS1App/VideoCommands.swift
```

The picker is `ForEach(DitherMode.allCases)`, so the fourth entry appears with
no edit. Confirm the menu order by eye in Step 6 — `allCases` follows
declaration order, which runs off → native → scaled → trueColor, i.e. least to
most smoothing. That ordering is deliberate; do not reorder the enum to put the
default first, because the raw values are the shader's uniform and must stay
stable across releases.

- [ ] **Step 5: Run the whole suite**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: all passing. In particular Gate 1's ladder (now pinned by Task 5) and
Gate 2's downsample-invariance are unmoved. Gate 3's `replayTo` now defaults to
`.trueColor`, which is what the spec asks for and is opt-in anyway.

- [ ] **Step 6: Look at it, on the reported case**

```bash
zig build capi-lib && zig build metallib && zig build macos
open zig-out/Substation.app
```

Boot Crash Bandicoot, reach a sand surface, and switch `Video ▸ Dithering`
between `True Colour` and `Scaled (Smooth)`. Expected: the banding on the sand
is gone in `True Colour` and the dither pattern is absent; `Off` shows the hard
bands the report describes. Note what you saw in the commit message — this is
the acceptance criterion of the whole feature and no test can state it.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Sources/PS1/DitherMode.swift ps1-macos/Tests/PS1Tests/DitherModeTests.swift
git commit -m "$(cat <<'MSG'
feat(gpu): true colour is the default dither mode

Four entries in Video > Dithering. It can be the default at every scale
because VRAM is written exactly as it is at .off, so no gate moves — and
PS1_LIVE_DIFF is correspondingly as loud as it is at .off, which is now
documented on the setting.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014Kcgw8AXvMh8ZFNjtU5xFS
MSG
)"
```

---

### Task 7: Gate 3 dumps the sidecar, Gate 4 measures the second attachment

Both are opt-in, neither asserts, and both exist because the thing they measure
cannot be caught by a hash. Gate 3 is how the banding is compared by eye on the
same frame; Gate 4 is the honest answer to "what did a second colour attachment
cost", which nothing so far has measured.

**Files:**
- Modify: `ps1-macos/Sources/PS1/VramImage.swift` (an RGBA8 sibling)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift:801-824`
  (`dumpsScaledImagesForEyeballing`)
- Test: `ps1-macos/Tests/PS1Tests/MetalVramTests.swift` (the PNG writer)

**Interfaces:**
- Consumes: `MetalScaleHarness.replayTo(..., wantSidecar:)` (Task 2),
  `DitherMode.trueColor` (Task 4).
- Produces: `VramImage.writeSidecar(_ bytes: [UInt8], width:height:to:) -> Bool`
  and `VramImage.url(fixture:frame:scale:sidecar:)` — `sidecar` defaults false
  and appends `-sidecar` to the filename when true.

- [ ] **Step 1: Write the failing test**

Append to `ps1-macos/Tests/PS1Tests/MetalVramTests.swift`:

```swift
@Test func theSidecarPngWriterRoundTripsItsBytes() throws {
    // Gate 3's only assertable half. The dump itself is eyeball-only, but a
    // writer that silently drops a channel would make the comparison it exists
    // for meaningless — and the PNG is the only place the eight-bit picture
    // is ever visible outside the app.
    let w = 4, h = 2
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h) {
        bytes[i * 4] = UInt8(i * 8)
        bytes[i * 4 + 1] = UInt8(i * 8 + 1)
        bytes[i * 4 + 2] = UInt8(i * 8 + 2)
        bytes[i * 4 + 3] = i % 2 == 0 ? 255 : 0
    }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sidecar-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(VramImage.writeSidecar(bytes, width: w, height: h, to: url))
    #expect(FileManager.default.fileExists(atPath: url.path))

    // The names must differ or the two dumps overwrite each other and the
    // comparison silently becomes one image against itself.
    let a = VramImage.url(fixture: "x", frame: 1, scale: 4)
    let b = VramImage.url(fixture: "x", frame: 1, scale: 4, sidecar: true)
    #expect(a != b)
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation; \
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -only-testing:PS1Tests/theSidecarPngWriterRoundTripsItsBytes 2>&1 | tail -20
```

Expected: compile failure — `type 'VramImage' has no member 'writeSidecar'`.

- [ ] **Step 3: Add the writer**

In `ps1-macos/Sources/PS1/VramImage.swift`:

```swift
    /// Sits next to the fixtures, which are already build artifacts.
    ///
    /// `sidecar` names the eight-bit dump rather than the VRAM one. They must
    /// not collide: the whole point of Gate 3 in this phase is putting the two
    /// side by side on the same frame.
    static func url(fixture: String, frame: Int, scale: Int, sidecar: Bool = false) -> URL {
        let suffix = sidecar ? "-sidecar" : ""
        return FixtureFile.repoURL
            .appendingPathComponent("zig-out/fixtures")
            .appendingPathComponent("\(fixture)-frame\(frame)-\(scale)x\(suffix).png")
    }

    /// The true-colour sidecar as it would be displayed: RGB where alpha says
    /// the pixel is present, black where it does not.
    ///
    /// Absent pixels are written BLACK rather than expanded from VRAM. This
    /// dump is for reading the sidecar's own coverage — which regions a frame
    /// actually carries eight-bit colour for — and expanding VRAM into the gaps
    /// would produce a plausible-looking picture that answers a different
    /// question. The displayed image is what the app shows.
    static func writeSidecar(_ bytes: [UInt8], width: Int, height: Int, to url: URL) -> Bool {
        precondition(bytes.count == width * height * 4)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let present = bytes[i * 4 + 3] != 0
            rgba[i * 4 + 0] = present ? bytes[i * 4 + 0] : 0
            rgba[i * 4 + 1] = present ? bytes[i * 4 + 1] : 0
            rgba[i * 4 + 2] = present ? bytes[i * 4 + 2] : 0
            rgba[i * 4 + 3] = 255
        }
        return writeRgba(rgba, width: width, height: height, to: url)
    }
```

…and extract the CGImage tail of the existing `write(_:width:height:to:)` into
`private static func writeRgba(_ rgba: [UInt8], width: Int, height: Int, to url: URL) -> Bool`,
leaving `write` as the ABGR1555 expansion that calls it. Both writers must keep
using the `(c << 3) | (c >> 2)` expansion, which `write` already documents.

- [ ] **Step 4: Extend Gate 3**

In `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift`, replace the body of
`dumpsScaledImagesForEyeballing`'s inner loop:

```swift
    for (name, frame) in gate3Frames {
        guard generatedFixtureExists(name) else { continue }
        for scale in Set([1, n]).sorted() {
            // Two modes on the same frame, which is the comparison this phase
            // exists to make: `.scaled` is the smoothest of the dithering modes
            // and `.trueColor` is the mode that has levels rather than a
            // pattern. `.off` is what the banding report describes and is one
            // edit away if it is wanted.
            for dither in [DitherMode.scaled, DitherMode.trueColor] {
                guard let f = try MetalScaleHarness.replayTo(
                    name, frame: frame, scale: scale, dither: dither,
                    wantSidecar: dither == .trueColor) else { return }

                let url = VramImage.url(fixture: "\(name)-\(dither)", frame: frame, scale: scale)
                #expect(VramImage.write(f.scaled, width: f.width, height: f.height, to: url))

                if let side = f.sidecar {
                    let sideUrl = VramImage.url(fixture: "\(name)-\(dither)",
                                                frame: frame, scale: scale, sidecar: true)
                    #expect(VramImage.writeSidecar(side, width: f.width, height: f.height,
                                                   to: sideUrl))
                    let present = stride(from: 3, to: side.count, by: 4)
                        .reduce(0) { $0 + (side[$1] != 0 ? 1 : 0) }
                    print("[gate-3] \(name) \(dither) @\(scale)x -> \(sideUrl.path) "
                          + "(\(present) of \(f.width * f.height) subtexels present)")
                }
                // Neither geometry fixture uploads a texture — their windows
                // start from a blank VRAM, so their textured draws sample
                // whatever the fills and copies left behind and a texel of 0 is
                // a discarded HOLE. This number is how much picture there
                // actually is to read.
                let painted = f.native.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
                print("[gate-3] \(name) \(dither) @\(scale)x -> \(url.path) "
                      + "(\(painted) of \(MetalVram.nativePixelCount) native px painted)")
            }
        }
    }
```

- [ ] **Step 5: Run Gate 3 and Gate 4**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation
zig build fixtures -Doptimize=ReleaseFast     # the generated fixtures Gate 3 reads
echo 4 > zig-out/fixtures/PS1_DUMP_SCALED
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -parallel-testing-enabled NO \
  -only-testing:PS1Tests/dumpsScaledImagesForEyeballing 2>&1 | grep gate-3
open zig-out/fixtures/silent-hill-usa-*.png
rm zig-out/fixtures/PS1_DUMP_SCALED
```

Expected: the `trueColor` dumps show no dither pattern and smoother gradients
than the `scaled` ones on the same frame. Both are opt-in and neither asserts.

```bash
touch zig-out/fixtures/PS1_SCALE_TIMING
xcodebuild test -project ps1-macos/PS1.xcodeproj -scheme PS1 \
  -parallel-testing-enabled NO \
  -only-testing:PS1Tests/measuresReplayCostAtEachScale 2>&1 | grep gate-4 | tee /tmp/gate4-after.txt
rm zig-out/fixtures/PS1_SCALE_TIMING
```

Record the `@8x` numbers for `silent-hill-usa` and `tr1-usa-v1-1` — they are
what replaces `REPLACE_WITH_MEASURED_MS` in Step 7's commit message and
`<numbers from Task 7 Step 5>` in Task 8's skill text. Neither placeholder may
survive into a commit. The
comparable pre-change figures are in `.claude/skills/ps1-gpu-metal/SKILL.md`
(silent-hill 28.5 ms → 18.6 ms per frame after triple buffering, crash-warped
11.1 → 8.2), measured on a Debug host. A second colour attachment doubles the
tile store bandwidth, so a regression here is expected and its SIZE is the
thing to write down. **If 8x has become slower than roughly 1.3x its previous
cost, say so in the commit message and in the skill — the remedy is the
player's internal-resolution setting, not a silent revert, and the number has
to exist for anyone to weigh it.** `-parallel-testing-enabled NO` is required:
swift-testing otherwise runs the timing beside the scale-8 comparisons and the
GPU contention both skews it and intermittently fails the run.

- [ ] **Step 6: Run the whole suite**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation && ps1-macos/test.sh 2>&1 | tail -30
```

Expected: all passing.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Sources/PS1/VramImage.swift ps1-macos/Tests/PS1Tests/MetalScaleTests.swift \
        ps1-macos/Tests/PS1Tests/MetalVramTests.swift
git commit -m "$(cat <<'MSG'
test(gpu): Gate 3 dumps true colour beside the dithered picture

Two modes and both textures per frame, so the banding is comparable by
eye on the same geometry. Gate 4 re-measured at 8x with the second colour
attachment: REPLACE_WITH_MEASURED_MS (silent-hill / crash-warped, against
18.6 / 8.2 ms before it).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014Kcgw8AXvMh8ZFNjtU5xFS
MSG
)"
```

---

### Task 8: The rules and their reasoning

The one-line rules go in `CLAUDE.md`; the measurements, the rejected shapes and
the dated reasoning go in the skill. That split is the repository's convention
and this feature has three things that look like mistakes if met cold.

**Files:**
- Modify: `CLAUDE.md` (the **GPU + Metal** rule block)
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md`
- Modify: `docs/superpowers/specs/2026-09-12-true-colour-rendering-design.md:4` (status)

**Interfaces:**
- Consumes: everything above, plus the Gate 4 numbers from Task 7.
- Produces: no code.

- [ ] **Step 1: Add the rules to `CLAUDE.md`**

In the **GPU + Metal** (`ps1-gpu-metal`) bullet list, after the
"`gp0.zig` cannot reach the renderer" entry:

```markdown
- **VRAM stays `.r16Uint`; the true-colour sidecar is DISPLAY-ONLY.** It is
  never sampled as a texel, never read back by a game, never hashed by a gate
  and never compared by `PS1_LIVE_DIFF`. Adopting `RGBA8` for VRAM itself
  surrenders all three gates at once.
- **The sidecar's alpha is PRESENCE, not a mask bit** — 255 means it holds a
  real eight-bit colour, 0 means expand VRAM with `c << 3 | c >> 2`. Both
  expansions in the codebase must stay that one expression or an invalidated
  rect shows a seam.
- **A VRAM->VRAM copy moves BOTH attachments in ONE pass.** A second pass can
  resolve a self-overlap differently from the VRAM copy beside it.
- **A GP0(A0) upload invalidates the sidecar across its destination rect**, and
  a whole-texture `upload`/`uploadNative` invalidates all of it: 5551 payload
  carries no extra precision to keep.
- **`.trueColor` writes VRAM exactly as `.off` does.** That is why it can be the
  default at every scale and why no hash moves — and it also means
  `PS1_LIVE_DIFF` is as loud at the shipped default as it is at `.off`, because
  the software shadow dithers. Switch to `.native` before reading a run.
- **Gate 1's harness pins its own dither mode.** It compares against a software
  rasterizer that dithers, so the mode is part of the gate; it must never
  inherit `DitherSetting.defaultMode` again.
```

- [ ] **Step 2: Add the reasoning to the skill**

Append to `.claude/skills/ps1-gpu-metal/SKILL.md`, after the dithering
paragraph that ends "…which is the same reasoning that put the degeneracy
clause at the native sample point":

```markdown
**Dithering could not close the gap, and the reason is arithmetic: it
redistributes quantisation error and cannot add levels** (true colour shipped
2026-09-12, against the same "the shadows look far rougher than DuckStation"
report). Every fragment passed through `ps1_pack`'s `>> 3` into a 16-bit
texture, so a Gouraud ramp had 32 stops per channel at every internal
resolution while DuckStation renders at 256 and ships **with dithering off**
(`settings.h:230`), emulating the 5-bit truncation in the shader only when true
colour is off (`gpu_hw.cpp:3448`). DuckStation can do that because its VRAM
*is* `RGBA8` — and it pays for it by sampling indexed texture data out of that
target and converting back down. We cannot: Gate 1's fixture hashes, Gate 2's
downsample-invariance and `PS1_LIVE_DIFF` all read VRAM and all require it
bit-exact.

So the eight-bit picture lives in a **display-only sidecar** — a second
`.rgba8Uint` texture, scaled like the render texture, written by the same
fragment invocation as `[[color(1)]]` and read only by `display_fragment`.
Texel fetch still reads `r16Uint`, so on that axis this is **more** accurate
than the reference. Five things are load-bearing:

- **Alpha is presence, per pixel**, and it replaces bookkeeping rather than
  adding some: DuckStation needs `m_vram_dirty_draw_rect` and
  `m_vram_dirty_write_rect` to tell GPU-drawn regions from CPU-written ones,
  and the alpha channel answers the same question exactly at rect boundaries
  for free. An absent pixel falls back to `c << 3 | c >> 2`, which is today's
  picture — so every invalidation degrades to the current behaviour rather than
  to a visible defect. `display_fragment`'s `unpack1555` was changed from
  `c / 31.0` to that same replication for exactly this reason: a one-level
  disagreement between the two expansions draws a seam along the boundary of
  every uploaded rect.
- **The residual encoding was considered and does not survive blending.** The
  cheaper shape — keep the low three bits per channel in an `r16Uint` sidecar
  and reconstruct as `vram << 3 | residual` — fails because a 5-bit blend is not
  the truncation of an 8-bit blend: `ps1_blend`'s integer halving differs from
  the same operation at eight bits by up to an LSB per layer, and after one
  transparent draw the two representations no longer reconstruct each other with
  no way to say so. A full parallel picture is *permitted* to drift sub-5-bit
  because nothing compares it.
- **The copy is one pass with two attachments**, never two passes. VRAM->VRAM
  copies wrap at the VRAM edges and self-overlap — DuckStation chunks an
  overlapping copy by rows (`gpu_hw.cpp:3660`) precisely because the ordering is
  observable — and a sidecar copied separately can resolve an overlap
  differently from the VRAM copy beside it.
- **`.trueColor` is a fourth `DitherMode` case, not a second control.** They are
  mutually exclusive by construction and DuckStation asserts exactly that
  (`gpu_hw_shadergen.cpp:2166`); two controls that cannot both be on is a
  control that silently no-ops, which the PGXP sub-setting work already ruled
  against. The flat-colour carve-out (DuckStation's `ShouldTruncate32To16`,
  `gpu_hw.cpp:167`) is adopted and its second menu entry is not: an untextured,
  unshaded, undithered draw writes the expansion of its own five-bit colour,
  which is what it would have written anyway, so there is nothing to choose
  until a game asks for it.
- **It is the default at every scale, 1x included, and that is not a relaxation
  of the testability rule that kept 1x the default resolution.** `.trueColor`
  writes VRAM byte-identically to `.off`, so no hash can move; `.scaled`
  knowingly trades Gate 2 above 1x and this trades nothing.
  `theCorpusRendersIdenticalVramInTrueColourAndOff` is the assertion, over both
  synthetic fixtures frame by frame.

**Two consequences that read as regressions and are not.** `PS1_LIVE_DIFF` is
now as loud at the shipped default as it is at `.off`, because the software
shadow dithers and true colour does not — `.native` is still the mode to switch
to before reading anything into a run, exactly as it already was above 1x. And
**Gate 1's harness had been inheriting `DitherSetting.defaultMode`**, which was
harmless only because `.scaled` and `.native` are the same expression at 1x;
`MetalFixtureHarness.replay` now pins `.native` itself, and
`gateOneRunsAtADitheringModeRatherThanThePlayersDefault` keeps it pinned by
showing that the same replay at `.trueColor` diverges on purpose.

**Milestone 2 — the eight-bit blend path — is deliberately not built.** The
blend still reads VRAM and writes the expansion of its five-bit result,
`aBlendedDrawStillFallsBackToFiveBitsInMilestoneOne` pins that, and the gate on
building it is finding one scene that bands *because of* layered blending. Most
PS1 "fog" is GTE depth cueing baked into vertex colour — a single Gouraud draw,
already fixed. The second case is assumed to exist because later hardware
composites that way, and that is not evidence that PS1 titles do.

**Cost, measured.** The sidecar doubles the render-target allocation: 2 MB at
1x, 18 MB at 3x, 134 MB at 8x, and the copy scratch pair the same again. Gate 4
at 8x after the change: <numbers from Task 7 Step 5> against
silent-hill 18.6 ms / crash-warped 8.2 ms before it.
```

Replace `<numbers from Task 7 Step 5>` with the real figures.

- [ ] **Step 3: Update the design doc's status**

```bash
cd /Users/david/Documents/develop/substation
sed -i '' 's|^\*\*Status:\*\* design approved, plan not yet written$|**Status:** milestone 1 shipped 2026-09-12; milestone 2 gated on evidence\n**Plan:** `docs/superpowers/plans/2026-09-12-true-colour-rendering.md`|' \
  docs/superpowers/specs/2026-09-12-true-colour-rendering-design.md
head -6 docs/superpowers/specs/2026-09-12-true-colour-rendering-design.md
```

- [ ] **Step 4: Final verification**

```bash
cd /Users/david/Documents/develop/substation && pkill -x Substation
zig build capi-lib && zig build metallib
ps1-macos/test.sh 2>&1 | tail -30
zig build test 2>&1 | tail -5
zig build trace-golden -- verify -Doptimize=ReleaseFast 2>&1 | tail -5
```

Expected: the Swift suite green, the Zig suite green and `trace-golden --
verify` unchanged from before this branch. The last two touch nothing this
feature changed and are run to prove exactly that. **`trace-golden -- verify`
has been red since ~2026-08-31 on an orphaned `mgs` golden filename — confirm
it is the SAME failure and not a new one, and do not recapture.**

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md .claude/skills/ps1-gpu-metal/SKILL.md \
        docs/superpowers/specs/2026-09-12-true-colour-rendering-design.md
git commit -m "$(cat <<'MSG'
docs(gpu): the true-colour sidecar's rules and reasoning

The rules in CLAUDE.md, the measurements and the two rejected shapes in
the skill, and the design doc marked as milestone 1 shipped.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014Kcgw8AXvMh8ZFNjtU5xFS
MSG
)"
```

---

## Milestone 2 — not in this plan

The spec's second milestone is the eight-bit blend path: the blend reads the
sidecar for its background where present and the expansion of VRAM where absent,
writes the hardware-exact five-bit result to VRAM and the eight-bit result to
the sidecar, so precision carries across a composite. It is gated on evidence —
**before building it, confirm one scene that bands because of layered
blending.** `aBlendedDrawStillFallsBackToFiveBitsInMilestoneOne` is the test
that would change, and `ps1_blend` gains a sibling rather than being replaced.

When it is built, it needs `ushort4 dstSide [[color(1)]]` as a programmable-blend
input on `ps1_prim_fragment` — the same mechanism `ushort dst [[color(0)]]`
already uses, and unaffected by the pass-splitting invariant for the same
reason.

## Out of scope

- PGXP Phase 3 (perspective-correct texturing) — independent: that one is about
  texture *coordinates*, this one about colour *precision*.
- DuckStation's downsampling modes (`Box`, `Adaptive`).
- Texture filtering.
- Any change to the software rasterizer, `ps1-core`, or the C ABI.

## Provenance

DuckStation was read for behavioural facts only — which VRAM paths exist, what
coherence each owes, what its defaults and mode semantics are. The sidecar
architecture has no counterpart there: DuckStation's VRAM *is* `RGBA8`, which is
the approach this design rejects. Its licence is CC BY-NC-ND and no code was
adapted.
