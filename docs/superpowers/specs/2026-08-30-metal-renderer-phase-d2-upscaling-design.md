# Metal renderer Phase D2 — upscaling in the app — design

**Date:** 2026-08-30
**Status:** approved; one implementation plan
**Parent spec:** `docs/superpowers/specs/2026-08-23-metal-hardware-renderer-design.md`
(§ Display and scanout, § The C ABI, § Phases → Phase D)
**Predecessor:** `docs/superpowers/specs/2026-08-30-metal-renderer-phase-d1-live-path-design.md`
**Also authoritative for the scaling rule:**
`docs/superpowers/specs/2026-08-29-metal-renderer-phase-c-design.md`

## Goal

Let the player choose the internal resolution, and make the extra resolution
reach the screen. Phase C made the rasterizer exact at 1…8×; D1 put it on the
display at 1×. This phase is the last link: a setting, a persisted choice, and a
display pass that samples the scaled texture instead of reducing it back to
native.

It is the final phase of the Metal hardware renderer. Nothing after it belongs to
this spec's umbrella.

## Scope

In:

- `InternalResolution`: the range, the persisted setting, and the clamp.
- `internalScale` on `EmulatorViewModel`, and a `CommandMenu` bound to it.
- `MetalDisplayView` / `LiveRenderer` rebuilt at the chosen scale, and the resync
  that a rebuild requires.
- Scale-aware display sampling and the scanout wrap in `DisplayShader.metal`.

Out — permanently, or elsewhere:

- **The 4:3 aspect lock and the letterbox.** Struck, with reasons — see § The
  aspect lock is not in this phase.
- Any Zig change. This phase adds none, exactly as Phase C added none: no
  `ps1-core`, no `ps1-capi`, no `ps1-golden`.
- Any change to the software rasterizer's output. Phase 0 was the only phase
  permitted that.
- PGXP, texture filtering, widescreen hacks, 24bpp display *enhancement*.

## Decisions taken

### 1. The scanout wrap is native, then scaled — NOT a scaled mask

**The parent spec's form is wrong and must not be implemented as written.** It
specifies the scale-aware wraps as `& (1024N−1)` and `& (512N−1)` (§ Display and
scanout, and again in § Phases → Phase D). A bitwise mask is a modulo only when
the modulus is a power of two. At N=3 the mask is 3071, which is not
`mod 3072`, so a display window crossing the VRAM edge samples the wrong column
— and this is exactly the shift-and-mask defect class Phase C put N ∈ {2,3,4,8}
in its gate list to catch, because `/ s` and `% s` degenerate to shifts and masks
at every power of two.

Three forms were weighed. Writing the scaled coordinate as `px = nx·s + sub_x`:

| form | expression | verdict |
|---|---|---|
| A — native wrap, then scale | `((vram_x + nx) & 1023)·s + sub_x` | **taken** |
| B — scaled mask | `(vram_x·s + px) & (1024·s − 1)` | wrong for non-power-of-two N |
| C — scaled modulo | `(vram_x·s + px) % (1024·s)` | correct, but a second coordinate space |

A and C agree for every N; the proof is one line. With `A = vram_x + nx` and
`A = 1024q + r`, `A·s + sub_x = 1024s·q + (r·s + sub_x)` and
`0 ≤ r·s + sub_x < 1024s`, so the modulo is `r·s + sub_x` — form A exactly.

A is taken over C because it is **already this project's rule**. Phase C's
§ Two reads that must stay native says `ps1_vram_read` linearizes in native space
and scales the result, and that a textured rectangle's `u`/`v` wrap is computed
from `nx`. The display pass is the same shape of read, and giving it a second,
scaled wrap space to be reasoned about separately buys nothing.

### 2. Sampling at scale is the point of the phase; the wrap is a consequence

The parent spec states the sampling multiplication once, in § The C ABI —
"`Ps1Display` is unchanged: `width`/`height` still come from
`getVisibleWidth/Height`… At scale N those are multiplied for sampling the
scaled texture and **not** multiplied for the aspect math" — and then omits it
from the Phase D bullet, which lists only the wraps.

That omission is worth correcting explicitly, because the wraps alone are a
no-op change. `display_fragment` derives `px`/`py` from the uv against
`p.width`/`p.height`, which are the programmed display area in **native** units
(`registers.zig`'s `getVisibleWidth/Height`). Scaling only the wrap leaves the
sample landing on each N×N block's top-left subtexel — which, by Phase C's
exactness property, is *byte-identical to the 1× picture*. The player would
select 8×, pay 134 MB, and see no difference.

The change that delivers the resolution is `px = uv.x · (width · s)`.

### 3. Live application, via D1's rebuild path

A scale change rebuilds `MetalVram` and therefore the render texture.
`MetalDisplayView` gains a `scale` and `ContentView` keys `.id()` on the runner's
identity **and** the scale, so the coordinator, its pipelines and its textures are
rebuilt exactly as they already are on a disc change (D1 § Lifecycle). Rebuilding
pipelines for a user-initiated, rare event is fine; a second bespoke
reconfiguration path is not.

### 4. `requestResync()` belongs in the coordinator's `init`, not at the call site

A fresh `MetalVram` is a **blank** texture. A command stream is a set of
incremental mutations, so applying the next queued stream to a blank texture
leaves the picture permanently wrong, with no symptom that names its cause —
the same failure mode D1's § Ordering and resync exists to prevent, arriving
through a new door.

`StreamQueue`'s `resync` flag defaults `true` (`StreamQueue.swift:58`), which
covers a *fresh queue*. A scale change keeps the runner and therefore keeps its
queue, so the default does not fire. The coordinator's `init` therefore calls
`runner.streams.requestResync()` unconditionally: it is unmissable there, and on
the disc-change path it is a harmless no-op against a flag already set.
`requestResync` is a release store on an atomic with multiple legitimate
producers already (D1 names three), so a fourth is not a new hazard.

### 5. Range 1…8, default 1

Everything Phase C proved, shipped. The default is 1 because 1× is the only
scale with a per-frame oracle on arbitrary content: the software shadow is a
byte-exact reference for whatever the player is playing, and above 1× the
comparison is the weaker downsample-invariance one (§ The gate). A user who
selects 4× is opting out of the stronger check knowingly; the out-of-the-box
configuration should not opt out for them on the first release that has a scaled
path at all.

### 6. The picker clamps; the precondition stays

`MetalVram.init` traps out-of-range scale (`MetalVram.swift:51`), and its own
comment anticipates this phase: that trap "stops being right the moment Phase D's
resolution picker reads a scale back from a persisted setting: that value is
data, not a literal, and it must be clamped or rejected by the picker rather than
aborting the app here."

Taken as written. `InternalResolution.load()` clamps into `1...8`, so a
`UserDefaults` value hand-edited to 99 — or written by a future build with a
wider range and then downgraded — starts the app instead of crashing it at
launch. The precondition remains, unchanged, as what it always was: a
programming-error trap for a bad literal.

## The aspect lock is not in this phase

The parent spec lists "the 4:3 aspect lock and the letterbox interaction at
scale" as D2 work, and D1's § Scope repeats it. **There is no interaction.**

- `letterboxScale` (`MetalDisplayView.swift:14-23`) takes the drawable's width
  and height and compares their ratio against 4:3. It reads nothing from the
  renderer, the display area, or the scale.
- `WindowConfigurator` sets `contentAspectRatio` from a constant `NSSize(4, 3)`
  and reads nothing from the renderer either.
- `display_vertex` applies the letterbox to **uv** and leaves the triangle at
  full viewport size, so the picture's mapping to the drawable is a function of
  the drawable alone.

Internal resolution changes how finely the render texture is sampled, not the
dimensions of the picture or of the window. The two are orthogonal by
construction. This section exists so that a reader who finds the item in the
parent spec and no section here does not conclude it was forgotten.

## Architecture

### `InternalResolution`

A small value type owning three things: the supported range, the `UserDefaults`
key, and a **clamping** load. It is a separate type rather than two lines inside
the view model so the clamp is reachable from a test without a window, matching
`ScopedBookmark`'s shape (`ScopedBookmark.swift:36`, `:55`) — the app's only
existing persisted setting.

`EmulatorViewModel` holds `internalScale: Int`, observable, initialised from
`InternalResolution.load()` and writing back on set.

### The menu

A `CommandMenu("Video")` in `PS1App` with a `Picker` bound to
`model.internalScale`, ⌘1…⌘8. Always enabled: it is a preference, not a
per-session control, and selecting one with no game loaded simply persists it.

The menu is chrome and is not tested. Everything decision-bearing — the clamp,
the persistence, the rebuild, the shader — sits below it and is.

### The rebuild

`MetalDisplayView(runner:scale:)`. `ContentView` keys
`.id()` on both the runner's `ObjectIdentifier` and the scale
(`ContentView.swift:13-21`). `Coordinator.init` builds
`LiveRenderer(device:queue:scale:)` — the parameter already exists
(`LiveRenderer.swift:22`) and already forwards to `MetalVram` — and then calls
`runner.streams.requestResync()` per Decision 4.

The shadow texture in the coordinator stays 1024×512. It is the 24bpp source and
the resync source, and both are native by definition.

### The display pass

`DisplayParams` and `Params` each gain a trailing `uint scale`. Both are 4-byte
aligned throughout, so the stride goes 36 → 40 on both sides with no padding
question; the existing rule that field order and types must match exactly
(`MetalDisplayView.swift:25-27`) is unchanged.

`display_fragment`:

```
uint sw = p.width  * p.scale;
uint sh = p.height * p.scale;
uint px = uint(in.uv.x * float(sw));   // clamped to sw - 1
uint py = uint(in.uv.y * float(sh));   // clamped to sh - 1
uint nx = px / p.scale,  sub_x = px % p.scale;
uint ny = py / p.scale,  sub_y = py % p.scale;
```

- **15bpp** reads the render texture at
  `(((p.vram_x + nx) & 1023) * s + sub_x, ((p.vram_y + ny) & 511) * s + sub_y)`
  — Decision 1's form A.
- **24bpp reads the shadow at `nx`/`ny`, and `sub_*` are discarded.** This is the
  trap in the phase. The shadow is 1024×512 at every N, and the 24bpp path
  reconstructs pixels by byte-packing across *adjacent 16-bit VRAM words*
  (`DisplayShader.metal:61-82`) — arithmetic that is meaningless in scaled space
  and the entire reason D1 routed 24bpp to the shadow permanently. Feeding it
  `px` instead of `nx` breaks every FMV in Croc and Silent Hill at N > 1 and
  nowhere else.
- **The `PS1_SOFTWARE_DISPLAY` debug seam reads the shadow at `nx`/`ny`** for the
  same reason.

At N=1, `nx == px`, `sub_x == 0` and `sw == p.width`, so every expression reduces
to today's character-for-character. That is what makes "1× is unchanged" a claim
about a `* 1`, not about a rewritten shader — the same argument Phase C's
§ The scaling rule makes for the rasterizer.

**No filtering is added.** The display remains exactly one point sample per
drawable pixel; the only change is that the sample grid is N× finer. A
downsample-and-filter pass is a different feature with different output and is
not in this phase.

## The gate

### The property

The display-side analogue of Phase C's exactness property, and mechanical for
the same reason: **a scaled texture whose every N×N block is uniform must present
byte-identically to the native image presented at 1×.** Block-uniformity is what
`uploadNative` produces, so the fixture is free.

This is strictly stronger than the visual checklist the parent spec fell back to,
and it fails form B of Decision 1, an off-by-one in the `sw - 1` clamp, and the
24bpp `px`/`nx` mix-up — each with a distinct signature.

### Deterministic

1. **Invariance**, at N ∈ {2,3,4,8}: `uploadNative(image)` into a scaled
   `MetalVram`, render the display pass at N into an offscreen drawable, and
   require the result byte-identical to the same image at N=1 into the same
   drawable. **N=3 is in the list on purpose** — it is the only member that
   fails form B.
2. **The wrap case, at N=3, as its own test**: `vram_x` near 1023 with a width
   that crosses the VRAM edge. Its own case rather than a hope that (1)'s image
   happens to cross, because this is the case the parent spec got wrong.
3. **24bpp at N=4 identical to N=1**, pinning the `nx`/`ny` routing.
4. **`InternalResolution`**: clamp, round-trip, and an out-of-range persisted
   value loading rather than trapping.
5. **`LiveRenderer` at N**: a queued stream drains into a scaled texture and
   `readbackNative()` matches the 1× replay of the same stream. Phase C's
   property, re-run through the live path rather than the fixture harness.
6. **All eleven Phase B and C fixture gates re-run unchanged.** A moved fixture
   hash is a bug in this phase, never a baseline to update.

### Exploratory

`PS1_LIVE_DIFF=1` at N ∈ {2,3,4} on Croc, Silent Hill, Spyro, Crash and TR1.

**This works at N > 1 for free, and it is a better instrument than D1 expected to
leave behind.** `LiveRenderer.diff` reads `vram.readbackNative()`, which is
already the top-left-subtexel view at any scale, so at N the existing oracle
becomes a *live downsample-invariance check on real games* — the thing D1's
§ Phase D is split said did not exist above 1× outside the fixture corpus. It
does; it is exploratory rather than CI, which is the same standing D1's own use
of it has.

The response to a divergence is unchanged and must stay unchanged: bank the
window as a fixture with `stream-capture`, never weaken the check. The one
divergence class no GPU backend can reproduce in any phase — a primitive that
samples its own destination — is still a thing to recognise rather than chase.

Also by hand, and not automatable: 1× and 8× A/B on the same scene, to confirm
the setting does something visible at all. Decision 2 exists because a plausible
implementation of this phase produces no visible change whatsoever, and no
mechanical gate in the list above would notice.

## Tasks

Five, strictly ordered.

| # | task | gate |
|---|---|---|
| 1 | `InternalResolution`; `internalScale` on `EmulatorViewModel` | clamp, round-trip, out-of-range load |
| 2 | `scale` in `DisplayParams`/`Params`; scaled sampling and form-A wrap; 24bpp on `nx`/`ny` | invariance at N ∈ {2,3,4,8}; the wrap case; the 24bpp case |
| 3 | `MetalDisplayView(runner:scale:)`, `.id()` on runner + scale, `requestResync()` in `init` | `LiveRenderer` at N; Phase B/C fixture gates unchanged |
| 4 | `CommandMenu("Video")` with ⌘1…⌘8 | none — chrome |
| 5 | `PS1_LIVE_DIFF` at N ∈ {2,3,4} on the five games, plus the 1×/8× A/B | exploratory; zero divergence, or a banked fixture |

Task 2 lands before task 3 deliberately: the shader is the phase's substance and
is fully testable offscreen against a hand-built texture, with no runner, no
queue and no menu in the picture.

## Risks

- **Draw-callback cost at N=8 is unmeasured on live content.** Phase C measured
  replay cost per fixture (2.9 s for a scale-8 pass over both 100-frame geometry
  fixtures); it did not measure passes per frame on a live game that alternates
  draw and sample. D1's queue is the seam if a dedicated render thread becomes
  necessary, and the parent spec's standing instruction holds: do not weaken the
  hazard test to buy speed.
- **A resync at N=8 will stutter.** `uploadNative` replicates on the CPU
  (`MetalVram.swift:164-179`), which at N=8 is 33.5M `u16` stores — ~67 MB — on
  the draw callback. The parent spec already accepts "momentarily 1×, then
  resumes at N", and the path is rare by construction, so this is flagged rather
  than pre-optimised. If it becomes a real complaint, the fix is a blit-and-blow-up
  render pass, which Phase C considered and rejected only because nothing was
  waiting on it.
- **Memory at N=8** is 67 MB of render texture plus 67 MB of copy scratch, beside
  D1's 27 MB queue and `.dual`'s 6.8 MB in `Bus`. Comfortable on Apple silicon
  and the reason the range was not capped, but it is the number to revisit first
  if a low-memory machine is ever a target.
- **Above 1× there is no byte-exact oracle on arbitrary content**, only
  downsample-invariance. That is a real reduction in check strength, mitigated by
  Decision 5's default and by the exploratory oracle above, and it is inherent:
  supersampled subpixels have no software reference to be compared against.
