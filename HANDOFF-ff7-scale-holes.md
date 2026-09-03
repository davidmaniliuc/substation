# Handoff — FF7 Cloud is full of holes at 8x

**Status: root-caused and reproduced, NOT fixed. One design decision blocks the fix.**
Opened 2026-09-02. Everything below is evidence, not conjecture; where something is
untested it says so.

Read `CLAUDE.md` § "The FF7 'Cloud is full of holes at 8x' report" first — it carries
the same finding in the permanent reference. This file is the working plan.

---

## 1. The symptom

Player runs the macOS app with `internalResolution = 8`, `pgxpEnabled = 1`
(`defaults read dev.zzssxx.ps1`). Cloud's field model is shot through with holes —
background visible between and inside body parts. At 1x it is solid.

## 2. What it is NOT — each ruled out with a control, do not re-litigate

| Suspect | Ruled out by |
|---|---|
| PGXP | Same window captured `--pgxp-on` and without: **identically shattered at 8x**. |
| The core / software rasterizer | 1x is byte-identical between the two rasterizers (Gate 1), and 1x is solid. |
| `38cceda` (ring: clause judged per subtexel) | Fixed, test passes, wrong class — that was one triangle's centre. |
| `6493756` (mesh: non-owner refused in its neighbour's pixel) | Fixed, test passes, wrong class — that was triangles under 1.5 px². |

**A methodological trap that cost this investigation real time:** the earlier claim that
"the 1x control ruled PGXP out" is *invalid reasoning* that happened to reach the right
answer. PGXP moves a vertex by a **fraction** of a pixel, so at 1x both sides of a crack
round into the same pixel and nothing shows. Only a control **at the scale the artifact
appears at** rules anything out. The same applies to any future scale-dependent report.

## 3. Root cause

`ps1_triangle_coverage` in `ps1-macos/Shaders/Rasterizer.metal` carries the degeneracy
clause — Avocado's *"and not all three zero"*, written as `b_i < PS1_Q_BIAS_SCALE`. It
exists to reproduce hardware's whole-pixel behaviour, and at 1x it is correct and
necessary.

A field character model is made of **sub-pixel facets**. Cloud is ~25 px tall and carries
232 triangles in that box:

```
twice-area:  0 → 24    1 → 88    2 → 43    3 → 13    4 → 13    5 → 33    6 → 14   >6 → 4
67% are under 1.5 native px² — the band the clause governs.
88 are the twice-area-1 "genuine sliver" refused at EVERY scale by design.
```

Over the model's 1x-painted blocks at 8x:

```
  4989  subtexels painted by the shader
   387  unpainted BUT covered by a triangle   <- deleted by the clause. THE HOLES.
   256  unpainted and outside all geometry    <- ordinary silhouette refinement, correct.
```

On the worst pixel (159,110): **all 64 subtexels are covered by some triangle; the shader
paints 36.** The mesh is watertight there. The clause is what opens the holes.

## 4. Why it is a decision and not a fix

`readbackNative()` samples the **top-left subtexel of each block**, which *is* the native
sample point. There, refusing a sliver is exactly what 1x does. So letting slivers paint
at scale puts colour on native lattice points 1x leaves background — breaking **Gate 2**
(downsample-invariance) and **`subPixelSliversAreRefusedAndPaintedIdenticallyAtEveryScale`**
together.

**Strict 1x-parity at top-left subtexels and hole-free upscaling of a sub-pixel mesh are
incompatible.** The code chose parity; the holes are the price. Anything that closes them
weakens that oracle and must be argued for, not slipped in — hence this handoff instead of
a commit.

## 5. Options

### Option 1 — status quo
Keep parity, accept the holes. Legitimate; it is now a documented decision rather than a
mystery. Nothing to do.

### Option 2 — RECOMMENDED, and untested
**The clause governs the native sample point and nothing else.** Off-lattice subtexels are
decided by pure geometric coverage.

Rationale: the clause is a **sampling** artifact — hardware takes one sample per pixel —
not a property of the shape. At 64 samples per pixel, reproducing it is faithful to the
wrong thing. The native sample point is where hardware's decision actually lives; the other
63 subtexels are samples hardware never took, and geometry should decide them.

Why this is stronger than "just drop the clause above 1x": **Gate 2 stays a strict equality
check**, because the top-left subtexel keeps the 1x answer by construction.

Expected side effect, and it must be checked rather than assumed: a block whose *only*
cover is a refused sliver paints 63 of 64 subtexels, leaving the lattice subtexel bare —
sub-visible at 8x (1/64 of a pixel) and correct against 1x at the point Gate 2 samples.

This likely lets the `area < 3 * PS1_Q_BIAS_SCALE` blocky branch from `6493756` be
**deleted**, since neighbours now cover the rest of the block geometrically. Verify against
its two tests before removing it — do not remove it on this paragraph's say-so.

### Option 3 — drop the clause entirely for `s > 1`
Simplest. Gate 2 must be restated one-directionally ("the scaled render must never leave
unpainted what 1x paints; it may paint more"). Weaker oracle than Option 2 for no extra
benefit that has been identified.

## 6. Implementation sketch (Option 2)

One function: `ps1_triangle_coverage`, `ps1-macos/Shaders/Rasterizer.metal`.

- Keep the `(b0 | b1 | b2) < 0` geometric test exactly as is.
- Apply the degeneracy clause **only when this subtexel is the native sample point** —
  `px % s == 0 && py % s == 0`. At `s == 1` that is every fragment, so 1x is untouched and
  Gate 1 cannot move.
- Reconsider the `area < 3 * PS1_Q_BIAS_SCALE` branch (see above).
- `w0/w1/w2` come back unbiased as today; attributes are unaffected.

## 7. Tests — expected movement

| Test | Expectation |
|---|---|
| Gate 1 (`MetalRasterizerTests`, `MetalMoverTests`) | **Must not move.** A 1x freeze. If it moves, the change leaked into `s == 1`. |
| Gate 2 (`MetalScaleHarness.compare`, many callers) | Should stay green under Option 2. Under Option 3 it must be restated first. |
| `subPixelSliversAreRefusedAndPaintedIdenticallyAtEveryScale` | **Will fail as written** and must be rescoped to "refused at every native sample point". Do not simply delete it — its job is real. |
| `aSmallTriangleIsSolidRatherThanHollowAtEveryScale` | Should stay green. |
| `aSubPixelMeshKeepsEveryNativePixelOneXPaints` | Should stay green. |
| New test | Add one that fails against today's shader: a sub-pixel MESH must not leave unpainted a subtexel that a triangle covers. The FF7 fixture is the realistic case; a synthetic pair of twice-area-1/2 facets is the pinnable one. |

Verify each claim by running it. Every fix in this area so far has been pinned by a test
**verified to fail against its predecessor**; keep that standard.

## 8. Reproduction — exact, ~3 min

`games/`, the BIOS and the memory card are all on the author's machine only. The fixtures
live in `zig-out/` (gitignored), so re-capture them.

```bash
zig build -Doptimize=ReleaseFast

INPUT="$(for m in $(seq 700 30 1300); do printf '%d:circle;' $m; done)"
./zig-out/bin/ps1-golden stream-capture \
  --cue="games/Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 1)/Final Fantasy VII (USA) (Disc 1).cue" \
  --key=ff7-mako-off \
  --memcard="$HOME/Library/Application Support/PS1/MemoryCards/card1.mcd" \
  --input="$INPUT" \
  --instructions=2200000000 --capture-from=2186000000 --frames=8

# add --pgxp-on --key=ff7-mako-pgxp for the PGXP control

zig build metallib          # the shader is compiled OFFLINE; edits do not reach Swift without this
echo 8 > zig-out/fixtures/PS1_DUMP_SCALED
xcodebuild -project ps1-macos/PS1.xcodeproj -scheme PS1 -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" SYMROOT=.build/xcode \
  -parallel-testing-enabled NO \
  "-only-testing:PS1Tests/dumpsScaledImagesForEyeballing()" test
rm zig-out/fixtures/PS1_DUMP_SCALED
```

**Frame 6 is the Mako Reactor field with Cloud.** Cloud sits at native (150..180, 100..130),
i.e. (1200..1440, 800..1040) in the 8x image.

Compare at matched size:

```bash
magick zig-out/fixtures/ff7-mako-off-frame6-1x.png -crop 22x26+152+101 +repage \
  -filter point -resize 2500% /tmp/z1x.png
magick zig-out/fixtures/ff7-mako-off-frame6-8x.png -crop 176x208+1216+808 +repage \
  -filter point -resize 312% /tmp/z8x.png
magick /tmp/z1x.png /tmp/z8x.png +append /tmp/side.png
```

## 9. How the 387 was measured — repeat this to confirm any fix

Re-implement the shader's edge functions in Python over the fixture's own records and ask,
for every subtexel the shader left unpainted inside a 1x-painted block, whether **any**
triangle covers it. Covered ⇒ the clause deleted it. Not covered ⇒ legitimate silhouette.

`.p1fx` layout: 48-byte header (frame count at offset 20), then a 24-byte frame-table entry
per frame (`record_off, record_count, payload_off, payload_count`), then 96-byte records.

Three traps, all paid for once:
- **Vertices are at record offset 36, not 24.** (`kind/opcode/transparent/_pad0`, `value`,
  `clut`, `tpage`, then six `int32`, *then* `v[3]` of 20 bytes each.)
- **Vertex coordinates are PRE-OFFSET.** Track `SET_DRAW_ENV` (kind 7) opcode `0xE5` and add
  the sign-extended 11-bit x/y. FF7 emits ~106 of them per frame, one per body part.
  Without this every triangle lands off-screen and you will conclude, wrongly, that nothing
  covers the pixel.
- Fill rule: `isTopLeft(dx, dy) = dy > 0 || (dy == 0 && dx < 0)`, bias `-1`, q-unit 16.

## 10. Traps specific to this area

- **`zig build metallib` after every `.metal` edit.** The shader is compiled offline into
  `libps1shaders.a`; Swift and the app both read the embedded blob. Note the installed
  file's **mtime is the cache artifact's, not the build's** — it can look stale when it is
  not. Check behaviour (run a test), never mtime.
- **A fixture window starts from a BLANK VRAM.** Textures uploaded before the window are
  gone, so every textured draw discards on texel 0 and the captured model is partial
  (Gouraud geometry still renders, which is what the measurement above uses). If a future
  question needs the textures, the capture tool would have to skip its blanking and export
  the live VRAM as a preload — not built.
- **Pick the capture instruction from a `ps1-trace` snapshot, then confirm by reading the
  fixture's per-frame record count.** 40M instructions early landed in a dialogue: 66–175
  records and zero payload, where the field carries ~745 records and a payload.
- Run scale-8 Swift work with `-parallel-testing-enabled NO`, and re-run before believing a
  failure with no `✘` line (documented flaky crash under sustained scale-8 GPU load).

## 11. Commits

| | |
|---|---|
| `6493756` | fix(metal): a sub-pixel facet must not lose the pixel its neighbour owns |
| `33e6561` | docs: the second half of the hollow-triangle bug, and why blocky is forced |
| `eb71c90` | feat(golden): capture one named disc, with a memory card and a pad script |
| `2816f90` | docs: the FF7 holes are the degeneracy clause, and Gate 2 forbids the fix |

Delete this file once the decision is made and the work lands; the durable half already
lives in `CLAUDE.md`.
