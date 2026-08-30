# Metal renderer Phase D2 — upscaling in the app — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the player pick an internal resolution of 1…8× and make the extra resolution reach the screen — a persisted setting, a rebuild of the render path at the chosen scale, and a display pass that samples the scaled texture instead of reducing it back to native.

**Architecture:** A small `InternalResolution` value type owns the range, the `UserDefaults` key and a **clamping** load; `EmulatorViewModel` exposes it as `internalScale`, and a `Video` command menu binds to that. `ContentView` keys `.id()` on the runner's identity **and** the scale, so a change rebuilds `MetalDisplayView`'s coordinator, its `LiveRenderer` and its `MetalVram` through exactly the path a disc change already uses; the coordinator's `init` requests a resync because a fresh `MetalVram` is a blank texture. `DisplayShader.metal` gains a `scale` uniform, derives `px`/`py` from `width * scale`, splits them into a native coordinate and a subtexel, and wraps **natively then scales** — never with a scaled bitmask.

**Tech Stack:** Swift 6 / swift-testing, Metal (MSL), SwiftUI, Xcode 26.6, `xcodebuild`. No Zig.

**Spec:** `docs/superpowers/specs/2026-08-30-metal-renderer-phase-d2-upscaling-design.md`
(predecessor: `docs/superpowers/specs/2026-08-30-metal-renderer-phase-d1-live-path-design.md`;
parent: `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`;
scaling rule: `docs/superpowers/specs/2026-08-29-metal-renderer-phase-c-design.md`)

## Global Constraints

- **This phase adds NO Zig change.** No `ps1-core`, no `ps1-capi`, no `ps1-golden`, no `build.zig`. A diff touching any of them is a defect in the task that produced it. The final verification checks this mechanically.
- **The internal-resolution range is `1...8`, and the default is `1`.** 1× is the only scale with a per-frame byte-exact oracle on arbitrary content; above it the check weakens to downsample-invariance, and the shipped configuration must not opt the player out of the stronger one.
- **The scanout wrap is form A: `((vram_x + nx) & 1023) * s + sub_x`.** The parent spec specifies `& (1024*s − 1)` and **that form is wrong and must not be implemented as written** — a bitwise mask is a modulo only when the modulus is a power of two, so at s = 3 it samples the wrong column.
- **24bpp and the `PS1_SOFTWARE_DISPLAY` seam read the 1024×512 shadow at `nx`/`ny`.** `sub_x`/`sub_y` are discarded there. Feeding them `px`/`py` breaks every FMV in Croc and Silent Hill above 1× and nowhere else.
- **Gate 1 is a freeze.** A moved Phase B/C fixture hash is a bug in this phase, never a baseline to update. Phase 0 was the only phase permitted to change output.
- **`ps1-macos/test.sh` needs `zig build capi-lib` and `zig build metallib` built first**, and says so. Both need full Xcode. Run them once before starting, not per task.
- **Adding a `.swift` file needs no project edit.** `Sources/` and `Tests/` are `PBXFileSystemSynchronizedRootGroup`s — the folder is the target's membership. Do not add `PBXFileReference`/`PBXBuildFile` entries.
- **Swift tests return early without a Metal device** rather than failing — `MTLCreateSystemDefaultDevice()` is nil on a headless runner and a red suite there is noise, not signal.
- **Do not `git push`.** Commit locally, one commit per task, on the current branch (`master`).

---

## File Structure

**The setting**

- `ps1-macos/Sources/PS1/InternalResolution.swift` — **create.** The range, the `UserDefaults` key, the clamp, the load and the write-back. One responsibility: the setting as data. Shaped after `ScopedBookmark` — the app's only other persisted setting — so the clamp is reachable from a test without a window.
- `ps1-macos/Sources/PS1/EmulatorViewModel.swift` — modify: a stored `InternalResolution` plus the `public var internalScale` seam the menu binds to.
- `ps1-macos/Tests/PS1Tests/InternalResolutionTests.swift` — **create.**

**The display pass**

- `ps1-macos/Shaders/DisplayShader.metal` — modify: `Params.scale`, the `sizeof` assertion, the scaled sample grid, the native/subtexel split, form-A wrap, `nx`/`ny` for both shadow reads, and an `unpack1555` helper so the 15bpp unpack is written once.
- `ps1-macos/Sources/PS1/MetalDisplayView.swift` — modify: `DisplayParams.scale`, `MetalDisplayView.scale`, `Coordinator(runner:scale:)`, `requestResync()` in `init`, `params.scale` in `draw`.
- `ps1-macos/Tests/PS1Tests/DisplayScaleTests.swift` — **create.** Its own offscreen harness: `DisplayRenderTests`' helper builds a plain managed 1024×512 texture, which cannot be scaled, and this needs the real `MetalVram` the live path samples.

**The rebuild**

- `ps1-macos/Sources/PS1/ContentView.swift` — modify: pass the scale, key `.id()` on the pair.
- `ps1-macos/Tests/PS1Tests/LiveRendererScaleTests.swift` — **create.**

**The menu**

- `ps1-macos/Sources/PS1App/VideoCommands.swift` — **create.** A `Commands` type rather than an inline `CommandMenu` so `@Bindable` produces the picker's binding directly.
- `ps1-macos/Sources/PS1App/PS1App.swift` — modify: install it.

**Docs**

- `CLAUDE.md` — modify (Task 6).

---

### Task 1: `InternalResolution` and `internalScale`

**Files:**
- Create: `ps1-macos/Sources/PS1/InternalResolution.swift`
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift:51-55` (beside `isPaused`)
- Test: `ps1-macos/Tests/PS1Tests/InternalResolutionTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `struct InternalResolution` with `static let range = 1...8`, `static let defaultsKey = "internalResolution"`, `static func clamp(_ value: Int) -> Int`, `init(key: String = InternalResolution.defaultsKey, defaults: UserDefaults = .standard)`, `private(set) var scale: Int`, `mutating func set(_ value: Int)`.
  - `EmulatorViewModel.internalScale: Int` — **public**, get/set, clamping. Task 3 reads it in `ContentView`; Task 4 binds to it from the `PS1App` module, which is why it is public.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/InternalResolutionTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

/// A fresh defaults key per test, exactly as `ScopedBookmarkTests` does: these
/// write to the real `UserDefaults`, so a shared key would let one test see
/// another's scale — and would clobber the running user's own setting.
private func uniqueKey() -> String { "test-resolution-\(UUID().uuidString)" }

@Test func anUnusedKeyLoadsAsOneX() {
    // `UserDefaults.integer(forKey:)` returns 0 for a missing key, and the
    // clamp lifts that to 1. The shipped default therefore falls out of the
    // clamp rather than being a second constant that could drift from it.
    let res = InternalResolution(key: uniqueKey())
    #expect(res.scale == 1)
}

@Test func theScaleRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    var written = InternalResolution(key: key)
    written.set(4)
    #expect(written.scale == 4)

    // The point of persisting it: a fresh instance built from the same key
    // reads the same scale back, which is what makes the choice survive a
    // relaunch.
    #expect(InternalResolution(key: key).scale == 4)
}

@Test func anOutOfRangePersistedValueLoadsInsteadOfTrapping() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    // Hand-edited defaults, or a value written by a future build with a wider
    // range and then downgraded. `MetalVram.init` traps outside 1...8
    // (MetalVram.swift:51) and its own comment says the picker must clamp
    // rather than let the app abort at launch — this is that clamp.
    UserDefaults.standard.set(99, forKey: key)
    #expect(InternalResolution(key: key).scale == 8)

    UserDefaults.standard.set(-3, forKey: key)
    #expect(InternalResolution(key: key).scale == 1)
}

@Test func settingAnOutOfRangeScaleClampsBeforeItIsStored() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }

    var res = InternalResolution(key: key)
    res.set(99)
    #expect(res.scale == 8)
    // Clamped on the way IN as well as on the way out, so a bad value never
    // reaches the defaults database in the first place.
    #expect(UserDefaults.standard.integer(forKey: key) == 8)
}

@MainActor
@Test func theViewModelRoundTripsAndClampsTheInternalScale() {
    let model = EmulatorViewModel()
    let original = model.internalScale
    defer { model.internalScale = original }

    model.internalScale = 4
    #expect(model.internalScale == 4)
    // A fresh model reads it back: the menu writes through to the setting, it
    // does not hold a session-only copy.
    #expect(EmulatorViewModel().internalScale == 4)

    model.internalScale = 99
    #expect(model.internalScale == 8)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ps1-macos/test.sh 2>&1 | tail -30`

Expected: FAIL — `cannot find 'InternalResolution' in scope` and `value of type 'EmulatorViewModel' has no member 'internalScale'`.

- [ ] **Step 3: Write `InternalResolution`**

Create `ps1-macos/Sources/PS1/InternalResolution.swift`:

```swift
import Foundation

/// The internal-resolution setting: the supported range, where it is stored,
/// and a load that CLAMPS.
///
/// A type of its own rather than two lines inside `EmulatorViewModel` so the
/// clamp is reachable from a test without a window — the same reason
/// `ScopedBookmark` is a type, and the same shape: `init` resolves, `set`
/// persists.
///
/// The clamp is the whole point. `MetalVram.init` traps outside `range`, and
/// its own comment anticipates this: a value read back from `UserDefaults` is
/// DATA, not a literal, so it must be clamped or rejected here rather than
/// aborting the app at launch. The precondition over there stays exactly what
/// it always was — a programming-error trap for a bad literal.
struct InternalResolution {
    /// Everything Phase C proved, shipped.
    static let range = 1...8
    static let defaultsKey = "internalResolution"

    private let defaults: UserDefaults
    private let key: String
    private(set) var scale: Int

    init(key: String = InternalResolution.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        // `integer(forKey:)` returns 0 for a missing key, and the clamp lifts
        // that to 1 — so the shipped default is not a second constant that can
        // drift from the range.
        self.scale = Self.clamp(defaults.integer(forKey: key))
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Clamped on the way in as well as on the way out, so a bad value never
    /// reaches the defaults database at all.
    mutating func set(_ value: Int) {
        scale = Self.clamp(value)
        defaults.set(scale, forKey: key)
    }
}
```

- [ ] **Step 4: Add `internalScale` to the view model**

In `ps1-macos/Sources/PS1/EmulatorViewModel.swift`, immediately after the `isPaused` property (`:51-55`), add:

```swift
    /// Internal resolution, 1...8, persisted. Public because the `Video` menu
    /// lives in the PS1App target, a separate module — the same reason
    /// `isPaused` and `rescanLibrary()` are public.
    ///
    /// A computed seam over a stored struct: `@Observable` instruments the
    /// stored `resolution`, so mutating it through here notifies observers and
    /// `ContentView` re-keys the display view on the new scale.
    private var resolution = InternalResolution()

    public var internalScale: Int {
        get { resolution.scale }
        set { resolution.set(newValue) }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `ps1-macos/test.sh 2>&1 | tail -30`

Expected: PASS, and every pre-existing test still green.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/InternalResolution.swift \
        ps1-macos/Sources/PS1/EmulatorViewModel.swift \
        ps1-macos/Tests/PS1Tests/InternalResolutionTests.swift
git commit -m "feat(macos): persist an internal-resolution setting, clamped to 1...8

MetalVram.init traps outside the range, and a UserDefaults value is data
rather than a literal: a hand-edited 99, or a value written by a future
build with a wider range and then downgraded, must start the app instead
of aborting it at launch. The default falls out of the clamp -- a missing
key reads 0 and clamps to 1 -- so it cannot drift from the range.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The display pass samples at scale

**Files:**
- Modify: `ps1-macos/Shaders/DisplayShader.metal:4-14` (`Params`) and `:42-91` (`display_fragment`)
- Modify: `ps1-macos/Sources/PS1/MetalDisplayView.swift:28-38` (`DisplayParams`)
- Test: `ps1-macos/Tests/PS1Tests/DisplayScaleTests.swift`

**Interfaces:**
- Consumes: `MetalVram(device:queue:scale:)`, `MetalVram.upload(_:)`, `MetalVram.uploadNative(_:)`, `MetalVram.nativeWidth`/`nativeHeight`/`nativePixelCount`, `Shaders.makeLibrary(_:)`, `letterboxScale(width:height:)` — all existing.
- Produces: `DisplayParams.scale: UInt32 = 1` as the **tenth and last** field; MSL `Params.scale` in the same position. Stride 40 on both sides. Task 3 writes `params.scale` from the renderer.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/DisplayScaleTests.swift`:

```swift
import Testing
import Metal
@testable import PS1

/// Renders the real display pass offscreen against a real `MetalVram` at
/// `scale` and hands back the drawable's BGRA bytes.
///
/// A second harness rather than a parameter on `DisplayRenderTests`' one: that
/// helper builds a plain managed 1024x512 texture, which cannot be scaled at
/// all. This needs the .private renderTarget+shaderRead texture the live path
/// actually samples.
///
/// `scaled` overrides `native` when given, for the one test that needs blocks
/// which are NOT uniform.
private func renderScaled(native: [UInt16],
                          scaled: [UInt16]? = nil,
                          shadow: [UInt16]? = nil,
                          scale: Int,
                          drawable: (width: Int, height: Int) = (320, 240),
                          configure: (inout DisplayParams) -> Void = { _ in })
    throws -> [UInt8]?
{
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue, scale: scale)
    else { return nil }
    if let scaled { vram.upload(scaled) } else { vram.uploadNative(native) }

    let shDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r16Uint, width: 1024, height: 512, mipmapped: false)
    shDesc.usage = .shaderRead
    shDesc.storageMode = .managed
    guard let shadowTex = device.makeTexture(descriptor: shDesc) else { return nil }
    (shadow ?? native).withUnsafeBytes { buf in
        shadowTex.replace(region: MTLRegionMake2D(0, 0, 1024, 512), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: 1024 * 2)
    }

    let targetDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: drawable.width, height: drawable.height,
        mipmapped: false)
    targetDesc.usage = [.renderTarget, .shaderRead]
    targetDesc.storageMode = .managed
    guard let target = device.makeTexture(descriptor: targetDesc) else { return nil }

    let library = try Shaders.makeLibrary(device)
    let pipeDesc = MTLRenderPipelineDescriptor()
    pipeDesc.vertexFunction = library.makeFunction(name: "display_vertex")
    pipeDesc.fragmentFunction = library.makeFunction(name: "display_fragment")
    pipeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: pipeDesc)

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    pass.colorAttachments[0].storeAction = .store

    var params = DisplayParams()
    params.width = 320
    params.height = 240
    params.enabled = 1
    params.scale = UInt32(scale)
    configure(&params)
    (params.scaleX, params.scaleY) = letterboxScale(
        width: Double(drawable.width), height: Double(drawable.height))

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(vram.texture, index: 0)
    enc.setFragmentTexture(shadowTex, index: 1)
    enc.setVertexBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
    enc.setFragmentBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    guard let blit = cmd.makeBlitCommandEncoder() else { return nil }
    blit.synchronize(resource: target)
    blit.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    var out = [UInt8](repeating: 0, count: drawable.width * drawable.height * 4)
    out.withUnsafeMutableBytes { buf in
        target.getBytes(buf.baseAddress!, bytesPerRow: drawable.width * 4,
                        from: MTLRegionMake2D(0, 0, drawable.width, drawable.height),
                        mipmapLevel: 0)
    }
    return out
}

/// A full native VRAM in which practically every pixel differs from its
/// neighbours, so an off-by-one in `nx` or a wrong wrap lands on a visibly
/// different colour instead of an identical one. Deterministic: the same
/// bytes on every run and on both sides of every comparison.
private func lcgImage(seed: UInt32 = 0x2545F491) -> [UInt16] {
    var out = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    var s = seed
    for i in 0..<out.count {
        s = s &* 1664525 &+ 1013904223
        out[i] = UInt16((s >> 15) & 0x7FFF)
    }
    return out
}

private let displayScaleLadder = [2, 3, 4, 8]

@Test func theDisplayParamsStrideMatchesTheShaderStruct() {
    // DisplayShader.metal carries `static_assert(sizeof(Params) == 40)`. This
    // is the other half of that pair: a field added on one side only shears
    // every field after it.
    #expect(MemoryLayout<DisplayParams>.stride == 40)
    #expect(MemoryLayout<DisplayParams>.size == 40)
    // Never 0: the fragment shader divides by it. A default of 0 would be a
    // divide-by-zero on the very first frame after a field reorder.
    #expect(DisplayParams().scale == 1)
}

@Test func aBlockUniformTextureDisplaysIdenticallyAtEveryScale() throws {
    // The display-side analogue of Phase C's exactness property: a scaled
    // texture whose every N x N block is uniform must present byte-identically
    // to the native image at 1x. `uploadNative` produces exactly that, so the
    // fixture is free.
    let image = lcgImage()
    guard let one = try renderScaled(native: image, scale: 1) else { return }
    for scale in displayScaleLadder {
        guard let many = try renderScaled(native: image, scale: scale) else { return }
        #expect(many == one, "scale \(scale)")
    }
}

@Test func aDisplayWindowCrossingTheVramEdgeWrapsNatively() throws {
    // The case the parent spec got wrong, as its own test rather than a hope
    // that the sweep above happens to cross an edge.
    //
    // vram_x 1000 + 320 columns and vram_y 400 + 240 rows both run off the end
    // of VRAM. Scale 3 is what separates form A -- ((vram_x + nx) & 1023) * s
    // + sub_x -- from the parent spec's `& (1024 * s - 1)`: at s = 3 that mask
    // is 3071, which is not `mod 3072`. At px = 75 the mask gives 2051 where
    // the correct column is 3.
    let image = lcgImage()
    func window(_ p: inout DisplayParams) {
        p.vramX = 1000
        p.vramY = 400
    }
    guard let one = try renderScaled(native: image, scale: 1, configure: window)
    else { return }
    for scale in displayScaleLadder {
        guard let many = try renderScaled(native: image, scale: scale, configure: window)
        else { return }
        #expect(many == one, "scale \(scale)")
    }
}

@Test func theDisplayPassSamplesSubtexelsNotJustTheBlockCorner() throws {
    // The test that fails for a plausible, entirely self-consistent
    // implementation of this whole phase: scaling only the WRAPS is a no-op.
    // Every sample then lands on its block's top-left subtexel, which by Phase
    // C's exactness property is byte-identical to the 1x picture -- the player
    // selects 8x, pays 67 MB and sees nothing. No other test here notices,
    // because every other one compares against the 1x picture on purpose.
    let scale = 2
    let w = MetalVram.nativeWidth * scale
    var scaled = [UInt16](repeating: 0, count: MetalVram.nativePixelCount * scale * scale)
    scaled[0] = 0x001F          // native (0,0) subtexel (0,0): red
    scaled[1] = 0x03E0          //                     (1,0): green
    scaled[w] = 0x7C00          //                     (0,1): blue
    scaled[w + 1] = 0x7FFF      //                     (1,1): white

    // sw = 320 * 2 = 640 and sh = 240 * 2 = 480, so a 640x480 drawable maps
    // 1:1 onto the scaled sample grid and the four subtexels of ONE native
    // pixel land on four distinct drawable pixels.
    guard let img = try renderScaled(
        native: [UInt16](repeating: 0, count: MetalVram.nativePixelCount),
        scaled: scaled, scale: scale, drawable: (640, 480)) else { return }

    // (b, g, r) — the target is .bgra8Unorm.
    func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let o = (y * 640 + x) * 4
        return (img[o], img[o + 1], img[o + 2])
    }
    #expect(px(0, 0).2 > 240 && px(0, 0).1 < 16)   // red
    #expect(px(1, 0).1 > 240 && px(1, 0).2 < 16)   // green
    #expect(px(0, 1).0 > 240 && px(0, 1).2 < 16)   // blue
    #expect(px(1, 1).0 > 240 && px(1, 1).1 > 240 && px(1, 1).2 > 240)  // white
}

@Test func twentyFourBppDisplaysIdenticallyAtEveryScale() throws {
    // The trap in the phase. 24bpp reconstructs pixels by byte-packing across
    // ADJACENT 16-bit VRAM words, arithmetic that is meaningless in scaled
    // space -- which is why D1 routed it to the 1024x512 shadow permanently.
    // It must be addressed with `nx`/`ny`; `px` at scale 4 reads a column four
    // times too far along and breaks every FMV in Croc and Silent Hill.
    let shadow = lcgImage()
    // The render texture holds something DIFFERENT, so a 24bpp path that read
    // it instead of the shadow fails here too.
    let render = lcgImage(seed: 0x9E3779B9)
    func depth(_ p: inout DisplayParams) { p.depth24 = 1 }

    guard let one = try renderScaled(native: render, shadow: shadow,
                                     scale: 1, configure: depth) else { return }
    for scale in displayScaleLadder {
        guard let many = try renderScaled(native: render, shadow: shadow,
                                          scale: scale, configure: depth) else { return }
        #expect(many == one, "scale \(scale)")
    }
}

@Test func theSoftwareDisplaySeamStaysOnTheNativeShadowAtEveryScale() throws {
    // Same routing rule as 24bpp, same reason: the shadow is 1024x512 at every
    // N, so it is addressed natively or not at all.
    let shadow = lcgImage()
    let render = lcgImage(seed: 0x9E3779B9)
    func seam(_ p: inout DisplayParams) { p.softwareDisplay = 1 }

    guard let one = try renderScaled(native: render, shadow: shadow,
                                     scale: 1, configure: seam) else { return }
    for scale in displayScaleLadder {
        guard let many = try renderScaled(native: render, shadow: shadow,
                                          scale: scale, configure: seam) else { return }
        #expect(many == one, "scale \(scale)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ps1-macos/test.sh 2>&1 | tail -30`

Expected: FAIL — `value of type 'DisplayParams' has no member 'scale'`.

- [ ] **Step 3: Add `scale` to the Swift mirror**

In `ps1-macos/Sources/PS1/MetalDisplayView.swift`, extend `DisplayParams` (`:28-38`) with a tenth field. Keep the existing doc comment above the struct and add the default note:

```swift
/// Mirrors `Params` in Shaders/DisplayShader.metal. Field order and types must match
/// exactly. File scope rather than nested in `Coordinator` so the offscreen
/// render test can feed the real struct to the real shader.
///
/// Both sides are 4-byte aligned throughout, so this is 40 bytes with no
/// padding question — pinned by `static_assert` over there and by
/// `theDisplayParamsStrideMatchesTheShaderStruct` here.
struct DisplayParams {
    var vramX: UInt32 = 0
    var vramY: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var depth24: UInt32 = 0
    var enabled: UInt32 = 0
    var scaleX: Float = 1
    var scaleY: Float = 1
    var softwareDisplay: UInt32 = 0
    /// Internal resolution, 1...8. Defaults to 1 and never 0: the fragment
    /// shader divides by it.
    var scale: UInt32 = 1
}
```

- [ ] **Step 4: Rewrite the fragment shader**

In `ps1-macos/Shaders/DisplayShader.metal`, extend `Params` and add the size assertion:

```metal
struct Params {
    uint  vram_x;
    uint  vram_y;
    uint  width;
    uint  height;
    uint  depth24;
    uint  enabled;
    float scale_x;   // letterboxing: 1.0 on the axis that fills
    float scale_y;
    uint  software_display; // debug seam: read the 1x shadow at 15bpp too
    uint  scale;            // internal resolution, 1...8
};

static_assert(sizeof(Params) == 40,
              "DisplayParams in MetalDisplayView.swift must match field for field");
```

Add the unpack helper above `display_fragment` — the 15bpp unpack is now needed on two paths and is written once:

```metal
static float4 unpack1555(uint texel) {
    // ABGR1555: bits 0-4 red, 5-9 green, 10-14 blue, bit 15 mask/STP.
    float r = float( texel        & 0x1F) / 31.0;
    float g = float((texel >>  5) & 0x1F) / 31.0;
    float b = float((texel >> 10) & 0x1F) / 31.0;
    return float4(r, g, b, 1.0);
}
```

Replace the whole body of `display_fragment` (`:42-91`) with:

```metal
fragment float4 display_fragment(VertexOut in [[stage_in]],
                                 texture2d<uint, access::read> vram [[texture(0)]],
                                 texture2d<uint, access::read> shadow [[texture(1)]],
                                 constant Params& p [[buffer(0)]]) {
    // Outside the picture: a letterbox bar.
    if (any(in.uv < 0.0) || any(in.uv >= 1.0)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    if (p.enabled == 0 || p.width == 0 || p.height == 0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // The sample grid is N times finer than the programmed display area, which
    // stays in NATIVE units (registers.zig's getVisibleWidth/Height). This
    // multiplication IS the phase: scaling only the wraps below leaves every
    // sample on its block's top-left subtexel, which by Phase C's exactness
    // property is byte-identical to the 1x picture -- 67 MB at 8x for no
    // visible change.
    uint sw = p.width  * p.scale;
    uint sh = p.height * p.scale;

    uint px = uint(in.uv.x * float(sw));
    uint py = uint(in.uv.y * float(sh));
    if (px >= sw) px = sw - 1;
    if (py >= sh) py = sh - 1;

    // The same split Rasterizer.metal applies to a scaled fragment. Everything
    // that wraps, addresses the shadow or packs bytes is computed from nx/ny;
    // only the 15bpp read of the render texture re-adds sub_x/sub_y.
    uint nx = px / p.scale, sub_x = px % p.scale;
    uint ny = py / p.scale, sub_y = py % p.scale;

    uint col = (p.vram_x + nx) & 1023;
    uint row = (p.vram_y + ny) & 511;

    if (p.depth24 != 0) {
        // 24bpp: three bytes per pixel packed across ADJACENT 16-bit VRAM
        // words. That arithmetic is meaningless once uploads are replicated
        // N x N in the scaled texture, and 24bpp content is FMV -- MDEC output
        // uploaded through A0, never upscaled geometry -- so it scans out of
        // the 1x shadow permanently, addressed at nx/ny with sub_x/sub_y
        // DISCARDED. Croc and Silent Hill both depend on this.
        uint byte_off = nx * 3;
        uint w0 = shadow.read(uint2((p.vram_x + (byte_off >> 1)) & 1023, row)).r;
        uint w1 = shadow.read(uint2((p.vram_x + (byte_off >> 1) + 1) & 1023, row)).r;

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

    // The debug seam reads the 1x shadow, so it is native for the same reason.
    if (p.software_display != 0) {
        return unpack1555(shadow.read(uint2(col, row)).r);
    }

    // The wrap is NATIVE, then scaled. A scaled mask `& (1024 * s - 1)` -- the
    // form the parent spec specifies -- is a modulo only at power-of-two s and
    // samples the wrong column at s = 3; a scaled modulo is correct but invents
    // a second coordinate space, which Phase C's rule that ps1_vram_read
    // linearizes natively already declined.
    return unpack1555(vram.read(uint2(col * p.scale + sub_x,
                                      row * p.scale + sub_y)).r);
}
```

At scale 1, `nx == px`, `sub_x == 0` and `sw == p.width`, so every expression above reduces to the previous shader character for character. "1× is unchanged" is a claim about a `* 1`, not about a rewritten shader.

- [ ] **Step 5: Rebuild the shader library and run the tests**

Run: `zig build metallib && ps1-macos/test.sh 2>&1 | tail -40`

Expected: PASS — the six new tests, plus the five pre-existing `DisplayRenderTests` cases unchanged (they construct `DisplayParams()`, whose `scale` now defaults to 1, so their pixels are identical).

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Shaders/DisplayShader.metal \
        ps1-macos/Sources/PS1/MetalDisplayView.swift \
        ps1-macos/Tests/PS1Tests/DisplayScaleTests.swift
git commit -m "feat(macos): sample the display pass at the internal resolution

px comes from width * scale, then splits into a native coordinate and a
subtexel. The scanout wrap is NATIVE then scaled -- ((vram_x + nx) & 1023)
* s + sub_x -- and NOT the parent spec's & (1024*s - 1), which is a modulo
only at power-of-two s and samples the wrong column at s = 3.

24bpp and PS1_SOFTWARE_DISPLAY keep reading the 1024x512 shadow at nx/ny
with the subtexel discarded: 24bpp packs bytes across adjacent 16-bit
words, which N x N replication destroys.

The subtexel test is the one that fails for a shader that scales only the
wraps -- an implementation that is byte-identical to 1x everywhere, so
every other gate here passes it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Rebuild the render path at the chosen scale

**Files:**
- Modify: `ps1-macos/Sources/PS1/MetalDisplayView.swift:40-43` (the view), `:62-121` (`Coordinator`), `:130-131` and `:176-179` (`draw`)
- Modify: `ps1-macos/Sources/PS1/ContentView.swift:11-21`
- Test: `ps1-macos/Tests/PS1Tests/LiveRendererScaleTests.swift`

**Interfaces:**
- Consumes: `EmulatorViewModel.internalScale` (Task 1), `DisplayParams.scale` (Task 2), `LiveRenderer(device:queue:scale:)` and `MetalVram.scale` (both already exist), `StreamQueue.requestResync()`.
- Produces: `MetalDisplayView(runner:scale:)` and `MetalDisplayView.Coordinator(runner:scale:)`. Task 4's menu reaches this only through `ContentView`.

- [ ] **Step 1: Write the failing tests**

Create `ps1-macos/Tests/PS1Tests/LiveRendererScaleTests.swift`:

```swift
import Testing
import Metal
import CPs1
@testable import PS1

/// Publishes one frame of records with no payload.
private func publish(_ q: StreamQueue, seq: UInt64, _ cmds: [Ps1GpuCommand]) {
    cmds.withUnsafeBufferPointer { buf in
        q.publish(seq: seq, records: buf.baseAddress!, recordCount: buf.count,
                  payload: nil, payloadCount: 0, complete: true)
    }
}

private func fillRect(x: Int32, y: Int32, w: Int32, h: Int32,
                      color: UInt32) -> Ps1GpuCommand {
    var c = Ps1GpuCommand()
    c.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
    c.x = x; c.y = y; c.w = w; c.h = h
    c.value = color
    return c
}

/// `copy_rect` reads x/y as the SOURCE and x2/y2 as the DESTINATION
/// (`command.zig:64`).
private func copyRect(srcX: Int32, srcY: Int32, dstX: Int32, dstY: Int32,
                      w: Int32, h: Int32) -> Ps1GpuCommand {
    var c = Ps1GpuCommand()
    c.kind = UInt8(PS1_GPU_COPY_RECT.rawValue)
    c.x = srcX; c.y = srcY; c.x2 = dstX; c.y2 = dstY; c.w = w; c.h = h
    return c
}

@Test func aLiveDrainAtScaleMatchesTheOneXReplayOfTheSameStream() throws {
    // Phase C's downsample-invariance property, re-run through the LIVE path
    // rather than the fixture harness -- the queue, the resync decision and
    // the persistent buffers are all in the picture here and are not in
    // MetalScaleHarness's.
    //
    // Fills and a VRAM->VRAM copy: both are exactly scale-invariant, and the
    // copy is the one read Phase C does NOT reduce to native (it carries
    // sub_x/sub_y so a blit preserves scaled detail), so it is worth having on
    // this path. Deliberately no Gouraud shading: dithering is on at 1x and
    // off above it BY DESIGN, so a dithered gradient legitimately differs.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }

    func run(_ live: LiveRenderer) {
        let q = StreamQueue()
        q.clearResync()
        publish(q, seq: 1, [
            fillRect(x: 7, y: 11, w: 33, h: 17, color: 0x03E0),
            fillRect(x: 40, y: 11, w: 20, h: 20, color: 0x7C00),
        ])
        publish(q, seq: 2, [copyRect(srcX: 7, srcY: 11, dstX: 200, dstY: 300,
                                     w: 33, h: 17)])
        live.drain(from: q) { ([], 0) }
    }

    let one = try LiveRenderer(device: device, queue: queue, scale: 1)
    run(one)
    let reference = one.vram.readbackNative()
    #expect(reference.contains { $0 != 0 }, "the stream painted nothing")

    for scale in [2, 3, 4, 8] {
        let many = try LiveRenderer(device: device, queue: queue, scale: scale)
        run(many)
        #expect(many.vram.readbackNative() == reference, "scale \(scale)")
        #expect(many.lastExecutedSeq == 2)
    }
}

@Test func buildingTheCoordinatorRaisesAResyncOnTheRunnersQueue() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let runner = EmulatorRunner(core: try Ps1Core(), ring: AudioRing(capacity: 8192))
    // A scale change keeps the runner, and therefore keeps its queue, so
    // StreamQueue's `resync` default (true, for a FRESH queue) does not fire.
    // Clearing it here is what a running game looks like.
    runner.streams.clearResync()

    _ = MetalDisplayView.Coordinator(runner: runner, scale: 2)

    // A fresh MetalVram is a BLANK texture and a command stream is a set of
    // incremental mutations: applying the next queued stream to it leaves the
    // picture permanently wrong with nothing naming the cause. The request
    // belongs in `init` -- unmissable there, and a harmless no-op on the
    // disc-change path where the flag is already set.
    #expect(runner.streams.needsResync)
}

@Test func theCoordinatorBuildsItsRendererAtTheScaleItWasGiven() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let runner = EmulatorRunner(core: try Ps1Core(), ring: AudioRing(capacity: 8192))
    let coordinator = MetalDisplayView.Coordinator(runner: runner, scale: 3)
    // `params.scale` is read back off the renderer rather than off a second
    // stored copy, so the uniform cannot drift from the texture it addresses.
    #expect(coordinator.liveForTesting.vram.scale == 3)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ps1-macos/test.sh 2>&1 | tail -30`

Expected: FAIL — `extra argument 'scale' in call` on both `Coordinator` constructions, and `value of type 'Coordinator' has no member 'liveForTesting'`.

- [ ] **Step 3: Thread the scale through `MetalDisplayView`**

In `ps1-macos/Sources/PS1/MetalDisplayView.swift`:

Replace the view's stored properties and `makeCoordinator` (`:40-43`):

```swift
struct MetalDisplayView: NSViewRepresentable {
    let runner: EmulatorRunner
    /// Internal resolution, 1...8. `ContentView` keys `.id()` on this as well
    /// as on the runner, so a change rebuilds the coordinator rather than
    /// reconfiguring it — see `Coordinator.init`.
    let scale: Int

    func makeCoordinator() -> Coordinator { Coordinator(runner: runner, scale: scale) }
```

Change the coordinator's `live` to be test-visible and take the scale (`:68` and `:77-121`):

```swift
        private let live: LiveRenderer
        /// The renderer, for tests that need to see which scale it was built
        /// at. `live` itself stays private: nothing outside should drive it.
        var liveForTesting: LiveRenderer { live }
```

and

```swift
        /// A scale change rebuilds `MetalVram` and therefore the render
        /// texture, so this whole object is rebuilt with it — the same path a
        /// disc change already takes. Rebuilding pipelines for a rare,
        /// user-initiated event is fine; a second bespoke reconfiguration path
        /// is not.
        init(runner: EmulatorRunner, scale: Int) {
```

…keeping the body unchanged down to the `LiveRenderer` construction, which becomes:

```swift
            let live: LiveRenderer
            do {
                live = try LiveRenderer(device: device, queue: queue, scale: scale)
            } catch {
                fatalError("Live renderer failed to build: \(error)")
            }
            self.live = live

            self.device = device
            self.queue = queue
            self.pipeline = pipeline
            self.shadowTexture = texture
            self.runner = runner

            // A fresh MetalVram is a BLANK texture, and a command stream is a
            // set of incremental mutations — applying the next queued stream
            // to it leaves the picture permanently wrong with no symptom that
            // names its cause. `StreamQueue.resync` defaults true, which
            // covers a FRESH queue; a scale change keeps the runner and
            // therefore keeps its queue, so the default does not fire. Doing
            // it here rather than at the call site makes it unmissable, and on
            // the disc-change path it is a no-op against a flag already set.
            runner.streams.requestResync()
        }
```

The shadow texture stays 1024×512: it is the 24bpp source and the resync source, and both are native by definition.

In `draw(in:)`, set the uniform from the renderer — immediately after `params.softwareDisplay` (`:130-131`):

```swift
            var params = DisplayParams()
            params.softwareDisplay = softwareDisplay ? 1 : 0
            // Read off the renderer, not off a second stored copy: the uniform
            // and the texture it addresses cannot drift apart.
            params.scale = UInt32(live.vram.scale)
```

- [ ] **Step 4: Key `ContentView` on the runner AND the scale**

In `ps1-macos/Sources/PS1/ContentView.swift`, add above `struct ContentView`:

```swift
/// What makes SwiftUI rebuild the display view. A new disc is a new runner and
/// a new queue; a new internal resolution is a new `MetalVram` and therefore a
/// new render texture, new pipelines and a new coordinator. Both are identity
/// changes, and there is deliberately no reconfiguration path for either.
private struct DisplayIdentity: Hashable {
    let runner: ObjectIdentifier
    let scale: Int
}
```

and replace the `.playing` branch's view construction (`:13-21`):

```swift
                if let runner = model.runner {
                    MetalDisplayView(runner: runner, scale: model.internalScale)
                        // SwiftUI may otherwise keep this view's identity
                        // across a disc swap and leave the coordinator holding
                        // the PREVIOUS runner. Harmless when it only read
                        // frames; wrong now that it drains a stream. The scale
                        // is in the key for the same reason: the coordinator
                        // owns a texture sized by it.
                        .id(DisplayIdentity(runner: ObjectIdentifier(runner),
                                            scale: model.internalScale))
                        .ignoresSafeArea()
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `ps1-macos/test.sh 2>&1 | tail -40`

Expected: PASS — the three new tests, plus every Phase B and C fixture gate unmoved. Confirm the fixture gates specifically:

Run: `ps1-macos/test.sh 2>&1 | grep -ci "failed"`

Expected: the failure count reported by xcodebuild is 0.

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1/MetalDisplayView.swift \
        ps1-macos/Sources/PS1/ContentView.swift \
        ps1-macos/Tests/PS1Tests/LiveRendererScaleTests.swift
git commit -m "feat(macos): rebuild the live render path at the chosen scale

ContentView keys .id() on the runner AND the scale, so a change rebuilds
the coordinator, its pipelines and its MetalVram through exactly the path
a disc change already uses.

Coordinator.init requests a resync unconditionally. A fresh MetalVram is
a BLANK texture and a command stream is incremental, so replaying the next
queued stream onto it is permanently wrong with nothing naming the cause.
StreamQueue's resync default covers a fresh queue; a scale change keeps
the runner and therefore keeps its queue, so the default does not fire.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The Video menu

**Files:**
- Create: `ps1-macos/Sources/PS1App/VideoCommands.swift`
- Modify: `ps1-macos/Sources/PS1App/PS1App.swift:33-41`

**Interfaces:**
- Consumes: `EmulatorViewModel.internalScale` (Task 1) and the rebuild it drives (Task 3).
- Produces: nothing later tasks depend on.

The spec is explicit that this is chrome and is not tested: everything decision-bearing — the clamp, the persistence, the rebuild, the shader — sits below it and is covered by Tasks 1–3. Verification here is by eye.

- [ ] **Step 1: Write `VideoCommands`**

Create `ps1-macos/Sources/PS1App/VideoCommands.swift`:

```swift
import SwiftUI
import PS1

/// The Video menu.
///
/// A `Commands` type rather than an inline `CommandMenu` in `PS1App.body` so
/// `@Bindable` produces the picker's binding directly. Building one with
/// `Binding(get:set:)` instead would capture the `@MainActor` model in two
/// escaping closures, which the Swift 6 language mode this target builds under
/// has to be argued out of. This is the same shape `ContentView` already uses.
///
/// Always enabled: internal resolution is a preference, not a per-session
/// control, and choosing one with no game loaded simply persists it.
struct VideoCommands: Commands {
    @Bindable var model: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Video") {
            Picker("Internal Resolution", selection: $model.internalScale) {
                ForEach(InternalResolution.menuRange, id: \.self) { n in
                    Text("\(n)×")
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                        .tag(n)
                }
            }
            // Inline, so the eight scales are top-level items in the Video
            // menu and their shortcuts are visible rather than buried in a
            // submenu.
            .pickerStyle(.inline)
        }
    }
}
```

- [ ] **Step 2: Expose the range to the PS1App module**

`InternalResolution` is `internal` to the PS1 module, so `PS1App` cannot name it. Add a public re-export in `ps1-macos/Sources/PS1/InternalResolution.swift`, at the bottom of the file:

```swift
extension InternalResolution {
    /// The range as the menu needs it. Public — and separate from `range`,
    /// which stays internal — so the PS1App target can build the picker
    /// without the whole type crossing the module boundary.
    public static var menuRange: ClosedRange<Int> { range }
}
```

Change `struct InternalResolution` to `public struct InternalResolution` and leave every member's access unchanged; only `menuRange` is public.

- [ ] **Step 3: Install the menu**

In `ps1-macos/Sources/PS1App/PS1App.swift`, add after the `CommandMenu("Machine")` block (`:40`), still inside `.commands { … }`:

```swift
            VideoCommands(model: model)
```

- [ ] **Step 4: Build the app**

Run: `zig build capi-lib && zig build metallib && zig build macos`

Expected: `zig-out/PS1.app` builds with no errors.

- [ ] **Step 5: Verify the menu by eye**

```bash
./zig-out/PS1.app/Contents/MacOS/PS1
```

Expected: a **Video** menu holding `1×` … `8×` with a checkmark on the current one and ⌘1…⌘8 beside them; picking one persists (quit and relaunch — the checkmark is where you left it) and, with a game running, the picture reappears after a brief resync rather than going wrong or blank.

**If the shortcuts do not appear beside the picker's options** — `keyboardShortcut` on a `Picker` option is not a documented contract, and the checkmark matters more than the accelerator — replace the `Picker` in `VideoCommands` with buttons, which draw their own checkmark and definitely carry shortcuts:

```swift
        CommandMenu("Video") {
            ForEach(InternalResolution.menuRange, id: \.self) { n in
                Button(model.internalScale == n ? "✓ \(n)×" : "   \(n)×") {
                    model.internalScale = n
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }
```

- [ ] **Step 6: Commit**

```bash
git add ps1-macos/Sources/PS1App/VideoCommands.swift \
        ps1-macos/Sources/PS1App/PS1App.swift \
        ps1-macos/Sources/PS1/InternalResolution.swift
git commit -m "feat(macos): a Video menu for internal resolution, 1x...8x

A Commands type rather than an inline CommandMenu so @Bindable produces
the picker's binding directly -- Binding(get:set:) would capture the
@MainActor model in escaping closures.

Chrome, and untested on purpose: the clamp, the persistence, the rebuild
and the shader all sit below it and are covered.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: The exploratory gate — five games at N ∈ {2,3,4}, and the 1×/8× A/B

**Files:** none. This task produces a commit message and, if anything diverges, a banked fixture.

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: the recorded result. Nothing depends on it in code.

- [ ] **Step 1: Build the app**

Run: `zig build capi-lib && zig build metallib && zig build macos`

Expected: builds clean.

- [ ] **Step 2: Understand what the oracle is doing before running it**

`LiveRenderer.diff` reads `vram.readbackNative()`, which is already the top-left-subtexel view at any scale. So at N > 1 the existing 1× oracle becomes a **live downsample-invariance check on real games** — for free, and it is the only coverage above 1× that exists outside the eleven-fixture corpus.

**A silent run is not by itself evidence.** The oracle compares only when the newest published frame is the one the texture holds, and it runs after a `drain` that blocks on the GPU, so most frames are skipped. It prints a running `checked N frames, skipped M` tally every 300 decisions and once more on eject. **Read that tally.** A run reporting `checked 0` proves nothing at all.

- [ ] **Step 3: Run each of the five games at each of three scales**

```bash
PS1_LIVE_DIFF=1 ./zig-out/PS1.app/Contents/MacOS/PS1
```

For each of Croc, Silent Hill, Spyro, Crash Bandicoot and Tomb Raider (`tr1-usa-v1-1`): set the Video menu to 2×, play past the boot logo into gameplay, then 3×, then 4×. Watch stdout.

Expected: **no `PS1_LIVE_DIFF` divergence lines**, and a non-zero `checked` count in every tally.

Record in the commit message, per game and per scale: the `checked`/`skipped` tally, and for each divergence the seq, the pixel count and the first coordinate.

**One class of divergence is not a bug and must be recognised rather than chased:** a primitive that samples its own destination. The software rasterizer scans row by row and sees its own new values deterministically; nothing orders fragments *within* one primitive on a GPU. `HazardTracker` orders one draw against the next and does not help — it is a divergence class, not a defect.

For anything else that diverges: bank that window as a fixture with `zig build fixtures` / `stream-capture`, add it to `MetalRasterizerTests`' corpus, and fix it in a follow-up commit with the fixture as its gate. **Never weaken a check to make a divergence go away.**

- [ ] **Step 4: The 1×/8× A/B by eye**

```bash
./zig-out/PS1.app/Contents/MacOS/PS1
```

On one fixed scene in Croc or Spyro, switch between 1× and 8× and look at polygon edges.

Expected: **a visible difference** — edges are sharper at 8×, and the dither cross-hatch on Gouraud gradients is gone (dithering is on at 1× and off above it, decided in the shader; that is correct and is Phase D's to revisit).

This step is here because a plausible implementation of this whole phase produces no visible change whatsoever, and only `theDisplayPassSamplesSubtexelsNotJustTheBlockCorner` would have caught it mechanically. This is the human confirmation of the same property.

- [ ] **Step 5: Confirm 24bpp and the debug seam still work above 1×**

```bash
./zig-out/PS1.app/Contents/MacOS/PS1                        # Croc's FMV at 4x
PS1_SOFTWARE_DISPLAY=1 ./zig-out/PS1.app/Contents/MacOS/PS1 # same scene at 4x
```

Expected: Croc's opening FMV renders correctly at 4× (that is the 24bpp shadow route, addressed at `nx`/`ny`), and the software-display run is visually indistinguishable at 15bpp.

- [ ] **Step 6: Commit the result**

```bash
git commit --allow-empty -m "test(macos): PS1_LIVE_DIFF at 2x/3x/4x over five games

<per game and scale: checked/skipped tally, and any divergence with its
 seq, pixel count and first coordinate>

1x/8x A/B on <scene>: edges visibly sharper at 8x, dither cross-hatch
absent above 1x as designed. Croc's FMV correct at 4x, and the
PS1_SOFTWARE_DISPLAY seam indistinguishable from it at 15bpp.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Rewrite the Metal backend's opening claim**

In `CLAUDE.md`, the paragraph beginning "**The Metal backend renders at an internal resolution of 1-8x and is now the LIVE display path at 1x.**" now ends with a sentence that is wrong: "**Scale above 1x is not wired to the app** — the picker, the scale-aware scanout wraps and the aspect interaction are Phase D2."

Replace the opening sentence and that closing one:

```markdown
**The Metal backend renders at an internal resolution of 1-8x, and since Phase
D2 that scale is a player-chosen setting that reaches the screen.**
`MetalRasterizer` (with `MetalVram`, `PrimBuilder`, `PrimEncoders`,
`HazardTracker`) consumes both `.p1fx` fixtures and, since Phase D1, the live
command stream: `ps1-capi` builds `gpu_sink = .dual`, `ps1_take_frame_stream`
drains one frame per `ps1_run_frame`, `EmulatorRunner` copies it into a 4-slot
ring, and `LiveRenderer` drains that ring from the `MTKView` draw callback.
`Video ▸ 1x…8x` (⌘1…⌘8) writes `InternalResolution` to `UserDefaults`;
`ContentView` keys `.id()` on the runner's identity AND the scale, so a change
rebuilds the coordinator, its pipelines, its `LiveRenderer` and its `MetalVram`
through exactly the path a disc change already uses.
```

- [ ] **Step 2: Add the D2 traps to the same section**

Append after the existing "Five things about the live path are load-bearing" paragraph and its two-switch paragraph:

```markdown
Four things about the SCALED display path are load-bearing. **The scanout wrap
is NATIVE, then scaled** — `((vram_x + nx) & 1023) * s + sub_x`, never
`& (1024*s - 1)`: a bitwise mask is a modulo only at power-of-two `s`, so at
`s = 3` a display window crossing the VRAM edge samples the wrong column. The
parent Metal spec specifies the mask form in two places; **it is wrong and must
not be implemented as written.** **Scaling the wraps alone is a no-op** — `px`
is derived from `p.width * p.scale`, and without that multiplication every
sample lands on its block's top-left subtexel, which by Phase C's exactness
property is byte-identical to the 1x picture: the player selects 8x, pays 67 MB
and sees nothing. **24bpp and the `PS1_SOFTWARE_DISPLAY` seam read the 1024x512
shadow at `nx`/`ny`, discarding `sub_x`/`sub_y`** — feeding them `px` breaks
every FMV in Croc and Silent Hill above 1x and nowhere else. And
**`MetalDisplayView.Coordinator.init` calls `requestResync()` unconditionally**,
because a rebuilt `MetalVram` is a BLANK texture while a command stream is a set
of incremental mutations; `StreamQueue`'s `resync` flag defaults true, but that
covers a FRESH queue, and a scale change keeps the runner and therefore keeps
its queue.

**The default is 1x, and that is a testability decision.** 1x is the only scale
with a per-frame byte-exact oracle on arbitrary content — the software shadow is
a reference for whatever is actually being played — and above it the check
weakens to downsample-invariance. Selecting 4x opts out of the stronger check
knowingly; the shipped configuration must not opt out for the player.
`InternalResolution.load` CLAMPS into 1...8 rather than trusting the stored
value, because `MetalVram.init` traps out of range and a `UserDefaults` integer
is data, not a literal.

**The 4:3 aspect lock does not interact with internal resolution.** The parent
spec lists that interaction as Phase D work; there is none, and this note exists
so nobody concludes it was forgotten. `letterboxScale` reads the drawable's
dimensions, `WindowConfigurator` reads a constant `NSSize(4, 3)`, and
`display_vertex` applies the letterbox to uv while leaving the triangle at full
viewport size — none of the three reads the renderer, the display area or the
scale. Internal resolution changes how finely the render texture is sampled, not
the dimensions of the picture or of the window.

**`PS1_LIVE_DIFF` works above 1x for free, and it is the only coverage there
outside the fixture corpus.** `LiveRenderer.diff` reads `vram.readbackNative()`,
which is already the top-left-subtexel view at any scale, so at N the oracle
becomes a live downsample-invariance check on real games. Its `checked/skipped`
tally still has to be read before an absence of output means anything.
```

- [ ] **Step 3: Note the setting in the macOS app section**

In the "## The macOS app" section, after the paragraph beginning "The app has three stages", add:

```markdown
`InternalResolution` is the app's second persisted setting, after
`ScopedBookmark`, and is shaped after it: `init` resolves from `UserDefaults`,
`set` persists, and the clamp lives in the type so it is reachable from a test
without a window.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: internal resolution is a setting that reaches the screen

Records the four load-bearing D2 rules -- native-then-scaled wrap, the
sampling multiplication that is the actual phase, 24bpp and the debug seam
staying on nx/ny, and the unconditional resync in the coordinator's init --
plus why the default is 1x and why the aspect lock does not interact.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **No Zig changed.** With `<base>` the commit this phase started from (`git log --oneline -1` before Task 1; it is `7491583` if nothing else landed first), run: `git diff --stat <base>..HEAD -- ps1-core ps1-capi ps1-golden ps1-debug ps1-trace ps1-wasm build.zig`. Expected: **empty.** This phase adds no Zig change, exactly as Phase C added none — so `zig build trace-golden -- verify` and the two ROM suites cannot have moved, and running them is confirmation rather than a gate.
- [ ] `zig build test` — 15 binaries green.
- [ ] `zig build capi-lib && zig build metallib && zig build macos` — the app builds.
- [ ] `ps1-macos/test.sh` — every pre-existing test plus the new ones, with **all eleven Phase B/C fixture hashes unmoved**. A moved hash is a bug in this phase, never a baseline to update.
- [ ] The Task 5 play-through result is recorded in a commit message, tallies included.
- [ ] The 1×/8× A/B confirmed a visible difference by eye. Without this, a phase that changed nothing on screen would pass every mechanical gate above except one.
