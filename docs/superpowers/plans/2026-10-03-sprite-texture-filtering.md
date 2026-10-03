# Sprite Texture Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second setting, Sprite Texture Filtering, that applies to textured rectangles and screen-aligned 2D polygons, with DuckStation's sprite/3D split deciding which of the two settings a textured primitive follows.

**Architecture:** The fragment shader classes each textured primitive as a sprite or 3D from its own instance fields (a rectangle is always a sprite; a triangle with a depth on all three vertices is always 3D; any other triangle is a sprite iff its texture is screen-aligned) and picks `uni.sprite_filter` or `uni.texture_filter`. Rectangles gain a bilinear path at the subtexel centre with limits that follow the 256-texel wrap; `ps1_bilinear` takes its limits as arguments so both primitive kinds share one filter body. Everything stays sidecar-only: VRAM, the hole and the STP bit stay on the nearest texel.

**Tech Stack:** Metal Shading Language (`ps1-macos/Shaders/`), Swift/SwiftUI, swift-testing, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-10-03-sprite-texture-filtering-design.md` (builds on `docs/superpowers/specs/2026-10-02-texture-filtering-design.md`)

## Global Constraints

- No Zig changes, no golden moves, no `.p1fx` change. `zig build test` and `trace-golden` are not affected and need not run.
- VRAM (`color(0)`) must be byte-identical under all four combinations of the two settings, in every dither mode, at every scale.
- The hole (raw texel 0), the STP bit and the VRAM value are decided by the NEAREST texel, always.
- The sprite/3D class chooses only WHICH setting applies; it never changes what either filter does.
- Both settings use the one `TextureFilter` enum. The sprite setting's key is `spriteTextureFilter`, its default `.nearest`, persisted through `PersistedChoice` (`object(forKey:)`, never `integer(forKey:)`).
- `MetalFixtureHarness.replay` pins BOTH settings to `.nearest`; Gate 1 never inherits a player default.
- `Ps1RasterUniforms` is 16 bytes: `scale`, `dither_mode`, `texture_filter`, `sprite_filter`, in that order, on both sides.
- Picker/menu titles: "Texture Filtering" and "Sprite Texture Filtering"; choices "Nearest-Neighbour" and "Bilinear (No Edge Blending)".
- Commit messages are a title line only, no body, no trailer. Commit directly on master. Never `git push`.
- After ANY `.metal` or shader-header edit, run `zig build metallib` before `xcodebuild`, or the tests run the OLD shader.
- `pkill -x Substation` before every `xcodebuild test` run.

## Running tests

Every task uses this command shape (run from the repo root). `test.sh` takes no
filter, so targeted runs call `xcodebuild` directly. swift-testing free
functions need the trailing `()`, and a filter that matches nothing reports
"passed" with `Executed 0 tests`: always read the `Test run with N tests` line.

```bash
pkill -x Substation; zig build metallib && zig build capi-lib && \
xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" SYMROOT="$PWD/.build/xcode" test \
  -only-testing:'PS1Tests/<testName>()' 2>&1 | grep -E "✘|✔|Test run|error:"
```

Repeat `-only-testing:` once per test. The full suite is
`pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -15` (fixtures already
exist in `zig-out/fixtures`). A full run that reports failing tests with zero
`✘` lines is the known scale-8 crash under load: re-run before believing it.

## Review Focus

1. **A screen-aligned 3D surface** (a floor seen from directly above, a wall facing the camera) carrying PGXP depths must follow Texture Filtering, not the sprite setting. Pinned by `aTriangleWithDepthFollowsTheTextureSettingEvenWhenScreenAligned` (Task 2).
2. **Mirrored 2D quads** (a character sprite drawn facing left as a polygon, `du/dx < 0`) are still sprites. Pinned by `aMirroredScreenAlignedTriangleIsStillASprite` (Task 2).
3. **A rectangle crossing the 256-texel wrap** must not blend across the wrap seam or past its own last column. Pinned by `aRectangleNeverFiltersPastItsWrapSegment` (Task 3).
4. **A semi-transparent sprite in a dithering mode** must composite its filtered colour, not the nearest one. Pinned by `aSemiTransparentFilteredSpriteBlendsTheFilteredColour` (Task 3).
5. **A tiled background drawn with a texture window (GP0(E2))** must wrap filtered neighbours inside the window. Pinned by `aWindowedSpriteFiltersInsideItsWindow` (Task 3).

---

### Task 1: The sprite setting and the uniform

Adds the value end to end with no shader behaviour: the uniform reaches the GPU
and nothing reads it yet.

**Files:**
- Modify: `ps1-macos/Shaders/PrimInstance.h` (the `PS1_FILTER_*` comment and `Ps1RasterUniforms`, ~lines 163-185)
- Modify: `ps1-macos/Shaders/Rasterizer.metal:14` (`static_assert`)
- Modify: `ps1-macos/Sources/PS1/TextureFilter.swift`
- Modify: `ps1-macos/Sources/PS1/MetalRasterizer.swift` (`textureFilter` property ~line 63; uniform construction ~line 292)
- Modify: `ps1-macos/Tests/PS1Tests/MetalMoverTests.swift:154-155`
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift:25-33`
- Modify: `ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift` (`replay`, ~lines 30-42)
- Modify: `ps1-macos/Tests/PS1Tests/TextureFilterSettingTests.swift`

**Interfaces:**
- Consumes: `TextureFilter`, `PersistedChoice`, `TextureFilterSetting` (existing).
- Produces: `struct SpriteFilterSetting { static let defaultsKey = "spriteTextureFilter"; static let defaultFilter: TextureFilter; var filter: TextureFilter; init(key:defaults:); mutating func set(_:) }`; `MetalRasterizer.spriteFilter: TextureFilter`; C `Ps1RasterUniforms.sprite_filter`; `MetalFixtureHarness.replay(..., spriteFilter: TextureFilter = .nearest, ...)`.

- [ ] **Step 1: Write the failing tests**

Append to `ps1-macos/Tests/PS1Tests/TextureFilterSettingTests.swift`:

```swift
// MARK: - Sprite Texture Filtering

private func uniqueSpriteKey() -> String { "test-sprite-filter-\(UUID().uuidString)" }

@Test func anUnusedSpriteFilterKeyLoadsAsNearest() {
    // Shipped off, as DuckStation ships it.
    #expect(SpriteFilterSetting(key: uniqueSpriteKey()).filter == .nearest)
    #expect(SpriteFilterSetting.defaultFilter == .nearest)
    #expect(SpriteFilterSetting.defaultsKey == "spriteTextureFilter")
}

@Test func theSpriteFilterRoundTripsThroughUserDefaults() {
    let key = uniqueSpriteKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    var written = SpriteFilterSetting(key: key)
    written.set(.bilinear)
    #expect(written.filter == .bilinear)
    #expect(SpriteFilterSetting(key: key).filter == .bilinear)
}

@Test func anUnrecognisedSpriteFilterFallsBackToNearest() {
    let key = uniqueSpriteKey()
    defer { UserDefaults.standard.removeObject(forKey: key) }
    UserDefaults.standard.set(7, forKey: key)
    #expect(SpriteFilterSetting(key: key).filter == .nearest)
}

@Test func aFreshRasterizerCarriesANearestSpriteFilter() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let vram = MetalVram(device: device, queue: queue) else { return }
    let r = try MetalRasterizer(vram: vram)
    #expect(r.spriteFilter == .nearest)
}
```

In `MetalScaleTests.swift`, replace `theRasterUniformIsTwelveBytesOnBothSides`
with:

```swift
@Test func theRasterUniformIsSixteenBytesOnBothSides() {
    // The Metal side carries `static_assert(sizeof(Ps1RasterUniforms) == 16)`.
    // This is the other half of that pair: a field added on one side only
    // shears `scale`, `dither_mode`, `texture_filter` and `sprite_filter`
    // against each other, and the symptom would be "scale 1 renders at
    // scale 0", i.e. nothing drawn at all.
    #expect(MemoryLayout<Ps1RasterUniforms>.stride == 16)
    #expect(MemoryLayout<Ps1RasterUniforms>.size == 16)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the command from "Running tests" with `anUnusedSpriteFilterKeyLoadsAsNearest`,
`theSpriteFilterRoundTripsThroughUserDefaults`,
`anUnrecognisedSpriteFilterFallsBackToNearest`,
`aFreshRasterizerCarriesANearestSpriteFilter`,
`theRasterUniformIsSixteenBytesOnBothSides`.
Expected: build error, `cannot find 'SpriteFilterSetting' in scope`.

- [ ] **Step 3: The header and the static_assert**

In `PrimInstance.h`, replace the `PS1_FILTER_*` comment block with:

```c
/* Texture filtering (Ps1RasterUniforms.texture_filter and .sprite_filter).
 * DISPLAY-ONLY: a filtered colour reaches the true-colour sidecar and never
 * VRAM, and the hole, the STP bit and the VRAM value stay on the nearest
 * texel, so no gate can see either setting. Which of the two a primitive
 * follows is `ps1_is_sprite`'s decision. BILINEAR is DuckStation's
 * "Bilinear (No Edge Blending)": cut-out edges stay sharp. */
```

Change the uniform comment's first sentence to "Per-DRAW state that is not
per-primitive: the internal resolution, the dither mode and the two texture
filters." (re-wrapped at ~78 columns like its neighbours), and the struct to:

```c
typedef struct {
    unsigned int scale;          /* internal resolution, 1...8 */
    unsigned int dither_mode;    /* PS1_DITHER_* above */
    unsigned int texture_filter; /* PS1_FILTER_*, for 3D primitives */
    unsigned int sprite_filter;  /* PS1_FILTER_*, for sprites (ps1_is_sprite) */
} Ps1RasterUniforms;
```

In `Rasterizer.metal:14`: `static_assert(sizeof(Ps1RasterUniforms) == 16,`.

- [ ] **Step 4: The setting**

In `TextureFilter.swift`, change the enum's doc comment first line to "How a
textured primitive samples its texture in the picture the player sees." and
replace the sentence "Textured rectangles (HUDs, text, 2D sprites) are never
filtered." with "Two settings carry it: `TextureFilterSetting` for 3D
primitives and `SpriteFilterSetting` for sprites, the split
`Rasterizer.metal`'s `ps1_is_sprite` decides." Then append:

```swift
/// The persisted SPRITE texture filter: what textured rectangles and
/// screen-aligned 2D polygons use. Same shape as `TextureFilterSetting`.
struct SpriteFilterSetting {
    static let defaultsKey = "spriteTextureFilter"
    /// Off, as DuckStation ships it.
    static let defaultFilter = TextureFilter.nearest

    private var choice: PersistedChoice<TextureFilter>
    var filter: TextureFilter { choice.value }

    init(key: String = SpriteFilterSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultFilter)
    }

    mutating func set(_ value: TextureFilter) { choice.set(value) }
}
```

- [ ] **Step 5: Carry it into the uniform**

`MetalRasterizer.swift`, change the `textureFilter` doc comment's first line to
"How 3D textured primitives sample, for the sidecar only: see `TextureFilter`."
and add after the property:

```swift

    /// How sprites sample: textured rectangles and screen-aligned 2D polygons.
    /// A uniform for `textureFilter`'s reason.
    var spriteFilter = SpriteFilterSetting.defaultFilter
```

and at the uniform construction:

```swift
            var uni = Ps1RasterUniforms(scale: UInt32(vram.scale),
                                        dither_mode: ditherMode.uniformValue,
                                        texture_filter: textureFilter.uniformValue,
                                        sprite_filter: spriteFilter.uniformValue)
```

`MetalMoverTests.swift:154`:

```swift
    var uni = Ps1RasterUniforms(scale: 1, dither_mode: UInt32(PS1_DITHER_OFF),
                                texture_filter: UInt32(PS1_FILTER_NEAREST),
                                sprite_filter: UInt32(PS1_FILTER_NEAREST))
```

`MetalFixtureHarness.replay`: add `spriteFilter: TextureFilter = .nearest`
after `filter`, change the doc comment's "`dither` and `filter` are PINNED
here" to "`dither`, `filter` and `spriteFilter` are PINNED here", and set
`renderer.spriteFilter = spriteFilter` beside `renderer.textureFilter = filter`.

- [ ] **Step 6: Run the tests to verify they pass**

Run the five tests from Step 2 plus `textureFilterRawValuesMatchTheShaderHeader`.
Expected: all PASS, `Test run with 6 tests`.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Shaders/PrimInstance.h ps1-macos/Shaders/Rasterizer.metal \
  ps1-macos/Sources/PS1/TextureFilter.swift ps1-macos/Sources/PS1/MetalRasterizer.swift \
  ps1-macos/Tests/PS1Tests/MetalMoverTests.swift ps1-macos/Tests/PS1Tests/MetalScaleTests.swift \
  ps1-macos/Tests/PS1Tests/MetalFixtureHarness.swift ps1-macos/Tests/PS1Tests/TextureFilterSettingTests.swift
git commit -m "feat(macos): sprite texture filter setting and uniform"
```

---

### Task 2: Classify textured triangles

The shader decides sprite or 3D per primitive and picks the setting. No
rectangle is filtered yet. Every existing filter test draws a SCREEN-ALIGNED
right triangle, which is now a sprite, so the test harness's sprite filter
follows its texture filter unless a test sets it: that keeps every existing
test's meaning intact.

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (add `ps1_is_sprite` and `ps1_filter_for` after `ps1_uv_limit`; the textured-triangle branch's filter condition)
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift:35-48` (`frame`)
- Modify: `ps1-macos/Tests/PS1Tests/TextureFilterTests.swift` (the corpus gate; new tests and one helper)

**Interfaces:**
- Consumes: `uni.sprite_filter`, `MetalRasterizer.spriteFilter` (Task 1).
- Produces: Metal `inline bool ps1_is_sprite(const device Ps1PrimInstance& p)` and `inline uint ps1_filter_for(const device Ps1PrimInstance& p, constant Ps1RasterUniforms& uni)`; `MetalScaleHarness.frame(scale:payload:preload:dither:filter:spriteFilter:wantSidecar:_:)` with `spriteFilter: TextureFilter? = nil` meaning "the same as `filter`".

- [ ] **Step 1: The harness's sprite filter**

In `MetalScaleHarness.frame`, add the parameter after `filter` and assign it
beside `r.textureFilter = filter`:

```swift
    static func frame(scale: Int, payload: [UInt32] = [], preload: [UInt16]? = nil,
                      dither: DitherMode = .off, filter: TextureFilter = .nearest,
                      spriteFilter: TextureFilter? = nil,
                      wantSidecar: Bool = false,
                      _ body: (MetalRasterizer) -> Void) throws -> Frame? {
```

```swift
        r.textureFilter = filter
        // nil: the sprite setting follows `filter`, so a test that draws a
        // screen-aligned triangle (a sprite) keeps meaning what it meant
        // before the sprite/3D split existed.
        r.spriteFilter = spriteFilter ?? filter
```

- [ ] **Step 2: Write the failing tests**

In `TextureFilterTests.swift`, add this helper after `texturedTriangle`:

```swift
/// A triangle with explicit vertices and texcoords, for mappings
/// `texturedTriangle` cannot express (turned on its side, mirrored).
private func mappedTriangle(_ xy: [(Int16, Int16)], _ uv: [(UInt8, UInt8)],
                            rw: (Int32, Int32, Int32) = (0, 0, 0))
    -> (MetalRasterizer) -> Void {
    return { r in
        drawingArea(r)
        var tri = Ps1GpuCommand()
        tri.kind = UInt8(PS1_GPU_DRAW_TEXTURED_TRIANGLE.rawValue)
        tri.opcode = 0x25
        tri.tpage = page16
        tri.v.0 = Ps1GpuVertex(x: xy[0].0, y: xy[0].1, u: uv[0].0, v: uv[0].1, _pad: 0, color: 0)
        tri.v.1 = Ps1GpuVertex(x: xy[1].0, y: xy[1].1, u: uv[1].0, v: uv[1].1, _pad: 0, color: 0)
        tri.v.2 = Ps1GpuVertex(x: xy[2].0, y: xy[2].1, u: uv[2].0, v: uv[2].1, _pad: 0, color: 0)
        tri.v.0.rw = rw.0; tri.v.1.rw = rw.1; tri.v.2.rw = rw.2
        r.apply(tri)
    }
}

/// The distinct present sidecar reds of `draw` under one pair of settings.
private func distinctReds(_ draw: @escaping (MetalRasterizer) -> Void, vram: [UInt16],
                          texture: TextureFilter, sprite: TextureFilter) throws -> Int? {
    guard let f = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                              filter: texture, spriteFilter: sprite,
                                              wantSidecar: true, draw) else { return nil }
    return Set(sidecarReds(f)).count
}
```

Replace `theCorpusRendersIdenticalVramUnderBothFilters` with:

```swift
@Test func theCorpusRendersIdenticalVramUnderEverySetting() throws {
    // THE gate. Every fixture that exists, every frame, two dither modes (a
    // dithering one, since the VRAM path there carries the offset) and two
    // scales (3 because `/ s` is a shift at every power of two), and every
    // combination of the two settings against Nearest/Nearest.
    // `tr1-usa-v1-1-pgxp` is the one that carries perspective texcoords.
    let corpus = ["synthetic-primitives", "synthetic-movers", "silent-hill-usa", "tr1-usa-v1-1",
                  "tr1-usa-v1-1-pgxp"]
    let settings: [(TextureFilter, TextureFilter)] =
        [(.nearest, .nearest), (.bilinear, .nearest), (.nearest, .bilinear), (.bilinear, .bilinear)]
    for name in corpus where generatedFixtureExists(name) {
        for dither in [DitherMode.native, .trueColor] {
            for scale in [1, 3] {
                guard let device = MTLCreateSystemDefaultDevice(),
                      let queue = device.makeCommandQueue() else { return }
                var vrams: [MetalVram] = []
                var rasterizers: [MetalRasterizer] = []
                for (texture, sprite) in settings {
                    guard let vram = MetalVram(device: device, queue: queue, scale: scale) else { return }
                    let r = try MetalRasterizer(vram: vram)
                    r.ditherMode = dither
                    r.textureFilter = texture
                    r.spriteFilter = sprite
                    vrams.append(vram)
                    rasterizers.append(r)
                }
                let file = try FixtureFile(contentsOf: FixtureFile.url(named: name))
                withExtendedLifetime(file) {
                    for i in 0..<file.frames.count {
                        for r in rasterizers {
                            r.beginFrame(payload: file.payload(for: i))
                            for cmd in file.records(for: i) { r.apply(cmd) }
                            r.endFrame()
                        }
                        let reference = vrams[0].readback()
                        for (k, vram) in vrams.enumerated().dropFirst() {
                            #expect(vram.readback() == reference,
                                    Comment(rawValue: "\(name) \(dither) @\(scale)x frame \(i) "
                                            + "\(settings[k]): VRAM moved"))
                        }
                    }
                }
            }
        }
    }
}
```

Append a new section:

```swift
// MARK: - Which setting applies

@Test func aScreenAlignedTriangleFollowsTheSpriteSetting() throws {
    // `texturedTriangle` maps u along x and v along y: a 2D quad's half.
    let draw = texturedTriangle(u0: 0, u1: 2)
    let vram = vramWithRows(edgeRow)
    guard let spriteOff = try distinctReds(draw, vram: vram, texture: .bilinear, sprite: .nearest),
          let spriteOn = try distinctReds(draw, vram: vram, texture: .nearest, sprite: .bilinear)
    else { return }
    #expect(spriteOff == 2, "Texture Filtering alone filtered a sprite: \(spriteOff) reds")
    #expect(spriteOn > 16, "Sprite Texture Filtering did not reach a sprite: \(spriteOn) reds")
}

@Test func aTextureTurnedOnItsSideFollowsTheTextureSetting() throws {
    // u runs DOWN the screen and v across it: du/dy != 0, so not a sprite.
    let draw = mappedTriangle([(300, 300), (428, 300), (300, 428)], [(0, 0), (0, 2), (2, 0)])
    let vram = vramWithRows(edgeRow)
    guard let textureOn = try distinctReds(draw, vram: vram, texture: .bilinear, sprite: .nearest),
          let spriteOn = try distinctReds(draw, vram: vram, texture: .nearest, sprite: .bilinear)
    else { return }
    #expect(textureOn > 16, "Texture Filtering did not reach a 3D mapping: \(textureOn) reds")
    #expect(spriteOn == 2, "Sprite Texture Filtering filtered a 3D mapping: \(spriteOn) reds")
}

@Test func aTriangleWithDepthFollowsTheTextureSettingEvenWhenScreenAligned() throws {
    // Review Focus 1. Screen-aligned, but PGXP gave all three vertices a
    // depth: DuckStation's "is_3d" wins over the derivative test. No
    // perspective flag, so the texcoords stay affine and only the class moves.
    let draw = texturedTriangle(u0: 0, u1: 2, rw: (65536, 65536, 65536))
    let vram = vramWithRows(edgeRow)
    guard let textureOn = try distinctReds(draw, vram: vram, texture: .bilinear, sprite: .nearest),
          let spriteOn = try distinctReds(draw, vram: vram, texture: .nearest, sprite: .bilinear)
    else { return }
    #expect(textureOn > 16, "a depth-carrying triangle ignored Texture Filtering")
    #expect(spriteOn == 2, "a depth-carrying triangle was treated as a sprite")
}

@Test func aMirroredScreenAlignedTriangleIsStillASprite() throws {
    // Review Focus 2. u runs right-to-left (du/dx < 0), as a sprite drawn
    // facing the other way: still du/dy == 0 and dv/dx == 0.
    let draw = mappedTriangle([(300, 300), (428, 300), (300, 428)], [(2, 0), (0, 0), (2, 2)])
    let vram = vramWithRows(edgeRow)
    guard let spriteOff = try distinctReds(draw, vram: vram, texture: .bilinear, sprite: .nearest),
          let spriteOn = try distinctReds(draw, vram: vram, texture: .nearest, sprite: .bilinear)
    else { return }
    #expect(spriteOff == 2, "a mirrored 2D triangle followed Texture Filtering")
    #expect(spriteOn > 16, "a mirrored 2D triangle ignored Sprite Texture Filtering")
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run the five tests above (`theCorpusRendersIdenticalVramUnderEverySetting`,
`aScreenAlignedTriangleFollowsTheSpriteSetting`,
`aTextureTurnedOnItsSideFollowsTheTextureSetting`,
`aTriangleWithDepthFollowsTheTextureSettingEvenWhenScreenAligned`,
`aMirroredScreenAlignedTriangleIsStillASprite`).
Expected: the corpus gate and `aTextureTurnedOnItsSideFollowsTheTextureSetting`
and `aTriangleWithDepthFollowsTheTextureSettingEvenWhenScreenAligned` PASS (the
shader still reads `texture_filter` for every triangle);
`aScreenAlignedTriangleFollowsTheSpriteSetting` and
`aMirroredScreenAlignedTriangleIsStillASprite` FAIL on both counts.

- [ ] **Step 4: `ps1_is_sprite` and `ps1_filter_for`**

In `Rasterizer.metal`, insert after `ps1_uv_limit`:

```metal
/// Whether a textured primitive is a SPRITE, which decides only WHICH
/// texture-filter setting it follows: DuckStation's split, made from this
/// primitive's own fields.
///
/// A textured rectangle always is. A triangle with a depth on all three
/// vertices never is (DuckStation's PGXP rule: a depth means 3D). Any other
/// triangle is a sprite iff its texture is SCREEN-ALIGNED, u constant down
/// the screen and v constant across it; with deltas from vertex 0 those are
/// the exact integer tests
///   du/dy == 0  <=>  du1 * dx2 == du2 * dx1
///   dv/dx == 0  <=>  dv1 * dy2 == dv2 * dy1
/// which scaled and mirrored 2D quads pass and rotated ones fail. A triangle
/// with no screen area or no texture area has no derivatives and stays 3D.
inline bool ps1_is_sprite(const device Ps1PrimInstance& p) {
    if (p.kind == PS1_PRIM_TEXTURED_RECT) return true;
    if (p.rw0 != 0 && p.rw1 != 0 && p.rw2 != 0) return false;
    int dx1 = p.x1 - p.x0, dy1 = p.y1 - p.y0, dx2 = p.x2 - p.x0, dy2 = p.y2 - p.y0;
    int du1 = p.u1 - p.u0, dv1 = p.v1 - p.v0, du2 = p.u2 - p.u0, dv2 = p.v2 - p.v0;
    if (dx1 * dy2 == dx2 * dy1 || du1 * dv2 == du2 * dv1) return false;
    return du1 * dx2 == du2 * dx1 && dv1 * dy2 == dv2 * dy1;
}

/// The PS1_FILTER_* this primitive's sidecar uses.
inline uint ps1_filter_for(const device Ps1PrimInstance& p,
                           constant Ps1RasterUniforms& uni) {
    return ps1_is_sprite(p) ? uni.sprite_filter : uni.texture_filter;
}
```

In the textured-triangle branch of `ps1_prim_fragment`, change
`if (uni.texture_filter == PS1_FILTER_BILINEAR) {` to:

```metal
        if (ps1_filter_for(p, uni) == PS1_FILTER_BILINEAR) {
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the five tests from Step 3 plus every existing `TextureFilterTests` test
(`bilinearAddsLevelsAcrossAMagnifiedEdge`, `bilinearAddsLevelsAtEveryTextureDepth`,
`aUniformTextureFiltersToItselfInEveryMode`, `perspectiveTexcoordsFilterToo`,
`aOneToOneMappingFiltersToTheNearestTexelAtOneX`, `aHoleNeighbourDrawsNoFringe`,
`uvLimitsKeepAtlasNeighboursOut`, `filteredNeighboursWrapInsideTheTextureWindow`,
`theDitheringModesStayFiveBitUnderBilinear`,
`aSemiTransparentFilteredDrawBlendsTheFilteredColourInDitheringModes`,
`texturedRectanglesAreNeverFiltered`).
Expected: all PASS, `Test run with 16 tests`.

- [ ] **Step 6: Full suite**

```bash
pkill -x Substation; zig build metallib && zig build capi-lib && ps1-macos/test.sh 2>&1 | tail -15
```

Expected: every test passes.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Shaders/Rasterizer.metal ps1-macos/Tests/PS1Tests/MetalScaleHarness.swift \
  ps1-macos/Tests/PS1Tests/TextureFilterTests.swift
git commit -m "feat(metal): textured triangles follow the sprite or texture filter"
```

---

### Task 3: Filter textured rectangles

**Files:**
- Modify: `ps1-macos/Shaders/Rasterizer.metal` (`ps1_bilinear` takes its limits; add `ps1_wrap_limit`; the textured-triangle call site; the textured-rectangle branch)
- Modify: `ps1-macos/Tests/PS1Tests/TextureFilterTests.swift` (replace `texturedRectanglesAreNeverFiltered`; new sprite tests and one helper)

**Interfaces:**
- Consumes: `ps1_filter_for`, `ps1_is_sprite` (Task 2); `ps1_uv_limit`, `ps1_centre_uv6`, `ps1_filtered`, `ps1_window_fetch`, `ps1_texel8` (existing); `MetalScaleHarness.frame(..., spriteFilter:)` (Task 2).
- Produces: `inline int3 ps1_bilinear(const device Ps1PrimInstance& p, texture2d<ushort, access::read> vram, uint s, int u6, int v6, int2 ul, int2 vl, uint u, uint v)`; `inline int2 ps1_wrap_limit(int a0, int extent, int nearest)`.

- [ ] **Step 1: Write the failing tests**

In `TextureFilterTests.swift`, add this helper after `mappedTriangle`:

```swift
/// A textured rectangle at (300, 300), `w` x `h` px, texcoord origin (u0, v0).
private func texturedRectangle(opcode: UInt8 = 0x65, tpage: UInt16 = page16,
                               u0: UInt8 = 0, v0: UInt8 = 0, w: UInt16 = 4, h: UInt16 = 4,
                               color: UInt32 = 0, transparent: UInt8 = 0)
    -> (MetalRasterizer) -> Void {
    return { r in
        drawingArea(r)
        var spr = Ps1GpuCommand()
        spr.kind = UInt8(PS1_GPU_DRAW_TEXTURED_RECTANGLE.rawValue)
        spr.opcode = opcode
        spr.tpage = tpage
        spr.value = color
        spr.transparent = transparent
        spr.x = 300; spr.y = 300; spr.w = w; spr.h = h
        spr.v.0 = Ps1GpuVertex(x: 0, y: 0, u: u0, v: v0, _pad: 0, color: 0)
        r.apply(spr)
    }
}
```

If `spr.w`/`spr.h`/`spr.value` are not `UInt16`/`UInt32` in `Ps1GpuCommand`
(`ps1-capi/include/ps1.h`), use their declared types; the values are what
matter.

Replace `texturedRectanglesAreNeverFiltered` with:

```swift
@Test func texturedRectanglesFollowTheSpriteSetting() throws {
    let vram = vramWithRows(edgeRow)
    let draw = texturedRectangle()
    guard let near = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let textureOnly = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                        filter: .bilinear, spriteFilter: .nearest,
                                                        wantSidecar: true, draw),
          let spriteOn = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                     filter: .nearest, spriteFilter: .bilinear,
                                                     wantSidecar: true, draw)
    else { return }
    #expect(sidecarReds(near, size: 4).count > 100, "the sprite drew nothing")
    #expect(near.sidecar == textureOnly.sidecar, "Texture Filtering reached a rectangle")
    #expect(Set(sidecarReds(spriteOn, size: 4)).count > 2,
            "Sprite Texture Filtering did not reach a rectangle")
    #expect(near.scaled == spriteOn.scaled, "VRAM moved")
}
```

Append:

```swift
// MARK: - Sprites

@Test func aRectangleAtOneXFiltersToItself() throws {
    // One texel per native pixel: at 1x every subtexel centre IS a texel
    // centre, so Bilinear reproduces Nearest exactly.
    let vram = vramWithRows(edgeRow)
    let draw = texturedRectangle()
    guard let near = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                 filter: .nearest, wantSidecar: true, draw),
          let bil = try MetalScaleHarness.frame(scale: 1, preload: vram, dither: .trueColor,
                                                filter: .nearest, spriteFilter: .bilinear,
                                                wantSidecar: true, draw)
    else { return }
    #expect(sidecarReds(near, size: 4).count == 16, "the sprite drew nothing")
    #expect(near.sidecar == bil.sidecar)
}

@Test func aUniformSpriteFiltersToItselfInEveryMode() throws {
    // Modulated (opcode 0x64) by a five-bit colour, as every sprite is.
    let vram = vramWithRows([UInt16](repeating: 0x2D6B, count: 4))
    let draw = texturedRectangle(opcode: 0x64, color: 0x0000_4210)
    for dither in DitherMode.allCases {
        guard let near = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: dither,
                                                     filter: .nearest, wantSidecar: true, draw),
              let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: dither,
                                                    filter: .nearest, spriteFilter: .bilinear,
                                                    wantSidecar: true, draw)
        else { return }
        #expect(sidecarReds(near, size: 4).count > 100, "\(dither): the sprite drew nothing")
        #expect(near.sidecar == bil.sidecar, "\(dither): a uniform sprite filtered to something else")
    }
}

@Test func aRectangleNeverFiltersPastItsWrapSegment() throws {
    // Review Focus 3. u0 = 250, 12 wide: unwrapped texels 250..261, i.e.
    // 250..255 then 0..5 after the wrap. Blue there; RED at 249 (below the
    // first segment) and 6 (past the last column), and in row 4 (past the
    // last row of a 4-tall sprite).
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<8 {
        for u in 0..<256 {
            let inside = (u >= 250 || u <= 5) && y < 4
            vram[y * w + pageX + u] = inside ? 0x7C00 : 0x001F
        }
    }
    let draw = texturedRectangle(u0: 250, w: 12)
    for scale in [4, 8] {
        guard let bil = try MetalScaleHarness.frame(scale: scale, preload: vram, dither: .trueColor,
                                                    filter: .nearest, spriteFilter: .bilinear,
                                                    wantSidecar: true, draw)
        else { return }
        let reds = sidecarReds(bil, size: 12)
        #expect(reds.count > 100, "@\(scale)x: the sprite drew nothing")
        #expect(reds.allSatisfy { $0 == 0 }, "@\(scale)x: a texel outside the sprite bled in")
    }
}

@Test func aSpriteHoleDrawsNoFringe() throws {
    // texel 1 is a HOLE between two bright texels; at 4x every filtered
    // subtexel beside it must stay at full red.
    let vram = vramWithRows([0x001F, 0x0000, 0x001F, 0x001F])
    let draw = texturedRectangle()
    guard let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                filter: .nearest, spriteFilter: .bilinear,
                                                wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil, size: 4)
    #expect(reds.count > 100, "the sprite drew nothing")
    #expect(reds.allSatisfy { $0 == 255 }, "a hole was filtered in: min red \(reds.min() ?? 0)")
}

@Test func aSemiTransparentFilteredSpriteBlendsTheFilteredColour() throws {
    // Review Focus 4. Raw, semi-transparent (opcode 0x67), STP-set texels,
    // mode 1 (add) over a dark red fill, in a dithering mode.
    let vram = vramWithRows([0x8001, 0x801F, 0x801F, 0x801F])
    let draw: (MetalRasterizer) -> Void = { r in
        drawingArea(r)
        var fill = Ps1GpuCommand()
        fill.kind = UInt8(PS1_GPU_FILL_RECT.rawValue)
        fill.value = 0x0008                // dark red background, 15-bit
        fill.x = 288; fill.y = 288; fill.w = 32; fill.h = 32
        r.apply(fill)
        var latch = Ps1GpuCommand()
        latch.kind = UInt8(PS1_GPU_LATCH_TEXPAGE.rawValue)
        latch.tpage = page16 | (1 << 5)
        r.apply(latch)
        texturedRectangle(opcode: 0x67, tpage: page16 | (1 << 5), transparent: 1)(r)
    }
    for dither in [DitherMode.off, .trueColor] {
        guard let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: dither,
                                                    filter: .nearest, spriteFilter: .bilinear,
                                                    wantSidecar: true, draw)
        else { return }
        #expect(Set(sidecarReds(bil, size: 4)).count > 2,
                "\(dither): the blend used the nearest texel")
    }
}

@Test func aWindowedSpriteFiltersInsideItsWindow() throws {
    // Review Focus 5. GP0(E2) mask 0x1F on both axes: every coordinate wraps
    // into 0..7. Blue inside that window, red outside it, and a 20 x 20
    // sprite tiles the window more than twice.
    var vram = [UInt16](repeating: 0, count: MetalVram.nativePixelCount)
    for y in 0..<24 {
        for u in 0..<24 { vram[y * w + pageX + u] = (u < 8 && y < 8) ? 0x7C00 : 0x001F }
    }
    let draw: (MetalRasterizer) -> Void = { r in
        var win = Ps1GpuCommand()
        win.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        win.opcode = 0xE2
        win.value = 0x1F | (0x1F << 5)
        r.apply(win)
        texturedRectangle(w: 20, h: 20)(r)
    }
    guard let bil = try MetalScaleHarness.frame(scale: 4, preload: vram, dither: .trueColor,
                                                filter: .nearest, spriteFilter: .bilinear,
                                                wantSidecar: true, draw)
    else { return }
    let reds = sidecarReds(bil, size: 20)
    #expect(reds.count > 1000, "the sprite drew nothing")
    #expect(reds.allSatisfy { $0 == 0 }, "a texel outside the window bled in")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run `texturedRectanglesFollowTheSpriteSetting`, `aRectangleAtOneXFiltersToItself`,
`aUniformSpriteFiltersToItselfInEveryMode`, `aRectangleNeverFiltersPastItsWrapSegment`,
`aSpriteHoleDrawsNoFringe`, `aSemiTransparentFilteredSpriteBlendsTheFilteredColour`,
`aWindowedSpriteFiltersInsideItsWindow`.
Expected: `texturedRectanglesFollowTheSpriteSetting` and
`aSemiTransparentFilteredSpriteBlendsTheFilteredColour` FAIL on their level
counts (no rectangle is filtered yet); the other five PASS, being negative
assertions that hold trivially while nothing filters.

- [ ] **Step 3: `ps1_bilinear` takes its limits**

Change its signature and first two lines, and wrap each clamped sample:

```metal
inline int3 ps1_bilinear(const device Ps1PrimInstance& p,
                         texture2d<ushort, access::read> vram, uint s,
                         int u6, int v6, int2 ul, int2 vl, uint u, uint v) {
    int bu = ps1_floor_div(u6 - 32, 64), bv = ps1_floor_div(v6 - 32, 64);
```

```metal
            ushort t = ps1_window_fetch(p, vram, s,
                                        uint(clamp(bu + i, ul.x, ul.y)) & 0xFFu,
                                        uint(clamp(bv + j, vl.x, vl.y)) & 0xFFu);
```

In its doc comment, replace the UV LIMITS bullet with:

```
/// - UV LIMITS: each sample is clamped to `ul`/`vl` (UNWRAPPED texels) and
///   then wrapped `& 0xFF` before the window, or an atlas cell or a sprite's
///   neighbour bleeds in. A triangle passes `ps1_uv_limit`, whose limits lie
///   in 0..255 so the wrap is a no-op; a rectangle passes `ps1_wrap_limit`.
```

In the textured-triangle branch, the call becomes:

```metal
            side5 = ps1_filtered(ps1_bilinear(p, vram, uint(s), c6.x, c6.y,
                                              ps1_uv_limit(p.u0, p.u1, p.u2, u),
                                              ps1_uv_limit(p.v0, p.v1, p.v2, v), u, v),
```

(the rest of that `ps1_filtered` call unchanged).

- [ ] **Step 4: `ps1_wrap_limit`**

Insert after `ps1_uv_limit`:

```metal
/// One axis of a textured RECTANGLE's limits, in UNWRAPPED texels.
///
/// A rectangle's texcoord wraps at 256, so a wide one repeats the page, and
/// DuckStation splits it into quads limited to their own texel range each.
/// This is the same limit without the split: the 256-texel segment holding
/// the nearest texel, cut to the sprite's own span [a0, a0 + extent - 1].
/// The high limit is the last column itself (a rectangle draws it), not the
/// triangle path's `max - 1`. The nearest texel always lies inside.
inline int2 ps1_wrap_limit(int a0, int extent, int nearest) {
    int seg = nearest & ~0xFF;
    return int2(max(a0, seg), min(a0 + extent - 1, seg + 0xFF));
}
```

- [ ] **Step 5: Filter the rectangle branch**

In the textured-rectangle branch of `ps1_prim_fragment`, after
`transparent = transparent && (src & 0x8000) != 0;` add:

```metal
        // The sprite filter, SIDECAR only, like the triangle's: `src`, the hole
        // and the STP bit above came from the nearest texel. The fractional
        // texcoord is taken at the subtexel CENTRE in the triangle's six-bit
        // units, unwrapped, so at 1x it lands on the texel centre and filters
        // to the nearest texel exactly.
        if (ps1_filter_for(p, uni) == PS1_FILTER_BILINEAR) {
            int nu = (nx - p.x0) + p.u0, nv = (ny - p.y0) + p.v0;
            int u6 = ((2 * px + 1) * 64) / (2 * s) - 64 * p.x0 + 64 * p.u0;
            int v6 = ((2 * py + 1) * 64) / (2 * s) - 64 * p.y0 + 64 * p.v0;
            side5 = ps1_filtered(ps1_bilinear(p, vram, uint(s), u6, v6,
                                              ps1_wrap_limit(p.u0, p.w, nu),
                                              ps1_wrap_limit(p.v0, p.h, nv), u, v),
                                 (p.flags & PS1_PRIM_MODULATE) != 0, ushort(p.color),
                                 shade8, dither_o, true_colour, src & 0x8000, src8);
            filtered = true;
        }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the seven tests from Step 2 and every other `TextureFilterTests` test.
Expected: all PASS, `Test run with 22 tests`.

- [ ] **Step 7: Full suite**

```bash
pkill -x Substation; zig build metallib && zig build capi-lib && ps1-macos/test.sh 2>&1 | tail -15
```

Expected: every test passes.

- [ ] **Step 8: Commit**

```bash
git add ps1-macos/Shaders/Rasterizer.metal ps1-macos/Tests/PS1Tests/TextureFilterTests.swift
git commit -m "feat(metal): bilinear sprite filtering with wrap-segment limits"
```

---

### Task 4: The setting in the app

**Files:**
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift` (after `textureFilter`, ~line 194)
- Modify: `ps1-macos/Sources/PS1/LiveRenderer.swift` (after `textureFilter`, ~line 49)
- Modify: `ps1-macos/Sources/PS1/MetalDisplayView.swift` (~lines 64-68, 88, 118, 162)
- Modify: `ps1-macos/Sources/PS1/ContentView.swift:29-31`
- Modify: `ps1-macos/Sources/PS1/Settings/SettingsCopy.swift` (~lines 107-111, 252)
- Modify: `ps1-macos/Sources/PS1/Settings/VideoSettingsPane.swift` (~lines 33-43)
- Modify: `ps1-macos/Sources/PS1App/VideoCommands.swift` (~lines 46-51)
- Modify: `ps1-macos/Tests/PS1Tests/TextureFilterSettingTests.swift`

**Interfaces:**
- Consumes: `SpriteFilterSetting`, `MetalRasterizer.spriteFilter` (Task 1).
- Produces: `EmulatorViewModel.spriteFilter: TextureFilter`; `LiveRenderer.spriteFilter`; `MetalDisplayView.spriteFilter`; `MetalDisplayView.Coordinator.init(runner:scale:ditherMode:textureFilter:spriteFilter:depthBuffer:)` with `spriteFilter` defaulting to `SpriteFilterSetting.defaultFilter`; `SettingsCopy.spriteTextureFiltering`.

- [ ] **Step 1: Write the failing test**

Append to `TextureFilterSettingTests.swift`:

```swift
@Test func theSpriteFilterReachesTheRasterizerWithoutARebuild() throws {
    // A runtime uniform, like the texture filter: the coordinator a running
    // game draws with is built once, and its renderer must carry the setting
    // it was built with and take a new one in place.
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let runner = EmulatorRunner()
    let coordinator = MetalDisplayView.Coordinator(runner: runner, scale: 1, ditherMode: .native,
                                                   spriteFilter: .bilinear)
    #expect(coordinator.live.spriteFilter == .bilinear)
    coordinator.live.spriteFilter = .nearest
    #expect(coordinator.live.spriteFilter == .nearest)
}
```

Before writing it, read `LiveRendererScaleTests.swift:80-125` and build the
`EmulatorRunner` exactly the way those tests do (they already construct
`MetalDisplayView.Coordinator`); replace `EmulatorRunner()` above with that
construction if it differs.

- [ ] **Step 2: Run it to verify it fails**

Expected: build error, `extra argument 'spriteFilter' in call`.

- [ ] **Step 3: Plumb it**

`LiveRenderer.swift`, after the `textureFilter` property:

```swift

    /// How sprites sample, for the sidecar: see `TextureFilter`. A runtime
    /// uniform, assigned by `MetalDisplayView.updateNSView`.
    var spriteFilter: TextureFilter {
        get { rasterizer.spriteFilter }
        set { rasterizer.spriteFilter = newValue }
    }
```

`EmulatorViewModel.swift`, after the `textureFilter` property:

```swift

    /// The sprite texture filter, persisted: a runtime uniform like
    /// `textureFilter`, so no `.id()` rebuild.
    private var spriteFilterSetting = SpriteFilterSetting()

    public var spriteFilter: TextureFilter {
        get { spriteFilterSetting.filter }
        set { spriteFilterSetting.set(newValue) }
    }
```

`MetalDisplayView.swift`:
- after `let textureFilter: TextureFilter` add
  ```swift
      /// How sprites sample. Like `ditherMode`, NOT part of the `.id()`.
      let spriteFilter: TextureFilter
  ```
- `makeCoordinator` passes `spriteFilter: spriteFilter` after `textureFilter: textureFilter`;
- `updateNSView` adds `context.coordinator.live.spriteFilter = spriteFilter`;
- `Coordinator.init` gains `spriteFilter: TextureFilter = SpriteFilterSetting.defaultFilter,`
  after the `textureFilter` parameter, and `live.spriteFilter = spriteFilter`
  after `live.textureFilter = textureFilter`.

`ContentView.swift`:

```swift
                    MetalDisplayView(runner: runner, scale: model.internalScale,
                                     depthBuffer: depthBuffer, ditherMode: model.ditherMode,
                                     textureFilter: model.textureFilter,
                                     spriteFilter: model.spriteFilter)
```

- [ ] **Step 4: Copy, the Settings picker and the menu**

`SettingsCopy.swift`: replace `textureFiltering`'s `details` with

```swift
        details: "Nearest-Neighbour shows each texture pixel as a sharp square, as the console did. Bilinear blends neighbouring texture pixels into a smooth surface. It applies to 3D surfaces only: 2D sprites, menus and text follow Sprite Texture Filtering, and the cut-out edges of things like foliage and fences stay sharp. It changes only the picture you see, never what the game itself reads back."
```

and add after it:

```swift

    static let spriteTextureFiltering = SettingInfo(
        title: "Sprite Texture Filtering",
        summary: "Smooths 2D graphics: sprites, menus, text and anything else the game draws flat on the screen.",
        details: "Nearest-Neighbour keeps 2D graphics as sharp squares, as the console drew them. Bilinear blends neighbouring texture pixels, which softens 2D characters, backgrounds, menus and text. 3D surfaces follow Texture Filtering instead, and cut-out edges stay sharp in both. It changes only the picture you see, never what the game itself reads back."
    )
```

and add `spriteTextureFiltering` after `textureFiltering` in `allInfo`.

`VideoSettingsPane.swift`: inside the Texture Filtering `Section`, after its
`SettingRow`, add a second row, and update the type comment to "Internal
resolution, dithering and the two texture filters, the Video menu preferences.":

```swift
                SettingRow(SettingsCopy.spriteTextureFiltering) {
                    Picker(SettingsCopy.spriteTextureFiltering.title, selection: $model.spriteFilter) {
                        ForEach(TextureFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
```

`VideoCommands.swift`, after the Texture Filtering `Picker`:

```swift

            Picker("Sprite Texture Filtering", selection: $model.spriteFilter) {
                ForEach(TextureFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run `theSpriteFilterReachesTheRasterizerWithoutARebuild()` and the
`SettingsCopyTests` suite (`-only-testing:PS1Tests/SettingsCopyTests`).
Expected: all PASS. If `everySentenceIsFinished` or `noLongDashes` fail, fix
the copy, not the test.

- [ ] **Step 6: Build the app**

```bash
pkill -x Substation; zig build macos
```

Expected: `zig-out/Substation.app` builds. The visual check (Settings ▸ Video
showing Sprite Texture Filtering under Texture Filtering, the Video menu's new
picker, a 2D game sharpening and softening as the sprite setting toggles while
3D does not) is for the user.

- [ ] **Step 7: Full suite and commit**

```bash
pkill -x Substation; ps1-macos/test.sh 2>&1 | tail -15
git add ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Sources/PS1/LiveRenderer.swift \
  ps1-macos/Sources/PS1/MetalDisplayView.swift ps1-macos/Sources/PS1/ContentView.swift \
  ps1-macos/Sources/PS1/Settings/SettingsCopy.swift ps1-macos/Sources/PS1/Settings/VideoSettingsPane.swift \
  ps1-macos/Sources/PS1App/VideoCommands.swift ps1-macos/Tests/PS1Tests/TextureFilterSettingTests.swift
git commit -m "feat(macos): sprite texture filtering in Settings and the Video menu"
```

---

### Task 5: Cost and documentation

**Files:**
- Modify: `ps1-macos/Tests/PS1Tests/MetalScaleTests.swift` (`measuresReplayCostAtEachScale`, `replayForTiming`, ~lines 868-910)
- Modify: `.claude/skills/ps1-gpu-metal/SKILL.md` (new section after `## Texture filtering (2026-10-02)`)
- Modify: `CLAUDE.md` (the texture-filtering rule under **GPU + Metal**, ~line 248)

- [ ] **Step 1: Gate 4 measures three settings**

Give `replayForTiming` a `spriteFilter: TextureFilter` parameter after
`filter`, assigned to `r.spriteFilter`. Replace the inner filter loop of
`measuresReplayCostAtEachScale` with:

```swift
            let settings: [(TextureFilter, TextureFilter)] =
                [(.nearest, .nearest), (.bilinear, .nearest), (.bilinear, .bilinear)]
            for (filter, sprite) in settings {
                let t0 = DispatchTime.now().uptimeNanoseconds
                guard let frames = try replayForTiming(name, scale: scale, filter: filter,
                                                       spriteFilter: sprite) else { continue }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                let label = name.padding(toLength: 30, withPad: " ", startingAt: 0)
                print("[gate-4] \(label) @\(scale)x \(filter)/\(sprite)  "
                      + String(format: "%8.1f ms", ms) + "  (\(frames) frames)")
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

Run it twice and keep both. Record `silent-hill-usa` and `tr1-usa-v1-1` at 4x
and 8x for all three settings, as ms/frame. Then confirm
`measuresReplayCostAtEachScale` still passes (skipped) without the marker file.

- [ ] **Step 3: Document**

Add `## Sprite texture filtering (2026-10-03)` to the `ps1-gpu-metal` skill,
directly after the `## Texture filtering (2026-10-02)` section, in this
codebase's voice (rule, then reason; declarative; no hedging prose), covering:
- the two settings and that the class chooses only which applies, so the
  sidecar-only argument and `theCorpusRendersIdenticalVramUnderEverySetting`
  carry over unchanged;
- `ps1_is_sprite`'s rule: rectangle always; depth on all three means 3D;
  otherwise the two integer derivative tests; degenerate means 3D; that it is
  DuckStation's `zero_dudy && zero_dvdx` with its PGXP `is_3d` override;
- the one difference from DuckStation (PGXP-resolved without a depth is judged
  by the derivative test) and why it is rare here;
- that the existing triangle tests draw screen-aligned triangles, which is why
  `MetalScaleHarness.frame`'s `spriteFilter` defaults to `filter`;
- the rectangle's centre sample (Nearest-exact at 1x) and `ps1_wrap_limit`'s
  segment rule, high limit `a0 + extent - 1` with no `max - 1`;
- the measured cost from Step 2, both runs, as ms/frame.

In `CLAUDE.md`, append to the texture-filtering bullet (after "touches
`color(1)` alone."):

```markdown
  Whether a primitive follows Texture Filtering or Sprite Texture Filtering
  is `ps1_is_sprite`'s decision, made from its own vertices in the shader;
  it chooses only which setting applies.
```

- [ ] **Step 4: Commit**

```bash
git add ps1-macos/Tests/PS1Tests/MetalScaleTests.swift .claude/skills/ps1-gpu-metal/SKILL.md CLAUDE.md
git commit -m "docs: sprite texture filtering cost and rules"
```
