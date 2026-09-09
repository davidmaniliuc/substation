---
name: ps1-gpu-metal
description: Use when touching ps1-core/src/gpu/ (rasterizer, gp0, renderer, vram, the command-stream sink/recorder), the Metal backend (Rasterizer.metal, MetalRasterizer, MetalVram, PrimBuilder, PrimEncoders, HazardTracker, LiveRenderer, StreamQueue), .p1fx fixtures, or internal resolution / upscaling. Covers the integer edge-function rules, dithering, the oversized-primitive drop, GPUSTAT bits, mask bits, the live command-stream path, the scaled-path gates and their blind spot.
---

# GPU + Metal renderer

**GPU** (`gpu/`) — ABGR1555. **The triangle path is an integer edge-function
rasterizer with a top-left fill rule and exact integer interpolation of every
per-pixel attribute (Gouraud colour, texcoord, texture modulation) — no `f32`
anywhere in the inner loop.** The formulas are shared with the Phase B Metal
backend by design (Metal Renderer Design, Phase 0): don't "optimise" them back
into float, or into incremental/stepped fixed-point, even though either would
be a cheaper CPU implementation on its own. **`drawShadedLine`'s gradient is
the same deal**: `c0 + floor((c1-c0)*k / steps)`, evaluated from the step
index `k` rather than accumulated — also not to be turned back into float or a
DDA. **Dither offsets, wherever added (Gouraud, texture modulation, the
shaded-line gradient), are 8-bit channel units**, added to the channel at
8-bit scale and clamped to `[0, 255]` *before* the `>> 3` down to 5 bits —
misreading them as 5-bit units is the bug `900daa0` fixed. `900daa0` also
moved `drawTexturedRectangle`'s output: it calls `modulate` with dithering
too.

**A Gouraud-shaded TEXTURED polygon (GP0 0x34-0x37, 0x3C-0x3F) modulates its
texel by the colour INTERPOLATED across the primitive, and until 2026-09-04 it
modulated by vertex 0's colour alone.** Both rasterizers did, because the
record carried one flat `value` and no per-vertex colour for the textured
kind; `draw_textured_triangle` now carries all three in `v[i].color` and a
flat-shaded polygon simply repeats its one colour, which the interpolation
reproduces bit for bit (`w0 + w1 + w2 == area` exactly). Three things are
worth keeping. The artifact is NOT a subtle shading error: a mesh that ramps
each facet from bright at its core to black at its rim comes out as **flat
hard-edged triangles wherever the first vertex is bright and as nothing at all
wherever it is black** — modulating by black is black, and these primitives
are usually additively blended, so the black half of the mesh vanishes and
leaves triangular HOLES. That is what Crash Warped's title glow was: a soft
halo rendered as a starburst of hard blue shards. **Avocado is an oracle here**
(`render_triangle.cpp`: `c = c * colorInterpolated` under `isGouraudShaded`,
`c * colorFlat` otherwise), so diffing against it would have found this. And
the whole `.p1fx` corpus agreed on every hash throughout, because nothing in
it carried a Gouraud-textured primitive at all — **frame 7 of
`synthetic-primitives.p1fx` is the rung that now gates it**, and it is the
only frame in the ladder that can. One knowing divergence remains: hardware
(and Avocado) modulate an 8-bit shade against a 5-bit texel (`>> 7`), while
`Color.modulate` truncates the shade to 5 bits first, exactly as the flat path
always did. That costs a little gradient precision and is deliberately left
alone; changing it moves every textured pixel in every game.

**No texture/CLUT
cache** (re-reads VRAM per texel). GP0 goes through a real 16-word FIFO with a
`cycle_debt` budget; cycle "cost" is hand-tuned heuristics, not real clocks.
Quads decompose into 2 triangles (possible diagonal seam); the textured-rectangle
path avoids decomposition on purpose. **A primitive whose vertices span >=1024
horizontally or >=512 vertically is dropped, not clipped** — the check sits in
`rasterizeTriangle` (per triangle, so each half of a quad is judged separately),
in both line paths, and in both rectangle paths — the GP0 rectangle size field
is 16 bits, so nothing else bounds it. Matches Avocado's
`render_triangle.cpp:214` / `render_line.cpp:24` / `render_rectangle.cpp:17`. This is load-bearing, not a micro-optimisation: geometry
crossing the near plane projects to screen coordinates that saturate at the
GTE's +-1024 SXY clamp, and hardware refusing to draw the result is the only
thing keeping it off screen. Games do not clip it themselves. Without the rule
Silent Hill's roadside foliage sweeps across the camera in the opening street —
about 110 triangles per 4 frames there are oversized, and every one of them was
being painted. Pinned by four tests in `gpu_test.zig`. Scanout uses the **programmed display area**
(`disp_env.screen_x1/x2`, `screen_y1/y2` → `getVisibleWidth/Height`), not the
nominal mode size. Every VRAM write except Fill Rectangle honours the GP0(E6)
mask bits: drawn pixels via `putPixel`, CPU->VRAM and VRAM->VRAM transfers via
`Vram.maskedWrite`. Fill Rectangle is unmasked **on purpose** — hardware ignores
E6 there. Bit15 of a drawn pixel is the **source** pixel's own bit15 (a textured
primitive's texel STP bit, 0 when untextured) OR'd with GP0(E6).bit0, and blending
carries it through — never clear it, games leave STP-set texels in VRAM
specifically to mask later check-mask draws (Silent Hill brackets its player that
way). VRAM transfers are a stateful multi-word FSM — a bug there silently swallows
real commands. A textured **polygon** latches its texpage word back into
GP0(E1) so GPUSTAT reflects it; a textured **rectangle** does not, because it
reads the current texpage rather than carrying one. GPUSTAT bit 15 is the E1
texture-disable bit, *not* GP1(09)'s "texture disable is allowed" latch.
Three more GPUSTAT bits are easy to get wrong: **bit 13 is hardwired to 1**
(it is the interlace field, not a PAL flag), **bit 27 is `readMode == Vram`**
— true only while a GP0(C0) transfer is in flight, so GPUREAD reports the
register once it drains and GP1(00) must not re-select VRAM — and **bit 25's
DMA request depends on the programmed direction** (off for 0, on for 1 and 2,
a mirror of bit 27 for 3).

**`gp0.zig` cannot reach the renderer.** Every VRAM-visible effect goes through
`gpu/sink.zig`, which builds a fixed-stride `command.Command` and hands it to
`command.execute` — the one function that turns a record into an effect, used by
the live path and by replay alike. The seam exists so the Metal backend can
consume an ordered stream, and the structural guarantee is the missing import: a
primitive that does not appear in the sink does not draw. **The stream must carry
the implicit texpage latch, not just E1-E6** — `e1_texpage_mask` covers bits 5-6,
the semi-transparency mode, so a textured polygon's blend mode comes from its own
tpage word; rectangles do not latch. **A record carries every input the effect
needs and nothing may be re-derived at replay time** — which is why the three
Gouraud modulation colours ride in `v[i].color` rather than being reconstructed
from `value`. Which core module records is a comptime
build option (`gpu_sink`), `.software` everywhere except `ps1-golden`, the two
ROM suites, and — since Phase D1 — `ps1-capi`, so the macOS app and `capi_test`
build `.dual` too; `Recorder.enabled` is a further runtime flag, so
`capture`/`verify` stay at today's speed. The recorder's capacities (`max_records`,
`max_payload_words`) are sized off the peaks `stream-verify` prints — it prints
them on success too, for exactly that reason.

**The fixture bridge is how Metal gets tested at all.** Metal runs only under
`ps1-macos/test.sh`; the ROM suites run only in Zig. `zig build fixtures`
writes `.p1fx` files — a header, a frame table, 96-byte records and a payload
blob — that Swift reads through `FixtureFile`. **The record type is declared
in `ps1-capi/include/ps1.h`, not mirrored in Swift**, because Swift does not
guarantee C-compatible struct layout; the header's `record_stride` and
`kind_count` are checked on load so a field or a `Kind` added on the Zig side
fails loudly instead of shearing every record. The hash is **FNV-1a 64, not
the trace harness's Wyhash** — Wyhash is a std-library implementation that can
change across Zig releases, and a file format pinned to it would break on a
toolchain upgrade while presenting as "Swift disagrees with Zig". Payload
offsets are **frame-relative**: a `vram_write_data` record's `.x` indexes its
own frame's run, exactly as `command.replay` reads it. Only the committed
synthetic fixture has its VRAM hashes verified — `ShadowVram` models the
memory movers, never the rasterizer — so the PL and Croc fixtures are
structurally checked and otherwise banked for Phase B. **Sixteen of each
PeterLemon fixture's seventeen frames are empty and repeat frame 0's hash** —
those ROMs draw once and then idle, so "17 frames verified" is not 17 frames
of coverage; only frame 0 is doing anything.

**The Metal backend renders at an internal resolution of 1-8x, and since Phase
D2 that scale is a player-chosen setting that reaches the screen.**
`MetalRasterizer` (with `MetalVram`, `PrimBuilder`, `PrimEncoders`,
`HazardTracker`) consumes both `.p1fx` fixtures and, since Phase D1, the live
command stream: `ps1-capi` builds `gpu_sink = .dual`, `ps1_take_frame_stream`
drains one frame per `ps1_run_frame`, `EmulatorRunner` copies it into a 4-slot
ring, and `LiveRenderer` drains that ring from the `MTKView` draw callback.
`Video ▸ Internal Resolution ▸ 1x…8x` writes `InternalResolution` to
`UserDefaults`. It is a **submenu**, matching Machine ▸ Change Disc — eight
scales spread flat over the Video menu bury the one other entry under them —
but it stays a `Picker` (`.pickerStyle(.menu)`) where Change Disc is a `Menu`
of `Button`s, because a scale is a preference and gets the system's checkmark,
where a disc swap is an action per item and draws its own. The menu attaches
⌘1…⌘8 via `.keyboardShortcut` on each `Picker` option's `Text` in
`VideoCommands.swift` — not a documented SwiftUI contract, only a type-check,
and now inside a submenu besides — so treat the accelerators as unverified
until someone confirms them by eye; a plain `Button` per scale is the fallback
shape if they don't show up in the menu.
`ContentView` keys `.id()` on the runner's identity AND the scale, so a change
rebuilds the coordinator, its pipelines, its `LiveRenderer` and its `MetalVram`
through exactly the path a disc change already uses.
Fixture playback still produces VRAM byte-identical to the software
rasterizer, checked per frame by `MetalRasterizerTests`. Four things about it
are load-bearing and easy to
"fix" wrongly: **coverage is decided in the FRAGMENT shader**, never by Metal's
rasterizer, whose fill rule and sample positions are not the PS1's; **blending
is integer arithmetic on 5-bit channels**, never fixed-function blending, which
normalizes to float and rounds differently; **every primitive is one instance
of a bounding-box quad** with all its state resolved on the CPU into a
`Ps1PrimInstance`, which is what leaves no pipeline state differing between
primitives and therefore nothing to break a batch on; and **a draw that samples
what the current render pass has already written must end that pass first**
(`HazardTracker`) — on a tile-based GPU such a read returns pre-pass contents,
so without the split it is silently stale. `synthetic-primitives.p1fx` is the
per-feature gate ladder, committed, one feature group per frame in a fixed
order that the Swift tests index by number; append to it, never reorder it.
**The texel HOLE is decided on the RAW texel, before modulation, and the
sampled colour must not travel back through the same value.** `renderer.zig:439`
returns `.draw = false` only for a raw texel of 0; a non-zero texel that
modulation maps onto 0x0000 is drawn BLACK (`renderer.zig:441-446`). Until
2026-08-30 `ps1_sample` returned the modulated colour and reused 0 as the hole
sentinel, so every such pixel was discarded and whatever was already in VRAM
showed through — a green speckle over the dark parts of Croc's rock, door and
crate. It now returns a bool with the colour in a `thread ushort&` out-param,
the shape `ps1_triangle_coverage` already used. Two things about it are worth
remembering. **Dithering makes one bug look like two**: its offset is in 8-bit
channel units and is applied at 1x only, so a marginal channel is pushed under
8 (and `>> 3` to 0) in a speckled pattern at 1x and left alone above it — the
crate's speckles vanish at 8x while the door's, whose un-dithered value is
already 0, do not. **The whole fixture corpus agreed on every hash throughout**,
because nothing in it modulates a texel to zero; a hand-built test
(`aTexelThatModulatesToBlackIsDrawnRatherThanDiscarded`) is what pins it, not
the gate ladder.
**A primitive that samples its OWN destination is the one shape no GPU
backend can reproduce, in any phase.** The software rasterizer scans row by
row, so a triangle whose texture read lands on pixels it has already drawn
sees the new values deterministically — and that determinism is baked into
every hash it produced. Nothing orders fragments *within* one primitive on a
GPU, so `HazardTracker` (which orders one draw against the next) does not
help and never will: it is a divergence class, not a bug to chase. Frames 2
and 4 of `synthetic-primitives.p1fx` contained it by accident and were
relocated below every read address they can generate (`142feb0`, `99bb56e`);
frames 0-5 now hold that invariant by construction, and frame 6's
*inter*-primitive feedback is the deliberate case `HazardTracker` exists for.
Expect this to resurface in Phase D as a real game diverging on a handful of
pixels with no explanation in the encoder.

Seven things about the live path are load-bearing. **`ps1_take_frame_stream` is a
DRAIN, not a peek** — it resets the recorder, so it must be called exactly once
per `ps1_run_frame`, and a frame left untaken stacks onto the next until the
capacity overruns. **`complete == 0` means the records are a PREFIX**, so the
stream is discarded and the renderer resyncs from the shadow rather than
replaying it. **VRAM is published before the stream, under the same seq**, so a
shadow sampled at seq `S` accounts for every frame up to and including `S` and
for none above it — which is why a resync discards **only the slots at or below
`S`** (`StreamQueue.discardThrough`) and executes the rest. Discarding the whole
backlog instead loses the mutations of any stream published after the sample,
and replaying a slot at or below `S` applies its mutations twice, which
VRAM->VRAM copies, semi-transparent blends and mask-bit draws do not survive.
The flag is **cleared before the shadow is sampled**, because `clearResync` is a
store rather than a compare-and-clear and would otherwise swallow a request
raised in between; and it is **left raised when the queue does not resume at
`S+1`**, since a hole means the survivors have no matching base. Until
2026-08-30 this was "discard the backlog and adopt the newest shadow", sampled
after the queue snapshot, and it was racy in both directions. **Execution never skips a frame, only
presentation does** — a command stream is a set of incremental mutations, unlike
the idempotent VRAM snapshot the shadow path publishes. And **24bpp scans out of
the 1x shadow permanently**, because it byte-packs across adjacent 16-bit words
and that arithmetic cannot survive N x N replication; Croc and Silent Hill both
depend on it.

**"The texture is not a picture of anything" and "a frame never arrived" are
two conditions, not one, and conflating them is what made the picture flicker
between 8x and 1x** (fixed 2026-09-03). `StreamQueue` carries `resync` for the
first and `dropped` for the second. Only `resync` may be answered by adopting
the shadow: it means a BLANK `MetalVram` — a fresh queue, a scale change, a
disc change, the coordinator's unconditional request — where there is no
picture to preserve and skipping leaves the window black until something
repaints all of VRAM, which for a static backdrop is never. `dropped` says the
opposite: the texture is a faithful picture of every frame that DID arrive, and
one that did not has no records to execute anyway. The choice there is not
whether to run the lost frame — nothing can — but whether to answer its absence
by throwing the scaled picture away, and **above 1x that is exactly what
adopting the shadow does**: `uploadNative` replicates a NATIVE image N x N, so
the whole frame drops to nearest-neighbour 1x until the game repaints it. At 1x
it is still adopted, because there `uploadNative` IS `upload` — exact, one
upload, and that exactness is what `PS1_LIVE_DIFF` at 1x is; the default scale
must not opt out of the only oracle covering real games. So the rule above
holds with one narrow relaxation, and `LiveRenderer.drain` is where the scale
decides it. `takeDroppedFrames` is a read-and-clear where `clearResync` is a
plain store: clearing the resync early costs a redundant re-adoption, while
clearing this one early would silently keep a stale picture with nothing left
to say so.

**But keeping the picture is only HALF an answer, and shipping it alone made
FF7's menu text invisible** (fixed 2026-09-04). "Games clear and redraw every
frame, so a lost mutation is corrected on the next one" is true of the DISPLAY
AREA and false of the rest of VRAM. A texture page, a CLUT and a VRAM->VRAM
copy are written ONCE and sampled by every frame after; no later stream repeats
them, so a frame lost while one is in flight is lost for the whole scene, and
above 1x nothing existed that could ever put it back. Measured on
`ff7-menu.p1fx` (`stream-capture` over the main menu, the recipe below plus
`2195:triangle`): the frame that opens the menu carries a single 256x3
`vram_write_setup` at (256, 493) — the menu's palettes — with 384 payload words
and **no draws at all**, and every one of the ~50 frames after it carries 197
`draw_textured_rectangle`s and **zero** payload words. Lose that one frame and
the text draws through a stale CLUT for as long as the menu stays open. Note
the shape of the report: the glyphs whose palette rows were already correct
(LV/HP/MP, the digits, the timer) rendered normally, so it reads as "some text
is missing" rather than as a lost upload. So `LiveRenderer` records a DEBT
(`repairOwed`) instead of writing the loss off, and settles it by adopting the
shadow on the first drain that loses NOTHING. Settling it while frames are
still being lost re-adopts a native shadow on every draw of a sustained
deficit, which is the flicker under another name; waiting for the burst to end
costs one frame of nearest-neighbour picture and repairs everything the burst
lost. **A deficit that never lifts is still not repaired** — no policy here
both keeps the scale and stays correct, and the remedy there is a lower
internal resolution. `aLostFramesMutationIsRepairedOnceTheDropsStop` pins it,
verified to fail at 2/3/4/8x against `52746d9`; the three tests that pin the
halves which must NOT change all still pass unaltered.

**The renderer falls behind at 8x on real content, and that is a measurement,
not a suspicion.** Per frame at 8x, replayed through gate 4 on this machine
(Debug host): silent-hill 28.5 ms, crash-warped 11.1 ms, against a 16.7 ms
budget at `preferredFramesPerSecond = 60`. Two things followed. `MetalRasterizer`
now **cycles its persistent buffers over three slots** (`FrameBuffers`,
matching MTKView's triple-buffered drawables) instead of blocking the next
`beginFrame` on the previous frame's completion. That old wait was correct —
commit order orders GPU work against GPU work, never a CPU write against an
in-flight GPU read — but it serialized encode against execute, so per frame the
cost was CPU + GPU rather than max(CPU, GPU) and, the part that mattered,
draining a backlog of N frames in one callback cost N full frames back to back,
which is a renderer that has fallen behind guaranteeing it stays behind.
Cycling took 8x to 18.6 / 8.2 ms on the same two fixtures. And `StreamQueue`
holds **8 slots rather than 4** (67 MB), which absorbs a TRANSIENT overrun — a
compositor hitch, one heavy frame — without losing a frame at all. Neither
helps a SUSTAINED deficit, and silent-hill at 8x is still one: no depth fixes
that, which is why `dropped` has to degrade well rather than merely rarely.

Two environment switches, both debug-only and both read by the APP rather than
the test host (the marker-file scheme exists because the hosted test process sees
no environment; the app launched from a shell has an ordinary one):
`PS1_LIVE_DIFF=1` reads the render texture back each frame and logs the first
divergence against the shadow, and `PS1_SOFTWARE_DISPLAY=1` routes 15bpp back to
the shadow so a suspect frame can be A/B'd without a rebuild. Neither is a mode
and neither is a user-facing setting.
**A silent `PS1_LIVE_DIFF` run is not by itself evidence** — the oracle compares
only when the newest published frame is the one the texture holds, and it runs
after a `drain` that blocks on the GPU, so every frame the emulator publishes in
that window is skipped rather than compared. It therefore prints a running
`checked N frames, skipped M` tally every 300 decisions and once more on eject;
read that ratio before reading anything into the absence of divergence lines.

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
`InternalResolution`'s initializer CLAMPS into 1...8 rather than trusting the
stored value, and `set` clamps again on the way in, because `MetalVram.init`
traps out of range and a `UserDefaults` integer is data, not a literal.

**The 4:3 aspect lock does not interact with internal resolution.** The parent
spec lists that interaction as Phase D work; there is none, and this note exists
so nobody concludes it was forgotten. `letterboxScale` reads the drawable's
dimensions, `WindowConfigurator` reads a constant `NSSize(4, 3)`, and
`display_vertex` applies the letterbox to uv while leaving the triangle at full
viewport size — none of the three reads the renderer, the display area or the
scale. Internal resolution changes how finely the render texture is sampled, not
the dimensions of the picture or of the window.

**`PS1_LIVE_DIFF` works above 1x for free, and it is the only coverage there
outside the fixture corpus — but expect it to be loud.** `LiveRenderer.diff`
reads `vram.readbackNative()`, which is already the top-left-subtexel view at
any scale, so at N the oracle becomes a live downsample-invariance check on
real games. It shares that role with a second, expected divergence class:
`Rasterizer.metal`'s fragment shader gates dithering on `s == 1`
(`bool dither = (p.flags & PS1_PRIM_DITHER) && s == 1 && uni.dither_off == 0u`,
`Rasterizer.metal:182`), so above 1x every dithered primitive draws without it
while `LiveRenderer.diff`'s software shadow always dithers. A real game at
2x/3x/4x will therefore print a divergence line on essentially every dithered
3D frame the oracle checks — that is by design, not a scale bug. The signal
worth reading a run for is a divergence that is *not* a ±1 single-channel
difference spread over a gradient; that shape is the dithering class, already
accounted for. Its `checked/skipped` tally still has to be read before an
absence of output means anything.

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
would make the record differ between scales — the visible consequence is
that a scaled frame loses the dither cross-hatch and shows 5-bit banding on
Gouraud gradients instead, which is correct and is Phase D's to revisit. The
gate is **downsample-invariance**: taking each block's top-left subtexel
reproduces the 1x image byte-for-byte over the whole 1024x512, on every
frame of all eleven fixtures, at N in {2,3,4,8} — **3 is in that list on
purpose**, since `/ s` and `% s` are shifts and masks at every power of two
and a `>> log2(s)` bug is invisible at 2, 4 and 8. Measured, the scale-8
pass over both 100-frame geometry fixtures costs 2.9 s, so nothing narrows.
Nothing display-side scales yet (the scanout wrap, 24bpp, the scale picker);
that is Phase D2.

**That gate has one BLIND SPOT, and it is where the scale bugs live: it only
ever looks at top-left subtexels.** `readbackNative()` is the top-left
subtexel of each block, and at a top-left subtexel the sample point IS the
native pixel — so anything a fragment shader decides from `px`/`py` reproduces
its 1x answer there by construction and both gates pass whatever the other
`s*s - 1` subtexels do. Gate 2b's coverage ratio is a whole-frame average and
a corpus of mostly-large primitives dilutes a small-primitive defect away.
That is how `ps1_triangle_coverage`'s degeneracy clause — "and not all three
zero", written as `b_i < PS1_Q_BIAS_SCALE` — shipped evaluated at the SUBTEXEL
when it is a statement about a whole native pixel. The three terms sum to the
twice-area, so it fires for any triangle under 1.5 native px^2; above 1x the
terms stop being multiples of `PS1_Q_BIAS_SCALE` and the band around the
CENTROID, where all three are smallest, is refused while every subtexel nearer
an edge is kept. **A small triangle came out as a RING** — 2 lost subtexels of
20 at 4x, 12 of 72 at 8x — and a distant character model, whose facets are all
about a pixel across, as scattered rims with the scene showing through
(reported on FF7's Cloud at 8x, 2026-09-02). The fix went through two wrong
shapes before landing — see the two paragraphs below — and is now simply that
the clause is asked at the native sample point and nowhere else.
The lesson generalises — **a new scaled-path test must assert something about
the interior of a block, not only its corner.** The one that caught this
(`aSmallTriangleIsSolidRatherThanHollowAtEveryScale`) asserts no unpainted
subtexel is enclosed by painted ones.

**Two earlier fixes are GONE, and the tests they left behind outlive them.**
Both tried to answer the clause per native pixel and hand the whole BLOCK that
answer; both rescued only the pixel's *owner*, since a non-owner's native
sample point lies outside it by definition, so every other facet covering that
pixel was refused there outright and a mesh of ~1px facets is nothing but
neighbours. Three tests pin the shapes that had to be got right along the way —
`aSmallTriangleIsSolidRatherThanHollowAtEveryScale` (no enclosed hole),
`aSubPixelMeshKeepsEveryNativePixelOneXPaints` (a mesh's hole reaches the
silhouette, which a single-triangle test cannot see) and
`aSubPixelFacetPaintsItsShareOfAPixelALargeNeighbourOwns` (the mixed case: a
large facet owns the pixel and paints only its own share, so the sub-pixel
facets covering the rest painted nothing at all).

**The clause is now asked at the NATIVE SAMPLE POINT and nowhere else** — that is
`px % s == 0 && py % s == 0` in `ps1_triangle_coverage`, sitting after an
unchanged `(b0|b1|b2) < 0` that every subtexel still faces. There is one code
path again: no `area < 3 * PS1_Q_BIAS_SCALE` branch, no per-block decision, no
replicated attributes.

The reasoning is that the clause is a statement about SAMPLING, not about the
shape. Hardware takes one sample per pixel, and a triangle enclosing no sample
point paints nothing; off the native lattice there is no hardware decision to
reproduce, because those are samples the console never took. Reproducing a
one-sample-per-pixel artifact 64 times a pixel is faithful to the wrong thing.
Four things about this are worth keeping:

- **Gate 2 stays a STRICT equality**, and this is the crux. At a top-left
  subtexel `px == nx * s`, so `qpx` is exactly `nqx` and the 1x answer is
  reproduced there by construction. Parity was only ever a claim about
  `1/s^2` of the subtexels; the rest were never constrained by it. At `s == 1`
  every fragment is a native sample point, so Gate 1 cannot move either — and
  it did not: `ff7-mako-off` frame 6 at 1x is byte-identical before and after.
- **No `area` guard is needed and none is there.** `renderer.zig` asks the
  clause of every pixel unconditionally; the terms summing to the twice-area is
  what stops it firing on a large triangle. The old large path skipped it on
  that reasoning, which was sound but left the shader's structure saying
  something the reference does not.
- **A genuine sliver is still refused at every native sample point at every
  scale**, which is the half of the rule upscaling must not quietly undo, and
  `subPixelSliversAreRefusedAndPaintedIdenticallyAtEveryScale` still pins it —
  it asserts on `.native`, which IS the lattice. A sliver does now paint the
  off-lattice subtexels it covers. That is the price, it is 1/s^2 of a pixel
  apiece, and it is visible in the measurement as a handful of isolated
  unpainted lattice points inside otherwise solid geometry: 7 over Cloud's
  whole 30x30 native box at 8x, 5 of them on the lattice.
- **Blockiness was a consequence, not a goal.** A sub-pixel facet now paints
  its true share of every pixel it touches, so a mesh of them upscales as a
  mesh. What it costs is the over-paint the old rule added: on FF7's Cloud at
  8x, 303 subtexels that no paintable triangle covers lost their fill, against
  299 covered ones regained — a net 4 fewer painted subtexels and a silhouette
  that follows the geometry instead of the pixel grid.

**The FF7 "Cloud is full of holes at 8x" report was NOT one of the shapes
above, and not PGXP either — it was the degeneracy clause deleting real geometry at scale.
CLOSED 2026-09-03 by moving the clause to the native sample point (above).**
Reproduced 2026-09-02 as a fixture, deterministically and with no app running:

    zig build -Doptimize=ReleaseFast
    ./zig-out/bin/ps1-golden stream-capture \
      --cue="games/Final Fantasy VII (USA)/.../Disc 1).cue" --key=ff7-mako-off \
      --memcard="$HOME/Library/Application Support/Substation/MemoryCards/card1.mcd" \
      --input="$(for m in $(seq 700 30 1300); do printf '%d:circle;' $m; done)" \
      --instructions=2200000000 --capture-from=2186000000 --frames=8
    echo 8 > zig-out/fixtures/PS1_DUMP_SCALED   # then run dumpsScaledImagesForEyeballing

Frame 6 is the Mako Reactor field with Cloud in it. Four things it settled:

- **PGXP is not the cause.** Captured twice, `--pgxp-on` and without, same
  window: both are shattered in the same places at 8x. The earlier note that a
  1x control had "ruled PGXP out" was invalid reasoning that happened to reach
  the right answer — PGXP moves a vertex by a FRACTION of a pixel, so at 1x both
  sides of a crack round into the same pixel and nothing shows. Only a control
  at the SCALE the artifact appears at can rule anything out. (FF7 resolves
  98.3% of 1.3M vertices there, `mixed=0` — coverage was never the problem.)
- **A field character model is made of SUB-PIXEL facets.** Cloud is ~25 px tall
  and carries 232 triangles in that box: twice-areas of 0 (24 of them), 1 (88),
  2 (43), 3 (13), 4 (13), 5 (33), 6 (14), and four above. **67% are under 1.5
  native px^2** — the band the degeneracy clause governs — and 88 are the
  twice-area-1 "genuine sliver" that `subPixelSliversAreRefusedAndPainted…`
  requires be refused at EVERY scale.
- **The holes were geometry the clause deleted, not geometry that is absent.**
  Over the model's 1x-painted blocks at 8x: 4,989 subtexels painted, 643 not.
  Of those 643, **387 were covered by a triangle** and refused; only 256 were
  genuinely outside all geometry (ordinary silhouette refinement). Checked by
  re-implementing the shader's edge functions over the fixture's own records —
  on the worst pixel, all 64 subtexels are covered by some triangle and the
  shader painted 36. **Discount the TEXTURED triangles when repeating this**:
  a fixture window starts from a blank VRAM, so every textured draw discards
  on texel 0 and counting it as cover overstates the defect. Against the
  geometry the shader can actually paint the figure is **299, and it is 0
  after the fix** — the residual 136 in the all-triangles count is entirely
  textured cover the shader legitimately holes.
- **Gate 2 looked like it forbade the fix, and that reading was wrong — the
  mistake is worth more than the fix.** Refusing a sliver is CORRECT at 1x, and
  `readbackNative()` samples exactly the top-left subtexel, so letting a sliver
  paint AT THE LATTICE breaks downsample-invariance and the sliver rule
  together. From that it was concluded that strict parity and hole-free
  upscaling of a sub-pixel mesh are "incompatible". They are not: the
  conclusion silently generalised "let slivers paint" from the lattice, where
  the oracle looks, to the `s^2 - 1` subtexels where it does not and never
  did. Refusing at the lattice and painting off it satisfies both at once.
  **When an invariant appears to forbid a fix, check what it actually
  constrains before recording the impossibility** — this one cost a day and a
  handoff document.

**A running `Substation.app` makes the suite fail, and it presents exactly like the
crash below.** The test host and an app launched from `zig-out` share a bundle
id; with one already running, a full run died twice in a row at 62 and 112
tests, then passed 352/352 the moment it was quit. `pkill -x Substation` before
re-running anything.

**The Swift suite crashes the test process under sustained scale-8 load, and
it reads as a test failure.** Once `zig build fixtures` has run, four
previously-skipped fixture gates turn on and a full run goes from ~90 s to
~4.5 min of near-continuous GPU work. Two runs in five died mid-test with no
recorded expectation failure at all — the victims differed each time
(`twoTrianglesSharingAShallowEdge…`, `theMoverFixtures…`, and once
`aSidecarIsFoundForARawBinToo`, which touches no GPU), and every one of them
passed on its own. **The tell is `Failing tests:` with zero `✘` lines**; a
real failure prints the expectation. Re-run before believing it.

**`HazardTracker`'s rule is symmetric, and the second half arrived late.** A
read during a render pass resolves against device memory; a write during that
same pass reaches device memory only when its tile is stored. So a draw that
WRITES what an earlier draw in this pass SAMPLED is exactly as unordered as
the reverse, and until 2026-08-30 only the reverse was tracked. It presents
as a RACE, not as a stable wrong pixel — frame 6 of `synthetic-primitives`
hashed three different ways across three runs of one binary once a Phase C
shader edit perturbed scheduling, and correctly and stably before it. Read
rects are kept as a LIST where written rects are unioned, and that is worth
50x: a sampled rect is a whole 256-row texture page, so unioning two distant
pages covers most of VRAM and nearly every later write then intersects it —
over `silent-hill-usa`, 244 passes before, 266 with the list, 13,767 with a
union.

**The two opt-in Metal gates are switched by a FILE, not an environment
variable.** `zig-out/fixtures/PS1_DUMP_SCALED` (holding N) writes the
comparison PNGs and `zig-out/fixtures/PS1_SCALE_TIMING` prints the per-scale
replay cost. That is forced, not chosen: the shared scheme's TestAction
carries `shouldUseLaunchSchemeArgsEnv`, and the hosted test process sees
neither an exported variable nor one passed with xcodebuild's `TEST_RUNNER_`
prefix — verified with a probe that printed an empty environment for both.
`zig-out/` is gitignored, so a marker cannot be committed by accident. Run
them with `-parallel-testing-enabled NO`: swift-testing otherwise runs them
beside the scale-8 comparisons, and the GPU contention both skews the timing
and intermittently fails the run.

