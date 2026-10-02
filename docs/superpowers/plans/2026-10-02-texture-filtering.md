# Texture Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Bilinear (No Edge Blending)" texture filter for textured triangles in the Metal renderer, selectable in Settings and the Video menu, that changes only the display-only sidecar.

**Architecture:** The textured-triangle fragment interpolates texcoords with six fractional bits (whose floor is exactly today's integer texcoord), fetches the four surrounding texels through the existing texture-window and CLUT path, and writes a filtered colour to the true-colour sidecar (`color(1)`) only. VRAM, the hole discard and the STP bit stay on the nearest texel, so no gate, golden or fixture hash can move. The filter is a runtime uniform beside `dither_mode`.

**Tech Stack:** Metal Shading Language (`ps1-macos/Shaders/`), Swift/SwiftUI, swift-testing, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-10-02-texture-filtering-design.md`

## Global Constraints

- No Zig changes, no golden moves, no `.p1fx` change. `zig build test` and `trace-golden` are not affected and need not run.
- VRAM (`color(0)`) must be byte-identical with the filter on and off, in every dither mode, at every scale.
- The hole (raw texel 0), the STP bit and the VRAM value are decided by the NEAREST texel, always.
- Textured RECTANGLES are never filtered.
- Six fractional bits exactly (`<< 6`); `iu = u6 >> 6` must replace today's interpolant, not sit beside it.
- The filter ships OFF: `TextureFilterSetting.defaultFilter == .nearest`.
- Persisted with `object(forKey:)`, never `integer(forKey:)` (0 is a valid value).
- `MetalFixtureHarness.replay` pins `.nearest`; Gate 1 never inherits a player default.
- Menu/picker titles: "Nearest-Neighbour" and "Bilinear (No Edge Blending)". The plain "Bilinear" label is reserved for the edge-blending follow-up.
- Commit messages are a title line only, no body, no trailer. Commit directly on master. Never `git push`.
- After ANY `.metal` or shader-header edit, run `zig build metallib` before `xcodebuild`, or the tests run the OLD shader.
- `pkill -x Substation` before every `xcodebuild test` run.

## Running tests

Every task uses this command shape (run from the repo root). `test.sh` takes no
filter, so targeted runs call `xcodebuild` directly. swift-testing free
functions need the trailing `()`, and a filter that matches nothing reports
"passed" with `Executed 0 tests`: always read the `Executed N tests` line.

```bash
pkill -x Substation; zig build metallib && zig build capi-lib && \
xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" SYMROOT="$PWD/.build/xcode" test \
  -only-testing:'PS1Tests/<testName>()' 2>&1 | grep -E "✘|✔|Executed|error:"
```

Repeat `-only-testing:` once per test. The full suite is `ps1-macos/test.sh`
(about 2.5 min with `zig build -Doptimize=ReleaseFast fixtures` already run).
A full run that reports `Failing tests:` with zero `✘` lines is the known
scale-8 crash under load, not a failure: re-run before believing it.

## Review Focus

1. **A semi-transparent filtered triangle in a dithering mode** must show the filtered blend, not the nearest one. The `.off`/`.native`/`.scaled` blend path currently derives `out8` from the nearest `out`. Pinned by `aSemiTransparentFilteredDrawBlendsTheFilteredColourInDitheringModes` (Task 3).
2. **A texture window (GP0(E2))** must wrap filtered neighbours inside the window exactly as the nearest texel wraps, or repeating textures bleed in texels from outside the window. Pinned by `filteredNeighboursWrapInsideTheTextureWindow` (Task 3).
3. **4bpp and 8bpp CLUT textures** must be filtered on the CLUT's output colours, never on the indices. Pinned by `bilinearAddsLevelsAtEveryTextureDepth` (Task 3).
4. **Atlas neighbours below the primitive's UV range** (`u_min - 1`) are the only side a centred bilinear sample can reach, and clamping is what stops the bleed. Pinned by `uvLimitsKeepAtlasNeighboursOut` (Task 3).
5. **Changing the setting while a game runs** must take effect on the next frame without a coordinator rebuild. Pinned by `theTextureFilterReachesTheRasterizerWithoutARebuild` (Task 4).

---

### Task 1: The setting, the enum and the uniform

Adds the value end to end, with no shader behaviour yet: the uniform reaches
the GPU and nothing reads it. It also extracts the persisted-enum logic
`DitherSetting` already has. This is its second user, and copying it would
leave two hand-maintained copies of the same load rule.

**Files:**
- Create: `ps1-macos/Sources/PS1/PersistedChoice.swift`
- Create: `ps1-macos/Sources/PS1/TextureFilter.swift`
- Create: `ps1-macos/Tests/PS1Tests/TextureFilterSettingTests.swift`
- Modify: `ps1-macos/Sources/PS1/DitherMode.swift` (`DitherSetting`, lines ~59-106)
- Modify: `ps1-macos/Shaders/PrimInstance.h:157-173`
- Modify: `ps1-macos/Shaders/Rasterizer.metal:14`
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift:58` and `:287-288`
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift:30-31`
- Modify: `ps1-macos/Tests/PS1Tests/MetalMoverTests.swift:154`

**Interfaces:**
- Produces: `enum TextureFilter: Int { case nearest = 0, bilinear = 1 }` with `title: String` and `uniformValue: UInt32`; `struct TextureFilterSetting { static let defaultsKey = "textureFilter"; static let defaultFilter: TextureFilter; var filter: TextureFilter; init(key:defaults:); mutating func set(_:) }`; `MetalRasterizer.textureFilter: TextureFilter`; C `PS1_FILTER_NEAREST`, `PS1_FILTER_BILINEAR`; `Ps1RasterUniforms.texture_filter`; `struct PersistedChoice<Value>`.

- [ ] **Step 1: Write the failing tests**

`ps1-macos/Tests/PS1Tests/TextureFilterSettingTests.swift`:

```swift
import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

/// A fresh defaults key per test, as `DitherModeTests` does: these write the
/// real `UserDefaults`, and a shared key would clobber the user's own setting.
private func uniqueKey() -> String { "test-texture-filter-\(UUID().uuidString)" }

@Test func textureFilterRawValuesMatchTheShaderHeader() {
    // The enum MIRRORS PrimInstance.h's PS1_FILTER_*, and the uniform carries
    // the raw value straight to the GPU: a renumbering on one side alone
    // compiles and silently selects the other filter.
    #expect(TextureFilter.nearest.uniformValue == UInt32(PS1_FILTER_NEAREST))
    #expect(TextureFilter.bilinear.uniformValue == UInt32(PS1_FILTER_BILINEAR))
}

@Test func anUnusedTextureFilterKeyLoadsAsNearest() {
    // Shipped off, as DuckStation ships it.
    #expect(TextureFilterSetting(key: uniqueKey()).filter == .nearest)
    #expect(TextureFilterSetting.defaultFilter == .nearest)
}

@Test func theTextureFilterRoundTripsThroughUserDefaults() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = TextureFilterSetting(key: key)
    written.set(.bilinear)
    #expect(written.filter == .bilinear)
    #expect(TextureFilterSetting(key: key).filter == .bilinear)
}

@Test func aStoredNearestPersistsRatherThanReadingBackAsTheDefault() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    // 0 is a real choice. Today it equals the default, so this pins the load
    // rule (object(forKey:)) rather than the value: it fails the day the
    // default moves if the load ever becomes `integer(forKey:)` plus a
    // "0 means unset" fallback.
    UserDefaults.standard.set(0, forKey: key)
    #expect(TextureFilterSetting(key: key).filter == .nearest)
    var written = TextureFilterSetting(key: key)
    written.set(.bilinear)
    written.set(.nearest)
    #expect(TextureFilterSetting(key: key).filter == .nearest)
}

@Test func anUnrecognisedTextureFilterFallsBackToNearest() {
    let key = uniqueKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    // A filter written by a future build (JINC2, xBR) and then downgraded.
    UserDefaults.standard.set(7, forKey: key)
    #expect(TextureFilterSetting(key: key).filter == .nearest)
}

@Test func aFreshRasterizerCarriesNearest() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    #expect(r.textureFilter == .nearest)
}
```

In `MetalScaleTests.swift:25-32`, rename the layout test and move it to 12:

```swift
@Test func theRasterUniformIsTwelveBytesOnBothSides() {
    // The Metal side carries `static_assert(sizeof(Ps1RasterUniforms) == 12)`.
    // This is the other half of that pair: a field added on one side only
    // shears `scale`, `dither_mode` and `texture_filter` against each other,
    // and the symptom would be "scale 1 renders at scale 0", i.e. nothing
    // drawn at all.
    #expect(MemoryLayout<Ps1RasterUniforms>.stride == 12)
    #expect(MemoryLayout<Ps1RasterUniforms>.size == 12)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the command from "Running tests" with the six new test names.
Expected: build error, `cannot find 'TextureFilter' in scope` / `PS1_FILTER_NEAREST`.

- [ ] **Step 3: Header constants and the uniform field**

In `PrimInstance.h`, after the `PS1_DITHER_*` enum (line 161), add:

```c
/* Texture filtering (Ps1RasterUniforms.texture_filter). DISPLAY-ONLY: a
 * filtered colour reaches the true-colour sidecar and never VRAM, and the
 * hole, the STP bit and the VRAM value stay on the nearest texel, so no gate
 * can see this setting. Textured rectangles are never filtered. BILINEAR is
 * DuckStation's "Bilinear (No Edge Blending)": cut-out edges stay sharp. */
enum {
    PS1_FILTER_NEAREST = 0,
    PS1_FILTER_BILINEAR = 1
};
```

Change the uniform struct and its comment's first line ("the internal
resolution and the dither mode") to also name the texture filter:

```c
typedef struct {
    unsigned int scale;          /* internal resolution, 1...8 */
    unsigned int dither_mode;    /* PS1_DITHER_* above */
    unsigned int texture_filter; /* PS1_FILTER_* above */
} Ps1RasterUniforms;
```

In `Rasterizer.metal:14`: `static_assert(sizeof(Ps1RasterUniforms) == 12, ...)`.

- [ ] **Step 4: Extract `PersistedChoice`**

`ps1-macos/Sources/PS1/PersistedChoice.swift`:

```swift
import Foundation

/// An `Int`-backed enum persisted in `UserDefaults`, with a load that REJECTS.
///
/// It reads `object(forKey:)` rather than `integer(forKey:)` because 0 is a
/// valid case of every enum stored this way, so the 0 that `integer(forKey:)`
/// invents for a missing key would read back as a deliberate choice. A stored
/// value no case matches (hand-edited, or written by a newer build and then
/// downgraded) falls back the same way: a `UserDefaults` integer is DATA.
struct PersistedChoice<Value: RawRepresentable> where Value.RawValue == Int {
    private let defaults: UserDefaults
    private let key: String
    private(set) var value: Value

    init(key: String, defaults: UserDefaults, fallback: Value) {
        self.defaults = defaults
        self.key = key
        if let raw = defaults.object(forKey: key) as? Int, let stored = Value(rawValue: raw) {
            self.value = stored
        } else {
            self.value = fallback
        }
    }

    mutating func set(_ newValue: Value) {
        value = newValue
        defaults.set(newValue.rawValue, forKey: key)
    }
}
```

In `DitherMode.swift`, replace `DitherSetting`'s stored properties, `init`
and `set` (keep `defaultsKey`, `defaultMode` and both doc comments; move the
"It reads `object(forKey:)`..." paragraph's reasoning to a one-line pointer,
since `PersistedChoice` now carries it):

```swift
    private var choice: PersistedChoice<DitherMode>
    var mode: DitherMode { choice.value }

    init(key: String = DitherSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultMode)
    }

    mutating func set(_ value: DitherMode) { choice.set(value) }
```

- [ ] **Step 5: The enum and its setting**

`ps1-macos/Sources/PS1/TextureFilter.swift`:

```swift
import Foundation

/// How a textured TRIANGLE samples its texture in the picture the player sees.
///
/// Display-only: the filtered colour reaches the true-colour sidecar and
/// never VRAM, and the hole, the STP bit and VRAM's value all stay on the
/// nearest texel, so no gate can tell the two apart. Textured rectangles
/// (HUDs, text, 2D sprites) are never filtered. `PrimInstance.h`'s
/// `PS1_FILTER_*` are the shader's half, pinned by
/// `textureFilterRawValuesMatchTheShaderHeader`.
public enum TextureFilter: Int, CaseIterable, Identifiable, Sendable {
    case nearest = 0
    /// DuckStation's "Bilinear (No Edge Blending)". Plain "Bilinear", which
    /// also softens cut-out edges, is a separate later case.
    case bilinear = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .nearest: return "Nearest-Neighbour"
        case .bilinear: return "Bilinear (No Edge Blending)"
        }
    }

    /// The value `Ps1RasterUniforms.texture_filter` carries.
    public var uniformValue: UInt32 { UInt32(rawValue) }
}

/// The persisted texture filter. Same shape as `DitherSetting`.
struct TextureFilterSetting {
    static let defaultsKey = "textureFilter"
    /// Off, as DuckStation ships it.
    static let defaultFilter = TextureFilter.nearest

    private var choice: PersistedChoice<TextureFilter>
    var filter: TextureFilter { choice.value }

    init(key: String = TextureFilterSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultFilter)
    }

    mutating func set(_ value: TextureFilter) { choice.set(value) }
}
```

- [ ] **Step 6: Carry it into the uniform**

`MetalRasterizer.swift`, after `var ditherMode = DitherSetting.defaultMode`:

```swift

    /// How textured triangles sample, for the sidecar only: see `TextureFilter`.
    /// A uniform for `ditherMode`'s reason: the instance bytes Gate 1 checks
    /// stay identical whatever it is.
    var textureFilter = TextureFilterSetting.defaultFilter
```

and at the uniform construction (`:287`):

```swift
            var uni = Ps1RasterUniforms(scale: UInt32(vram.scale),
                                        dither_mode: ditherMode.uniformValue,
                                        texture_filter: textureFilter.uniformValue)
```

`MetalMoverTests.swift:154`:

```swift
    var uni = Ps1RasterUniforms(scale: 1, dither_mode: UInt32(PS1_DITHER_OFF),
                                texture_filter: UInt32(PS1_FILTER_NEAREST))
```

- [ ] **Step 7: Run the tests to verify they pass**

Run the six new tests, `theRasterUniformIsTwelveBytesOnBothSides()`, and the `DitherModeTests` tests `anUnusedKeyLoadsAsTheDefaultRatherThanAsOff()`,
`offPersistsRatherThanReadingBackAsTheDefault()`,
`anUnrecognisedPersistedValueFallsBackToTheDefault()`.
Expected: all PASS, `Executed 10 tests`.

- [ ] **Step 8: Commit**

```bash
git add ps1-macos/Sources/PS1/PersistedChoice.swift ps1-macos/Sources/PS1/TextureFilter.swift \
  ps1-macos/Sources/PS1/DitherMode.swift ps1-macos/Sources/PS1/MetalRasterizer.swift \
  ps1-macos/Shaders/PrimInstance.h ps1-macos/Shaders/Rasterizer.metal \
  ps1-macos/Tests/PS1Tests/TextureFilterSettingTests.swift \
  ps1-macos/Tests/PS1Tests/MetalScaleTests.swift ps1-macos/Tests/PS1Tests/MetalMoverTests.swift
git commit -m "feat(macos): texture filter setting and uniform"
```

---

### Task 2: Fractional texcoords and a shared windowed fetch (no behaviour change)

Two refactors the filter needs. Both are pinned by the existing gates
staying green, and this task must move no pixel anywhere.

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal:268-296` (`ps1_sample`) and `:399-402` (texcoord interpolation)

**Interfaces:**
- Produces: `inline ushort ps1_window_fetch(const device Ps1PrimInstance& p, texture2d<ushort, access::read> vram, uint s, uint u, uint v)`, returning the raw texel (0 = hole) after the texture window. Local `int u6`, `int v6` in the textured-triangle branch, holding the texcoord with six fractional bits.

- [ ] **Step 1: Extract `ps1_window_fetch`**

Insert immediately above `ps1_sample`'s doc comment block (the `///` lines
that start above `inline bool ps1_sample`):

```metal
/// The texture window, then the fetch: the RAW texel at (u, v), 0 meaning a
/// hole. Everything that reads a texel goes through here, so a bilinear
/// neighbour wraps inside the window exactly as the nearest texel does.
/// The window is in TEXEL units, like u and v: nothing here scales.
inline ushort ps1_window_fetch(const device Ps1PrimInstance& p,
                               texture2d<ushort, access::read> vram, uint s,
                               uint u, uint v) {
    uint mask_x   = (p.tex_window & 0x1Fu) * 8u;
    uint mask_y   = ((p.tex_window >> 5) & 0x1Fu) * 8u;
    uint offset_x = ((p.tex_window >> 10) & 0x1Fu) * 8u;
    uint offset_y = ((p.tex_window >> 15) & 0x1Fu) * 8u;
    uint final_u = (u & ~mask_x) | (offset_x & mask_x);
    uint final_v = (v & ~mask_y) | (offset_y & mask_y);
    return ps1_fetch_texel(vram, s, p.tex_depth, p.tpage_x, p.tpage_y,
                           p.clut_x, p.clut_y, final_u, final_v);
}
```

and replace `ps1_sample`'s first eleven body lines (the four `mask_`/`offset_`
lines, the comment, the two `final_` lines and the `ps1_fetch_texel` call)
with:

```metal
    ushort texel = ps1_window_fetch(p, vram, s, u, v);
```

- [ ] **Step 2: Six fractional bits on the texcoord**

Replace lines 399-402:

```metal
        int iu = ps1_interp_attr(tex_persp, w0, w1, w2, area, p.u0, p.u1, p.u2, p.rw0, p.rw1, p.rw2);
        int iv = ps1_interp_attr(tex_persp, w0, w1, w2, area, p.v0, p.v1, p.v2, p.rw0, p.rw1, p.rw2);
        uint u = uint(clamp(iu, 0, 255));
        uint v = uint(clamp(iv, 0, 255));
```

with:

```metal
        // SIX fractional bits, which only the texture filter reads. The integer
        // texcoord is their floor, and for a non-negative value
        // floor(floor(64x) / 64) == floor(x), so `u6 >> 6` IS the old
        // interpolant on both paths, bit for bit: one interpolation, not two.
        // The bound: `ps1_interp_w`'s numerator reaches 2^55 with an 8-bit
        // attribute, so a 14-bit one reaches 2^61, inside `long`; the affine
        // numerator is w * a with w <= area, far below that.
        int u6 = ps1_interp_attr(tex_persp, w0, w1, w2, area,
                                 p.u0 << 6, p.u1 << 6, p.u2 << 6, p.rw0, p.rw1, p.rw2);
        int v6 = ps1_interp_attr(tex_persp, w0, w1, w2, area,
                                 p.v0 << 6, p.v1 << 6, p.v2 << 6, p.rw0, p.rw1, p.rw2);
        uint u = uint(clamp(u6 >> 6, 0, 255));
        uint v = uint(clamp(v6 >> 6, 0, 255));
```

- [ ] **Step 3: Run the textured gates to verify nothing moved**

Run with these filters (each is an existing test):
`texturedTrianglesAreDownsampleInvariantAtAllThreeDepths()`,
`perspectiveCorrectionReachesTheInteriorOfABlockAtEightX()`,
`aModulatedTexelKeepsMoreThanThirtyTwoLevelsInTheSidecar()`,
`theCorpusRendersIdenticalVramInTrueColourAndOff()`.
Expected: all PASS.

- [ ] **Step 4: Run the full Swift suite**

```bash
pkill -x Substation; zig build -Doptimize=ReleaseFast fixtures && zig build metallib && zig build capi-lib && ps1-macos/test.sh 2>&1 | tail -15
```

Expected: every test passes. This is Gate 1 (every fixture hash), Gate 2
(downsample-invariance) and the PGXP-on parity gate over the new interpolant.
Any failure here means the floor identity was broken, and it must be fixed,
not recaptured.

- [ ] **Step 5: Commit**

```bash
git add ps1-macos/Shaders/Rasterizer.metal
git commit -m "refactor(metal): fractional texcoords and a shared windowed fetch"
```

---

### Task 3: The bilinear filter

**Files:**
- Modify: `ps1-macos/Shaders/Ps1Color.h` (add `ps1_filtered` after `ps1_modulate`, ~line 208)
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (add `ps1_bilinear` after `ps1_sample`; edit `ps1_prim_fragment`)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift:35-45` (add a `filter:` parameter)
- Create: `ps1-macos/Tests/PS1Tests/TextureFilterTests.swift`

**Interfaces:**
- Consumes: `ps1_window_fetch`, `u6`/`v6` (Task 2); `uni.texture_filter`, `PS1_FILTER_BILINEAR`, `MetalRasterizer.textureFilter` (Task 1).
- Produces: `MetalScaleHarness.frame(scale:payload:preload:dither:filter:wantSidecar:_:)`, where `filter: TextureFilter = .nearest`.

- [ ] **Step 1: Give the harness a filter**

In `MetalScaleHarness.frame`, add the parameter after `dither`, and assign it
beside `r.ditherMode = dither`:

```swift
    static func frame(scale: Int, payload: [UInt32] = [], preload: [UInt16]? = nil,
                      dither: DitherMode = .off, filter: TextureFilter = .nearest,
                      wantSidecar: Bool = false,
                      _ body: (MetalRasterizer) -> Void) throws -> Frame? {
```

```swift
        r.ditherMode = dither
        r.textureFilter = filter
```

- [ ] **Step 2: Write the failing tests**

`ps1-macos/Tests/PS1Tests/TextureFilterTests.swift`:

```swift
import Testing
import Foundation
import Metal
import CPs1
@testable import PS1

/// Texture filtering's own gates.
///
/// The primary assertion is negative, as true colour's was: VRAM is
/// byte-identical under both filters, so nothing a gate reads can move. The
/// rest pin the sidecar: what filtering adds, and the three ways it could
/// smear the wrong colour in (a hole, an atlas neighbour, a texture window).

private let w = MetalVram.nativeWidth
/// The 16bpp texture page every hand-built test samples: tpage 0x0104 puts
/// page X at unit 4, i.e. VRAM x = 256, y = 0.
private let page16: UInt16 = 0x0104
private let pageX = 256

/// A native VRAM with `row` written at (256 + u, v) for v in 0..<rows.
private func vramWithRows(_ row: [UInt16], rows: Int = 16) -> [UInt16] {
    var v = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<rows { for (u, t) in row.enumerated() { v[y * w + pageX + u] = t } }
    return v
}

private func drawingArea(_ r: MetalRasterizer) {
    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023
    r.apply(area)
}

/// A right triangle at (300, 300) whose legs are `size` px and span texcoords
/// `u0...u1` horizontally and `v0...v1` vertically: a magnified texture.
private func texturedTriangle(opcode: UInt8 = 0x25, tpage: UInt16 = page16, clut: UInt16 = 0,
                              u0: UInt8, u1: UInt8, v0: UInt8 = 0, v1: UInt8 = 2,
                              size: Int16 = 128, colors: (UInt32, UInt32, UInt32) = (0, 0, 0),
                              flags: UInt8 = 0, rw: (Int32, Int32, Int32) = (0, 0, 0))
    -> (MetalRasterizer) -> Void {
    return { r in
        drawingArea(r)
        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue)
        tri.opcode = opcode
        tri.tpage = tpage
        tri.clut = clut
        tri.v.0 = Ps1GpuVertex(x: 300, y: 300, u: u0, v: v0, _pad: 0, color: colors.0)
        tri.v.1 = Ps1GpuVertex(x: 300 + size, y: 300, u: u1, v: v0, _pad: 0, color: colors.1)
        tri.v.2 = Ps1GpuVertex(x: 300, y: 300 + size, u: u0, v: v1, _pad: 0, color: colors.2)
        tri.v.0.rw = rw.0; tri.v.1.rw = rw.1; tri.v.2.rw = rw.2
        tri.flags = flags
        r.apply(tri)
    }
}

/// Every PRESENT sidecar pixel's red byte inside the triangle's box.
private func sidecarReds(_ f: MetalScaleHarness.Frame, size: Int = 128) -> [UInt8] {
    guard let side = f.sidecar else { return [] }
    var reds: [UInt8] = []
    let s = f.scale
    for y in (300 * s)..<((300 + size) * s) {
        for x in (300 * s)..<((300 + size) * s) {
            let i = y * f.width + x
            if side[i * 4 + 3] == 255 { reds.append(side[i * 4]) }
        }
    }
    return reds
}

/// Red 1 -> red 31 -> red 31: a hard edge one texel wide, magnified 64x.
private let edgeRow: [UInt16] = [0x0001, 0x001F, 0x001F, 0x001F]

// MARK: - VRAM never moves

@Test func theCorpusRendersIdenticalVramUnderBothFilters() throws {
    // THE gate. Every fixture that exists, every frame, two dither modes (a
    // dithering one, since the VRAM path there carries the offset) and two
    // scales (3 because `/ s` is a shift at every power of two).
    let corpus = ["synthetic-primitives", "synthetic-movers", "silent-hill-usa", "tr1-usa-v1-1"]
    for name in corpus where generatedFixtureExists(name) {
        for dither in [DitherMode.native, .trueColor] {
            for scale in [1, 3] {
                guard let device = MTLCreateSystemDefaultDevice(),
                      let queue = device.makeCommandQueue(),
                      let a = MetalVram(device: device, queue: queue, scale: scale),
                      let b = MetalVram(device: device, queue: queue, scale: scale) else { return }
                let nearest = try MetalRasterizer(vram: a)
                let bilinear = try MetalRasterizer(vram: b)
                for r in [nearest, bilinear] { r.ditherMode = dither }
                nearest.textureFilter = .nearest
                bilinear.textureFilter = .bilinear
                let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
                withExtendedLifetime(file) {
                    for i in 0..<file.frames.count {
                        for r in [nearest, bilinear] {
                            r.beginFrame(payload: file.payload(for: i))
                            for cmd in file.records(for: i) { r.apply(cmd) }
                            r.endFrame()
                        }
                        #expect(a.readback() == b.readback(),
                                Comment(rawValue: "\(name) \(dither) @\(scale)x frame \(i): VRAM moved"))
                    }
                }
            }
        }
    }
}

// MARK: - What it adds

@Test func bilinearAddsLevelsAcrossAMagnifiedEdge() throws {
    let draw = texturedTriangle(u0: 0, u1: 2)
    let vram = vramWithRows(edgeRow)
    guard let near = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    #expect(Set(sidecarReds(near)).count == 2, "the control: nearest has exactly two reds")
    #expect(Set(sidecarReds(bil)).count > 16,
            "bilinear has \(Set(sidecarReds(bil)).count) reds across a 64x-magnified edge")
    #expect(near.scaled == bil.scaled, "VRAM moved")
}

@Test func bilinearAddsLevelsAtEveryTextureDepth() throws {
    // Filtered on the CLUT's OUTPUT. A 4bpp/8bpp texel is an index; the four
    // indices 0, 1, 1, 1 map through a CLUT at (0, 240) to edgeRow's colours.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    vram[240 * w + 1] = 0x0001
    vram[240 * w + 2] = 0x001F
    for y in 0..<16 {
        vram[y * w + pageX] = 0x2221        // 4bpp: indices 1,2,2,2 in one word
        vram[y * w + 128] = 0x0201          // 8bpp page at x = 128: indices 1,2
        vram[y * w + 129] = 0x0202          //                          2,2
    }
    let clut: UInt16 = 240 << 6
    for (label, tpage) in [("4bpp", UInt16(0x0004)), ("8bpp", UInt16(0x0082))] {
        let draw = texturedTriangle(tpage: tpage, clut: clut, u0: 0, u1: 2)
        guard let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                    filter: .bilinear, wantSidecar: true, draw)
        else { return }
        #expect(Set(sidecarReds(bil)).count > 16, "\(label): filtering did not reach the CLUT colours")
    }
}

@Test func aUniformTextureFiltersToItselfInEveryMode() throws {
    // T == t5 << 3 everywhere, and every per-mode formula reproduces today's
    // sidecar there bit for bit. Modulated and Gouraud-shaded with dithering
    // ON (GP0(E1) bit 9), so the dithering modes' formula is exercised too.
    let vram = vramWithRows([UInt16](repeating: 0x2D6B, count: 4))
    let draw: (MetalRasterizer) -> Void = { r in
        var mode = Ps1GpuCommand()
        mode.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        mode.opcode = 0xE1
        mode.value = 1 << 9
        r.apply(mode)
        texturedTriangle(opcode: 0x34, u0: 0, u1: 3, v1: 3,
                         colors: (0x0020_4060, 0x00FF_C080, 0x0010_8040))(r)
    }
    for dither in DitherMode.allCases {
        guard let near = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                     filter: .nearest, wantSidecar: true, draw),
              let bil = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                    filter: .bilinear, wantSidecar: true, draw)
        else { return }
        #expect(sidecarReds(near).count > 1000, "\(dither): the triangle drew nothing")
        #expect(near.sidecar == bil.sidecar, "\(dither): a uniform texture filtered to something else")
        #expect(near.scaled == bil.scaled)
    }
}

@Test func perspectiveTexcoordsFilterToo() throws {
    let draw = texturedTriangle(u0: 0, u1: 2, flags: UInt8(PS1_GPU_FLAG_TEXTURE_PERSPECTIVE),
                                rw: (65536, 16384, 65536))
    let vram = vramWithRows(edgeRow)
    guard let near = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    #expect(Set(sidecarReds(bil)).count > 16)
    #expect(near.scaled == bil.scaled, "VRAM moved on the perspective path")
}

// MARK: - What it must not smear in

@Test func aHoleNeighbourDrawsNoFringe() throws {
    // texel 0 bright, texel 1 a HOLE. Filtering the hole as black darkens
    // every pixel beside a cut-out; weight zero leaves them at the texel.
    let draw = texturedTriangle(u0: 0, u1: 1)
    let vram = vramWithRows([0x001F, 0x0000])
    guard let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil)
    #expect(reds.count > 1000, "the triangle drew nothing")
    #expect(reds.allSatisfy { $0 == 255 }, "a hole was filtered in: min red \(reds.min() ?? 0)")
}

@Test func uvLimitsKeepAtlasNeighboursOut() throws {
    // An atlas cell at u/v 4..7, all blue, with RED in the column and row just
    // below it. A centred sample at U < 4.5 reaches u = 3 unless clamped.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<12 {
        for u in 0..<12 {
            vram[y * w + pageX + u] = (u == 3 || y == 3) ? 0x001F : 0x7C00
        }
    }
    let draw = texturedTriangle(u0: 4, u1: 7, v0: 4, v1: 7)
    guard let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil)
    #expect(reds.count > 1000, "the triangle drew nothing")
    #expect(reds.allSatisfy { $0 == 0 }, "an atlas neighbour bled in: max red \(reds.max() ?? 0)")
}

@Test func filteredNeighboursWrapInsideTheTextureWindow() throws {
    // GP0(E2) mask field 0x1F clears bits 3-7 of u and v, offset 0: every
    // coordinate wraps into 0..7. Inside that window texels are blue;
    // u = 8.. and v = 8.. are red and must never be reached.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<24 {
        for u in 0..<24 { vram[y * w + pageX + u] = (u < 8 && y < 8) ? 0x7C00 : 0x001F }
    }
    let draw: (MetalRasterizer) -> Void = { r in
        var win = Ps1GpuCommand()
        win.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        win.opcode = 0xE2
        win.value = 0x1F | (0x1F << 5)     // u & 7, v & 7
        r.apply(win)
        texturedTriangle(u0: 0, u1: 20, v0: 0, v1: 20)(r)
    }
    guard let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil)
    #expect(reds.count > 1000, "the triangle drew nothing")
    #expect(reds.allSatisfy { $0 == 0 }, "a texel outside the window bled in")
}

// MARK: - Dithering modes and blending

@Test func theDitheringModesStayFiveBitUnderBilinear() throws {
    let draw = texturedTriangle(u0: 0, u1: 2)
    let vram = vramWithRows(edgeRow)
    for dither in [DitherMode.off, .native, .scaled] {
        guard let near = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                     filter: .nearest, wantSidecar: true, draw),
              let bil = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                    filter: .bilinear, wantSidecar: true, draw)
        else { return }
        let reds = sidecarReds(bil)
        // `expand` of a five-bit value: the byte is (c << 3) | (c >> 2).
        #expect(reds.allSatisfy { r in let c = r >> 3; return r == (c << 3) | (c >> 2) },
                "\(dither): an eight-bit value reached a five-bit mode's sidecar")
        #expect(Set(reds).count > Set(sidecarReds(near)).count,
                "\(dither): filtering changed nothing")
    }
}

@Test func aSemiTransparentFilteredDrawBlendsTheFilteredColourInDitheringModes() throws {
    // Review Focus 1. Raw + semi-transparent (opcode 0x27), STP-set texels,
    // mode 1 (add) over a grey fill. Before the fix `out8` came from the
    // NEAREST blend in the dithering modes and showed exactly two reds.
    let vram = vramWithRows([0x8001, 0x801F, 0x801F, 0x801F])
    let draw: (MetalRasterizer) -> Void = { r in
        drawingArea(r)
        var fill = Ps1GpuCommand()
        fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
        fill.value = 0x0008                // dark red background, 15-bit
        fill.x = 288; fill.y = 288; fill.w = 160; fill.h = 160
        r.apply(fill)
        texturedTriangle(opcode: 0x27, tpage: page16 | (1 << 5), u0: 0, u1: 2)(r)
    }
    for dither in [DitherMode.off, .trueColor] {
        guard let bil = try MetalScaleHarness.frame(scale: 2, preload: vram, dither: dither,
                                                    filter: .bilinear, wantSidecar: true, draw)
        else { return }
        #expect(Set(sidecarReds(bil)).count > 8,
                "\(dither): the blend shows \(Set(sidecarReds(bil)).count) reds; it used the nearest texel")
    }
}

@Test func texturedRectanglesAreNeverFiltered() throws {
    let vram = vramWithRows(edgeRow)
    let draw: (MetalRasterizer) -> Void = { r in
        drawingArea(r)
        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = 0x65                  // raw textured sprite
        spr.tpage = page16
        spr.x = 300; spr.y = 300; spr.w = 4; spr.h = 4
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: 0, v: 0, _pad: 0, color: 0)
        r.apply(spr)
    }
    guard let near = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                filter: .bilinear, wantSidecar: true, draw)
    else { return }
    #expect(sidecarReds(near, size: 4).count > 100, "the sprite drew nothing")
    #expect(near.sidecar == bil.sidecar)
}
```

`generatedFixtureExists` is the module-level helper in
`FixtureBridgeTests.swift:76`.

- [ ] **Step 3: Run the tests to verify they fail**

Run all eleven tests in `TextureFilterTests.swift`.
Expected: `theCorpusRendersIdenticalVramUnderBothFilters`,
`aUniformTextureFiltersToItselfInEveryMode`, `aHoleNeighbourDrawsNoFringe`,
`uvLimitsKeepAtlasNeighboursOut`, `filteredNeighboursWrapInsideTheTextureWindow`
and `texturedRectanglesAreNeverFiltered` PASS (the shader ignores the uniform,
so the filter is not yet doing anything). `bilinearAddsLevelsAcrossAMagnifiedEdge`,
`bilinearAddsLevelsAtEveryTextureDepth`, `perspectiveTexcoordsFilterToo`,
`theDitheringModesStayFiveBitUnderBilinear` and
`aSemiTransparentFilteredDrawBlendsTheFilteredColourInDitheringModes` FAIL on
their level counts.

- [ ] **Step 4: `ps1_filtered` in `Ps1Color.h`**

Insert after `ps1_modulate`:

```metal
/// The SIDECAR's value for a bilinear-filtered texel, and its five-bit form.
///
/// `t` is the filtered texel per channel in units of 1/8 of a five-bit step
/// (0..248): `t5 << 3` at a texel centre. Every expression is chosen so that
/// `t == t5 << 3` reproduces today's sidecar value bit for bit:
///
///   modulated, true colour   (t * c8) >> 7       == (t5 * c8) >> 4
///   modulated, dithering     ((t * c5) >> 4) + d == ((t5 * c5) >> 1) + d
///   raw, true colour         t + (t >> 5)        == t5 << 3 | t5 >> 2
///   raw, dithering           pack(t)             == t5
///
/// The return is the FIVE-BIT filtered colour with the nearest texel's STP
/// bit: what a dithering mode's sidecar blends with. VRAM never sees it.
inline ushort ps1_filtered(int3 t, bool modulate, ushort shade, ushort3 shade8,
                           int dither_o, bool true_colour, ushort stp,
                           thread ushort3& out8) {
    if (modulate) {
        int3 c5 = int3(shade & 0x1F, (shade >> 5) & 0x1F, (shade >> 10) & 0x1F);
        int3 m = ((t * c5) >> 4) + dither_o;
        ushort f = ps1_pack(m.x, m.y, m.z) | stp;
        int3 m8 = (t * int3(shade8)) >> 7;
        out8 = true_colour ? ps1_pack8(m8.x, m8.y, m8.z) : ps1_expand(f);
        return f;
    }
    ushort f = ps1_pack(t.x, t.y, t.z) | stp;
    int3 e = t + (t >> 5);
    out8 = true_colour ? ps1_pack8(e.x, e.y, e.z) : ps1_expand(f);
    return f;
}
```

- [ ] **Step 5: `ps1_bilinear` in `Rasterizer.metal`**

Insert after `ps1_sample`:

```metal
/// Bilinear filtering over the four texels around (u6, v6), six fractional
/// bits each, for the SIDECAR only. Returns the filtered texel per channel in
/// units of 1/8 of a five-bit step (see `ps1_filtered`).
///
/// Samples are texel CENTRES, so the base texel is floor((u6 - 32) / 64), a
/// real floor because u6 - 32 can be -32. Three rules:
/// - UV LIMITS: each sample is clamped to the primitive's own texcoord range
///   before the window, or an atlas cell pulls in its neighbour. A centred
///   sample reaches one texel BELOW the range and never above it.
/// - A HOLE has weight zero and the rest renormalise; filtering it as black
///   draws a dark fringe around every cut-out.
/// - The weight sum is never zero: the nearest texel (u6 >> 6) is one of the
///   four with weight >= 32 on each axis, it lies inside the limits (a convex
///   combination of the three texcoords), and it is not a hole, or the
///   fragment would already have discarded.
inline int3 ps1_bilinear(const device Ps1PrimInstance& p,
                         texture2d<ushort, access::read> vram, uint s,
                         int u6, int v6) {
    int umin = min(p.u0, min(p.u1, p.u2)), umax = max(p.u0, max(p.u1, p.u2));
    int vmin = min(p.v0, min(p.v1, p.v2)), vmax = max(p.v0, max(p.v1, p.v2));
    int bu = ps1_floor_div(u6 - 32, 64), bv = ps1_floor_div(v6 - 32, 64);
    int fu = (u6 - 32) - bu * 64, fv = (v6 - 32) - bv * 64;
    int3 acc = int3(0);
    int wsum = 0;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            ushort t = ps1_window_fetch(p, vram, s, uint(clamp(bu + i, umin, umax)),
                                        uint(clamp(bv + j, vmin, vmax)));
            if (t == 0) continue;
            int wt = (i == 0 ? 64 - fu : fu) * (j == 0 ? 64 - fv : fv);
            acc += wt * (int3(t & 0x1F, (t >> 5) & 0x1F, (t >> 10) & 0x1F) << 3);
            wsum += wt;
        }
    }
    return acc / wsum;
}
```

- [ ] **Step 6: Wire it into `ps1_prim_fragment`**

Beside `ushort src; ushort3 src8; uint iz = 0u;` add:

```metal
    // The five-bit colour a dithering mode's SIDECAR blends with. It differs
    // from `src` only for a bilinear-filtered texel; VRAM always blends `src`.
    bool filtered = false;
    ushort side5 = 0;
```

In the textured-triangle branch, after
`transparent = transparent && (src & 0x8000) != 0;` add:

```metal
        // Bilinear touches the SIDECAR only. `src` (VRAM's value), the hole
        // and the STP bit above were all decided by the nearest texel.
        if (uni.texture_filter == PS1_FILTER_BILINEAR) {
            side5 = ps1_filtered(ps1_bilinear(p, vram, uint(s), u6, v6),
                                 (p.flags & PS1_PRIM_MODULATE) != 0, shade,
                                 ps1_pack8(sr, sg, sb), dither_o, true_colour,
                                 src & 0x8000, src8);
            filtered = true;
        }
```

In the blend tail, replace:

```metal
    } else {
        out8 = ps1_expand(out);
    }
```

with:

```metal
    } else {
        // A filtered draw blends its FILTERED five-bit colour, so a dithering
        // mode shows a filtered composite; unfiltered, this is `out` exactly.
        out8 = ps1_expand(filtered ? ps1_blend(dst, side5, p.blend_mode) : out);
    }
```

- [ ] **Step 7: Run the filter tests to verify they pass**

Run all eleven `TextureFilterTests` tests.
Expected: all PASS, `Executed 11 tests`.

- [ ] **Step 8: Run the full Swift suite**

```bash
pkill -x Substation; zig build metallib && zig build capi-lib && ps1-macos/test.sh 2>&1 | tail -15
```

Expected: every test passes (the default is `.nearest`, so no existing
assertion moves).

- [ ] **Step 9: Commit**

```bash
git add ps1-macos/Shaders/Ps1Color.h ps1-macos/Shaders/Rasterizer.metal \
  ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift ps1-macos/Tests/PS1Tests/TextureFilterTests.swift
git commit -m "feat(metal): bilinear texture filtering in the sidecar"
```

---

### Task 4: The setting in the app

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift:174-185`
- Modify: `ps1-macos/Sources/PS1/LiveRenderer.swift:37-42`
- Modify: `ps1-macos/Sources/PS1/MetalDisplayView.swift:58-85, 113, 155`
- Modify: `ps1-macos/Sources/PS1/ContentView.swift:29-30`
- Modify: `ps1-macos/Sources/PS1/Settings/SettingsCopy.swift:100-120, 246`
- Modify: `ps1-macos/Sources/PS1/Settings/VideoSettingsPane.swift`
- Modify: `ps1-macos/Sources/PS1App/VideoCommands.swift:37-44`
- Modify: `ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift:31-39`
- Modify: `ps1-macos/Tests/PS1Tests/TextureFilterSettingTests.swift`

**Interfaces:**
- Consumes: `TextureFilter`, `TextureFilterSetting`, `MetalRasterizer.textureFilter` (Task 1).
- Produces: `EmulatorViewModel.textureFilter: TextureFilter`; `LiveRenderer.textureFilter`; `MetalDisplayView.textureFilter`; `MetalDisplayView.Coordinator.init(runner:scale:ditherMode:textureFilter:depthBuffer:)`, where `textureFilter` defaults to `TextureFilterSetting.defaultFilter`; `SettingsCopy.textureFiltering`.

- [ ] **Step 1: Write the failing test**

Append to `TextureFilterSettingTests.swift`:

```swift
@Test func theTextureFilterReachesTheRasterizerWithoutARebuild() throws {
    // Review Focus 5. A runtime uniform, like dithering: the coordinator is
    // NOT rebuilt, so `updateNSView`'s assignment must land on the live
    // rasterizer the next frame encodes with.
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return }
    let live = try LiveRenderer(device: device, queue: queue)
    #expect(live.textureFilter == .nearest)
    live.textureFilter = .bilinear
    // The getter reads the (private) rasterizer's own field, so this is the
    // value the next encoded frame's uniform carries.
    #expect(live.textureFilter == .bilinear)
}
```

- [ ] **Step 2: Run it to verify it fails**

Expected: build error, `value of type 'LiveRenderer' has no member 'textureFilter'`.

- [ ] **Step 3: Plumb it**

`LiveRenderer.swift`, after the `ditherMode` property:

```swift

    /// How textured triangles sample, for the sidecar: see `TextureFilter`.
    /// A runtime uniform, assigned by `MetalDisplayView.updateNSView`.
    var textureFilter: TextureFilter {
        get { rasterizer.textureFilter }
        set { rasterizer.textureFilter = newValue }
    }
```

`EmulatorViewModel.swift`, after the `ditherMode` property:

```swift

    /// The texture filter, persisted: a runtime uniform exactly like
    /// `ditherMode`, so no `.id()` rebuild.
    private var textureFilterSetting = TextureFilterSetting()

    public var textureFilter: TextureFilter {
        get { textureFilterSetting.filter }
        set { textureFilterSetting.set(newValue) }
    }
```

`MetalDisplayView.swift`: after `let ditherMode: DitherMode` add

```swift
    /// How textured triangles sample. Like `ditherMode`, NOT part of the `.id()`.
    let textureFilter: TextureFilter
```

`makeCoordinator` passes `textureFilter: textureFilter`; `updateNSView` adds
`context.coordinator.live.textureFilter = textureFilter`; `Coordinator.init`
gains `textureFilter: TextureFilter = TextureFilterSetting.defaultFilter`
after `ditherMode`, and beside `live.ditherMode = ditherMode` (line 155):
`live.textureFilter = textureFilter`.

`ContentView.swift:29-30`:

```swift
                    MetalDisplayView(runner: runner, scale: model.internalScale,
                                     depthBuffer: depthBuffer, ditherMode: model.ditherMode,
                                     textureFilter: model.textureFilter)
```

`MetalFixtureHarness.replay`: add `filter: TextureFilter = .nearest` after
`dither`, extend the doc comment's pinning sentence to "`dither` and `filter`
are PINNED here", and set `renderer.textureFilter = filter` beside
`renderer.ditherMode = dither`.

- [ ] **Step 4: Copy, the Settings picker and the menu**

`SettingsCopy.swift`, after `ditherMode(_:)`:

```swift

    static let textureFiltering = SettingInfo(
        title: "Texture Filtering",
        summary: "Smooths textures on 3D surfaces so they no longer break up into visible squares up close.",
        details: "Nearest-Neighbour shows each texture pixel as a sharp square, as the console did. Bilinear blends neighbouring texture pixels into a smooth surface. Only 3D surfaces are smoothed: menus, text and 2D sprites stay sharp, and so do the cut-out edges of things like foliage and fences. It changes only the picture you see, never what the game itself reads back."
    )
```

and add `textureFiltering` after `dithering` in `allInfo`.

`VideoSettingsPane.swift`: add a third `Section` after the dithering one,
and update the type comment to "Internal resolution, dithering and texture
filtering, the Video menu preferences.":

```swift
            Section {
                SettingRow(SettingsCopy.textureFiltering) {
                    Picker(SettingsCopy.textureFiltering.title, selection: $model.textureFilter) {
                        ForEach(TextureFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
```

`VideoCommands.swift`, after the Dithering `Picker`:

```swift

            Picker("Texture Filtering", selection: $model.textureFilter) {
                ForEach(TextureFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run `theTextureFilterReachesTheRasterizerWithoutARebuild()` and the
`SettingsCopyTests` (`-only-testing:PS1Tests/SettingsCopyTests`).
Expected: all PASS. If `everySentenceIsFinished` or `noLongDashes` fail,
fix the copy, not the test.

- [ ] **Step 6: Build the app and look at it**

```bash
pkill -x Substation; zig build macos && open zig-out/Substation.app
```

Open Settings ▸ Video: three pickers, Texture Filtering last, with its info
button showing the details text. Check that the Video menu has the Texture
Filtering picker. Boot a 3D game at 4x, switch Bilinear on and off while it
runs: textures smooth and sharpen at once, with no black frame (no rebuild),
and HUD text stays sharp.

- [ ] **Step 7: Full suite and commit**

```bash
pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -15
git add ps1-macos/Sources ps1-macos/Tests
git commit -m "feat(macos): texture filtering in Settings and the Video menu"
```

---

### Task 5: Cost and documentation

**Files:**
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift:868-905` (Gate 4 measures both filters)
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md` (new section)
- Modify: `CLAUDE.md` (one rule line under **GPU + Metal**)

- [ ] **Step 1: Gate 4 measures the filter**

Give `replayForTiming` a `filter: TextureFilter` parameter that it assigns to
`r.textureFilter`. In `measuresReplayCostAtEachScale`, loop
`for filter in TextureFilter.allCases` inside the scale loop and append
`\(filter)` to the printed label:

```swift
        for scale in [1, 2, 4, 8] {
            for filter in TextureFilter.allCases {
                let t0 = DispatchTime.now().uptimeNanoseconds
                guard let frames = try replayForTiming(name, scale: scale, filter: filter) else { continue }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                let label = name.padding(toLength: 30, withPad: " ", startingAt: 0)
                print("[gate-4] \(label) @\(scale)x \(filter)  "
                      + String(format: "%8.1f ms", ms) + "  (\(frames) frames)")
            }
        }
```

- [ ] **Step 2: Measure**

```bash
pkill -x Substation; touch zig-out/fixtures/PS1_SCALE_TIMING
xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" SYMROOT="$PWD/.build/xcode" test \
  -parallel-testing-enabled NO -only-testing:'PS1Tests/measuresReplayCostAtEachScale()' \
  2>&1 | grep "gate-4"
rm zig-out/fixtures/PS1_SCALE_TIMING
```

Run it twice and keep the second run. Record the `silent-hill-usa` and
`tr1-usa-v1-1` numbers at 4x and 8x for both filters. Divide by the frame
count to get ms/frame.

- [ ] **Step 3: Document**

Add a section `## Texture filtering (2026-10-02)` to the `ps1-gpu-metal`
skill, after the true-colour material, covering, in this codebase's voice:
- that it is sidecar-only and why (the three gates), and that VRAM equality
  over the corpus is the gate (`theCorpusRendersIdenticalVramUnderBothFilters`);
- the `u6 >> 6` floor identity and the 2^61 bound;
- the centred-sample convention, and that UV limits only ever bite on the
  LOW side;
- holes at weight zero, and why the sum cannot be zero;
- the per-mode table from `ps1_filtered` and the `side5` blend in the
  dithering modes;
- that it is DuckStation's "No Edge Blending" variant, and that edge
  blending is possible (write `dst` back to VRAM, blend into the sidecar),
  being the next spec;
- the measured Gate 4 cost from Step 2, stated plainly.

In `CLAUDE.md`, under **GPU + Metal**, after the sidecar-alpha rule, add:

```markdown
- **Texture filtering is SIDECAR-ONLY.** VRAM, the hole and the STP bit stay
  on the nearest texel; the filtered colour reaches `color(1)` alone, and
  `u6 >> 6` must stay the one texcoord interpolant both share.
```

- [ ] **Step 4: Commit**

```bash
git add ps1-macos/Tests/PS1Tests/MetalScaleTests.swift .claude/skills/ps1-gpu-metal/SKILL.md CLAUDE.md
git commit -m "docs: texture filtering cost and rules"
```
