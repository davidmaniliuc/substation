---
name: ps1-gpu-metal
description: Use when touching ps1-core/src/gpu/ (rasterizer, gp0, renderer, vram, the command-stream sink/recorder), the Metal backend (Rasterizer.metal, MetalRasterizer, MetalVram, PrimBuilder, PrimEncoders, HazardTracker, LiveRenderer, StreamQueue), .p1fx fixtures, or internal resolution / upscaling. Covers the integer edge-function rules, dithering, the oversized-primitive drop, GPUSTAT bits, mask bits, the live command-stream path, the scaled-path gates and their blind spot.
---

# GPU + Metal renderer

**GPU** (`gpu/`): ABGR1555. **The triangle path is an integer edge-function
rasterizer with a top-left fill rule and exact integer interpolation of every
per-pixel attribute (Gouraud colour, texcoord, texture modulation): no `f32`
anywhere in the inner loop.** The formulas are shared with the Phase B Metal
backend by design (Metal Renderer Design, Phase 0): don't "optimise" them back
into float, or into incremental/stepped fixed-point, even though either would
be a cheaper CPU implementation on its own. **`drawShadedLine`'s gradient is
the same deal**: `c0 + floor((c1-c0)*k / steps)`, evaluated from the step
index `k` rather than accumulated, also not to be turned back into float or a
DDA. **Dither offsets, wherever added (Gouraud, texture modulation, the
shaded-line gradient), are 8-bit channel units**, added to the channel at
8-bit scale and clamped to `[0, 255]` *before* the `>> 3` down to 5 bits:
misreading them as 5-bit units is the bug `e4ceec7` fixed. `e4ceec7` also
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
wherever it is black**; modulating by black is black, and these primitives
are usually additively blended, so the black half of the mesh vanishes and
leaves triangular HOLES. That is what Crash Warped's title glow was: a soft
halo rendered as a starburst of hard blue shards. **Avocado is an oracle here**
(`render_triangle.cpp`: `c = c * colorInterpolated` under `isGouraudShaded`,
`c * colorFlat` otherwise), so diffing against it would have found this. And
the whole `.p1fx` corpus agreed on every hash throughout, because nothing in
it carried a Gouraud-textured primitive at all: **frame 7 of
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
horizontally or >=512 vertically is dropped, not clipped** (the check sits in
`rasterizeTriangle` (per triangle, so each half of a quad is judged separately),
in both line paths, and in both rectangle paths) the GP0 rectangle size field
is 16 bits, so nothing else bounds it. Matches Avocado's
`render_triangle.cpp:214` / `render_line.cpp:24` / `render_rectangle.cpp:17`. This is load-bearing, not a micro-optimisation: geometry
crossing the near plane projects to screen coordinates that saturate at the
GTE's +-1024 SXY clamp, and hardware refusing to draw the result is the only
thing keeping it off screen. Games do not clip it themselves. Without the rule
Silent Hill's roadside foliage sweeps across the camera in the opening street:
about 110 triangles per 4 frames there are oversized, and every one of them was
being painted. Pinned by four tests in `gpu_test.zig`. Scanout uses the **programmed display area**
(`disp_env.screen_x1/x2`, `screen_y1/y2` → `getVisibleWidth/Height`), not the
nominal mode size. Every VRAM write except Fill Rectangle honours the GP0(E6)
mask bits: drawn pixels via `putPixel`, CPU->VRAM and VRAM->VRAM transfers via
`Vram.maskedWrite`. Fill Rectangle is unmasked **on purpose**: hardware ignores
E6 there. Bit15 of a drawn pixel is the **source** pixel's own bit15 (a textured
primitive's texel STP bit, 0 when untextured) OR'd with GP0(E6).bit0, and blending
carries it through, never clear it, games leave STP-set texels in VRAM
specifically to mask later check-mask draws (Silent Hill brackets its player that
way). VRAM transfers are a stateful multi-word FSM: a bug there silently swallows
real commands. A textured **polygon** latches its texpage word back into
GP0(E1) so GPUSTAT reflects it; a textured **rectangle** does not, because it
reads the current texpage rather than carrying one. GPUSTAT bit 15 is the E1
texture-disable bit, *not* GP1(09)'s "texture disable is allowed" latch.
Three more GPUSTAT bits are easy to get wrong: **bit 13 is hardwired to 1**
(it is the interlace field, not a PAL flag), **bit 27 is `readMode == Vram`**
(true only while a GP0(C0) transfer is in flight, so GPUREAD reports the
register once it drains and GP1(00) must not re-select VRAM), and **bit 25's
DMA request depends on the programmed direction** (off for 0, on for 1 and 2,
a mirror of bit 27 for 3).

**`gp0.zig` cannot reach the renderer.** Every VRAM-visible effect goes through
`gpu/sink.zig`, which builds a fixed-stride `command.Command` and hands it to
`command.execute`: the one function that turns a record into an effect, used by
the live path and by replay alike. The seam exists so the Metal backend can
consume an ordered stream, and the structural guarantee is the missing import: a
primitive that does not appear in the sink does not draw. **The stream must carry
the implicit texpage latch, not just E1-E6**: `e1_texpage_mask` covers bits 5-6,
the semi-transparency mode, so a textured polygon's blend mode comes from its own
tpage word; rectangles do not latch. **A record carries every input the effect
needs and nothing may be re-derived at replay time**, which is why the three
Gouraud modulation colours ride in `v[i].color` rather than being reconstructed
from `value`. Which core module records is a comptime
build option (`gpu_sink`), `.software` everywhere except `ps1-golden`, the two
ROM suites, and (since Phase D1) `ps1-capi`, so the macOS app and `capi_test`
build `.dual` too; `Recorder.enabled` is a further runtime flag, so
`capture`/`verify` stay at today's speed. The recorder's capacities (`max_records`,
`max_payload_words`) are sized off the peaks `stream-verify` prints: it prints
them on success too, for exactly that reason.

**The fixture bridge is how Metal gets tested at all.** Metal runs only under
`ps1-macos/test.sh`; the ROM suites run only in Zig. `zig build fixtures`
writes `.p1fx` files (a header, a frame table, 96-byte records and a payload
blob) that Swift reads through `FixtureFile`. **The record type is declared
in `ps1-capi/include/ps1.h`, not mirrored in Swift**, because Swift does not
guarantee C-compatible struct layout; the header's `record_stride` and
`kind_count` are checked on load so a field or a `Kind` added on the Zig side
fails loudly instead of shearing every record. The hash is **FNV-1a 64, not
the trace harness's Wyhash**: Wyhash is a std-library implementation that can
change across Zig releases, and a file format pinned to it would break on a
toolchain upgrade while presenting as "Swift disagrees with Zig". Payload
offsets are **frame-relative**: a `vram_write_data` record's `.x` indexes its
own frame's run, exactly as `command.replay` reads it. Only the committed
synthetic fixture has its VRAM hashes verified (`ShadowVram` models the
memory movers, never the rasterizer), so the PL and Croc fixtures are
structurally checked and otherwise banked for Phase B. **Sixteen of each
PeterLemon fixture's seventeen frames are empty and repeat frame 0's hash**:
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
`UserDefaults`. It is a **submenu**, matching Machine ▸ Change Disc (eight
scales spread flat over the Video menu bury the one other entry under them),
but it stays a `Picker` (`.pickerStyle(.menu)`) where Change Disc is a `Menu`
of `Button`s, because a scale is a preference and gets the system's checkmark,
where a disc swap is an action per item and draws its own. The menu attaches
⌘1…⌘8 via `.keyboardShortcut` on each `Picker` option's `Text` in
`VideoCommands.swift` (not a documented SwiftUI contract, only a type-check,
and now inside a submenu besides), so treat the accelerators as unverified
until someone confirms them by eye; a plain `Button` per scale is the fallback
shape if they don't show up in the menu.
`ContentView` keys `.id()` on the runner's identity AND the scale, so a change
rebuilds the coordinator, its pipelines, its `LiveRenderer` and its `MetalVram`
through exactly the path a disc change already uses.
**`Video ▸ Dithering` is the counter-example, and the distinction is the point**:
it is a runtime uniform on a pipeline that is already built, so it is NOT part
of that `.id()` and rides `updateNSView` down to `LiveRenderer.ditherMode`
instead. Three flat entries, no accelerators, no submenu. `DitherSetting`
reads `object(forKey:)` where `InternalResolution` reads `integer(forKey:)`,
and that difference is load-bearing: 0 is outside the resolution range so the
clamp lifts a missing key to the default, but 0 is a VALID dither mode
(`.off`, the worst-looking of the three), so `integer(forKey:)` would report
every fresh install as having deliberately chosen it.
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
(`HazardTracker`): on a tile-based GPU such a read returns pre-pass contents,
so without the split it is silently stale. `synthetic-primitives.p1fx` is the
per-feature gate ladder, committed, one feature group per frame in a fixed
order that the Swift tests index by number; append to it, never reorder it.
**The texel HOLE is decided on the RAW texel, before modulation, and the
sampled colour must not travel back through the same value.** `TexturedShader.shade`
(`gpu/shaders.zig`) returns `.draw = false` only for a raw texel of 0; a non-zero texel that
modulation maps onto 0x0000 is drawn BLACK (the modulation branch just below it). Until
2026-08-30 `ps1_sample` returned the modulated colour and reused 0 as the hole
sentinel, so every such pixel was discarded and whatever was already in VRAM
showed through: a green speckle over the dark parts of Croc's rock, door and
crate. It now returns a bool with the colour in a `thread ushort&` out-param,
the shape `ps1_triangle_coverage` already used. Two things about it are worth
remembering. **Dithering makes one bug look like two**: its offset is in 8-bit
channel units and is applied at 1x only, so a marginal channel is pushed under
8 (and `>> 3` to 0) in a speckled pattern at 1x and left alone above it; the
crate's speckles vanish at 8x while the door's, whose un-dithered value is
already 0, do not. **The whole fixture corpus agreed on every hash throughout**,
because nothing in it modulates a texel to zero; a hand-built test
(`aTexelThatModulatesToBlackIsDrawnRatherThanDiscarded`) is what pins it, not
the gate ladder.
**A primitive that samples its OWN destination is the one shape no GPU
backend can reproduce, in any phase.** The software rasterizer scans row by
row, so a triangle whose texture read lands on pixels it has already drawn
sees the new values deterministically, and that determinism is baked into
every hash it produced. Nothing orders fragments *within* one primitive on a
GPU, so `HazardTracker` (which orders one draw against the next) does not
help and never will: it is a divergence class, not a bug to chase. Frames 2
and 4 of `synthetic-primitives.p1fx` contained it by accident and were
relocated below every read address they can generate (`f4db802`, `1a74e02`);
frames 0-5 now hold that invariant by construction, and frame 6's
*inter*-primitive feedback is the deliberate case `HazardTracker` exists for.
Expect this to resurface in Phase D as a real game diverging on a handful of
pixels with no explanation in the encoder.

Seven things about the live path are load-bearing. **`ps1_take_frame_stream` is a
DRAIN, not a peek**: it resets the recorder, so it must be called exactly once
per `ps1_run_frame`, and a frame left untaken stacks onto the next until the
capacity overruns. **`complete == 0` means the records are a PREFIX**, so the
stream is discarded and the renderer resyncs from the shadow rather than
replaying it. **VRAM is published before the stream, under the same seq**, so a
shadow sampled at seq `S` accounts for every frame up to and including `S` and
for none above it, which is why a resync discards **only the slots at or below
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
presentation does**: a command stream is a set of incremental mutations, unlike
the idempotent VRAM snapshot the shadow path publishes. And **24bpp scans out of
the 1x shadow permanently**, because it byte-packs across adjacent 16-bit words
and that arithmetic cannot survive N x N replication; Croc and Silent Hill both
depend on it.

**"The texture is not a picture of anything" and "a frame never arrived" are
two conditions, not one, and conflating them is what made the picture flicker
between 8x and 1x** (fixed 2026-09-03). `StreamQueue` carries `resync` for the
first and `dropped` for the second. Only `resync` may be answered by adopting
the shadow: it means a BLANK `MetalVram` (a fresh queue, a scale change, a
disc change, the coordinator's unconditional request), where there is no
picture to preserve and skipping leaves the window black until something
repaints all of VRAM, which for a static backdrop is never. `dropped` says the
opposite: the texture is a faithful picture of every frame that DID arrive, and
one that did not has no records to execute anyway. The choice there is not
whether to run the lost frame, nothing can, but whether to answer its absence
by throwing the scaled picture away, and **above 1x that is exactly what
adopting the shadow does**: `uploadNative` replicates a NATIVE image N x N, so
the whole frame drops to nearest-neighbour 1x until the game repaints it. At 1x
it is still adopted, because there `uploadNative` IS `upload`: exact, one
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
`vram_write_setup` at (256, 493) (the menu's palettes) with 384 payload words
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
lost. **A deficit that never lifts is still not repaired**: no policy here
both keeps the scale and stays correct, and the remedy there is a lower
internal resolution. `aLostFramesMutationIsRepairedOnceTheDropsStop` pins it,
verified to fail at 2/3/4/8x against `fab1138`; the three tests that pin the
halves which must NOT change all still pass unaltered.

**The renderer falls behind at 8x on real content, and that is a measurement,
not a suspicion.** Per frame at 8x, replayed through gate 4 on this machine
(Debug host): silent-hill 28.5 ms, "crash-warped" 11.1 ms, against a 16.7 ms
budget at `preferredFramesPerSecond = 60`. **That second fixture name has no
provenance and should not be trusted**: `crash-warped` is not a `.p1fx` in
this repo, is not in Gate 4's corpus and the string has never appeared in
`MetalScaleTests.swift` in any commit (`git log -S`), so whatever produced
11.1/8.2 ms was not Gate 4. The second fixture in Gate 4's pair is
`tr1-usa-v1-1`; treat these two figures as a silent-hill number plus an
unsourced one. Two things followed. `MetalRasterizer` now **cycles its
persistent buffers over three slots** (`FrameBuffers`,
matching MTKView's triple-buffered drawables) instead of blocking the next
`beginFrame` on the previous frame's completion. That old wait was correct
(commit order orders GPU work against GPU work, never a CPU write against an
in-flight GPU read), but it serialized encode against execute, so per frame the
cost was CPU + GPU rather than max(CPU, GPU) and, the part that mattered,
draining a backlog of N frames in one callback cost N full frames back to back,
which is a renderer that has fallen behind guaranteeing it stays behind.
Cycling took 8x to 18.6 ms on silent-hill (the 8.2 ms pair figure carries the
caveat above).

**A renderer that falls behind now STOPS THE EMULATOR rather than losing a
frame** (2026-10-05, DuckStation's model: its core thread blocks once
`gpu_max_queued_frames` are queued). Until then a full `StreamQueue` dropped the
frame, and above 1x the debt it left was settled by adopting the native
shadow: the "some frames render at 1x while upscaled" report. Measured live on
Crash at 4x on an M1 Air: callbacks spiking to 85-170 ms filled the 8-slot ring,
every burst ended in one or two adoptions, and each adoption cost ~45 ms on the
render thread, which fed the next drop. `StreamBackpressure` makes the emulator
thread poll before running a frame while the queue is full, the queue is 3
slots (latency, not drops, is now all depth buys), and after 250 ms of a
continuously full queue the renderer is treated as GONE (hidden window,
torn-down view) and frames drop as before until it drains once. Afterwards: 0
drops, 0 adoptions. The cost is real and measured: the GPU is now the speed
limit. Crash at 4x costs ~15-16 ms of GPU per frame on that machine (command
buffers in flight 1.5-1.8 s per second, i.e. saturated), so fast-forward at 4x
tops out at ~60-70 fps where it used to reach 3x by discarding ~70% of frames.
`dropped` and the repair debt remain for the three ways a frame is still lost:
a stalled renderer, an incomplete (overflowed) recording, an oversized frame.

Two environment switches, both debug-only and both read by the APP rather than
the test host (the marker-file scheme exists because the hosted test process sees
no environment; the app launched from a shell has an ordinary one):
`PS1_LIVE_DIFF=1` reads the render texture back each frame and logs the first
divergence against the shadow, and `PS1_SOFTWARE_DISPLAY=1` routes 15bpp back to
the shadow so a suspect frame can be A/B'd without a rebuild. Neither is a mode
and neither is a user-facing setting.
**A silent `PS1_LIVE_DIFF` run is not by itself evidence**: the oracle compares
only when the newest published frame is the one the texture holds, and it runs
after a `drain` that blocks on the GPU, so every frame the emulator publishes in
that window is skipped rather than compared. It therefore prints a running
`checked N frames, skipped M` tally every 300 decisions and once more on eject;
read that ratio before reading anything into the absence of divergence lines.

Four things about the SCALED display path are load-bearing. **The scanout wrap
is NATIVE, then scaled**: `((vram_x + nx) & 1023) * s + sub_x`, never
`& (1024*s - 1)`: a bitwise mask is a modulo only at power-of-two `s`, so at
`s = 3` a display window crossing the VRAM edge samples the wrong column. The
parent Metal spec specifies the mask form in two places; **it is wrong and must
not be implemented as written.** **Scaling the wraps alone is a no-op**: `px`
is derived from `p.width * p.scale`, and without that multiplication every
sample lands on its block's top-left subtexel, which by Phase C's exactness
property is byte-identical to the 1x picture: the player selects 8x, pays 67 MB
and sees nothing. **24bpp and the `PS1_SOFTWARE_DISPLAY` seam read the 1024x512
shadow at `nx`/`ny`, discarding `sub_x`/`sub_y`**: feeding them `px` breaks
every FMV in Croc and Silent Hill above 1x and nowhere else. And
**`MetalDisplayView.Coordinator.init` calls `requestResync()` unconditionally**,
because a rebuilt `MetalVram` is a BLANK texture while a command stream is a set
of incremental mutations; `StreamQueue`'s `resync` flag defaults true, but that
covers a FRESH queue, and a scale change keeps the runner and therefore keeps
its queue. It is a CLAIM (`StreamQueue.claimConsumer`), not a bare
request, and a superseded coordinator's `draw` returns at once (`ownsStream`):
the queue's flag is shared, so the view being replaced could get one more draw
callback after a rebuild, consume the new texture's resync and leave it
replaying onto a blank VRAM. Texture pages are uploaded once per level, so
every textured polygon then sampled texel 0 and vanished while untextured
geometry drew normally: Crash 1's level disappearing after the depth buffer
was toggled off, 2026-09-27.

**The default is 1x, and that is a testability decision.** 1x is the only scale
with a per-frame byte-exact oracle on arbitrary content (the software shadow is
a reference for whatever is actually being played), and above it the check
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
viewport size: none of the three reads the renderer, the display area or the
scale. Internal resolution changes how finely the render texture is sampled, not
the dimensions of the picture or of the window.

**`PS1_LIVE_DIFF` works above 1x for free, and it is the only coverage there
outside the fixture corpus, but expect it to be loud.** `LiveRenderer.diff`
reads `vram.readbackNative()`, which is already the top-left-subtexel view at
any scale, so at N the oracle becomes a live downsample-invariance check on
real games. It shares that role with a second, expected divergence class, and **which
divergence to expect now depends on the player's dither mode** (below). At
the shipped `.scaled` a real game at 2x/3x/4x prints a divergence line on
essentially every dithered 3D frame the oracle checks, because the shadow
indexes the table by the native pixel and the shader indexes it by the
subtexel: that is by design, not a scale bug. At `.native` that class
disappears entirely and the oracle is as quiet above 1x as it is at 1x, which
makes `.native` the mode to switch to before reading anything into a run. The
signal worth reading a `.scaled` run for is a divergence that is *not* a ±1
single-channel difference spread over a gradient; that shape is the dithering
class, already accounted for. Its `checked/skipped` tally still has to be read
before an absence of output means anything.

**Internal resolution is a runtime uniform, and every RECORD stays native.**
`Ps1PrimInstance` is in 1024x512 units at every scale: the vertex shader
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
is the one read that is not reduced to native**: it carries `sub_x`/`sub_y`
so a VRAM->VRAM blit preserves scaled detail, and those terms are zero at a
top-left subtexel, so dropping them would pass every hash. Texture data is
never upscaled: a texel at `(u, v)` reads its block's top-left subtexel at
all three depths. **Where the dither pattern is SAMPLED is a player setting,
and it is the one knob in the rasterizer that is a matter of taste**: decided
in the shader from `uni.dither_mode` and never by clearing the flag in
`PrimBuilder`, which would make the record differ between modes. The
gate is **downsample-invariance**: taking each block's top-left subtexel
reproduces the 1x image byte-for-byte over the whole 1024x512, on every
frame of all eleven fixtures, at N in {2,3,4,8}; **3 is in that list on
purpose**, since `/ s` and `% s` are shifts and masks at every power of two
and a `>> log2(s)` bug is invisible at 2, 4 and 8. Measured, the scale-8
pass over both 100-frame geometry fixtures costs 2.9 s, so nothing narrows.
Nothing display-side scales yet (the scanout wrap, 24bpp, the scale picker);
that is Phase D2.

**Dithering used to be OFF above 1x, and the reason given (that it is the
single exception to downsample-invariance) was true only of a pattern indexed
by the SUBTEXEL** (fixed 2026-09-12, reported as "the shadows look far rougher
than DuckStation" on Crash Bandicoot's sand). Without dithering a Gouraud ramp
is quantised straight to 5 bits, and a slow gradient over a large surface comes
out as wide hard-edged bands, which reads as a rasterizer defect and is not
one. `PS1_DITHER_NATIVE` indexes `ps1_dither` by `nx`/`ny`, handing every
subtexel of a native pixel that pixel's own 1x offset, so the top-left subtexel
reproduces the 1x answer exactly and **the gate holds with dithering ON at
every scale** (`aNativeDitheredReplayIsStillDownsampleInvariant`, the full
synthetic-primitives ladder at N in {2,3,4,8}). `PS1_DITHER_SCALED` indexes by
`px`/`py`: the finest pattern, the smoothest gradient, and the mode that really
does break the property; at the lattice too, since `px == nx * s` is congruent
to `nx` mod 4 only at `s == 1`, which is the trap that made the first version
of `scaledDitheringActuallyChangesThePictureAboveOneX` assert the opposite. It
ships as the default because at the shipped 1x the two are the SAME EXPRESSION,
so no Gate 1 hash can move and the choice only reaches a player who already
opted up. `PS1_DITHER_OFF` is what Gate 2 has always run at. Three things
follow. The mode is a **uniform**, for the reason `dither_off` was one: a flag
cleared in `PrimBuilder` would make the instance bytes differ between modes.
`Ps1RasterUniforms` is still 8 bytes, so the `static_assert` pair is unmoved.
And the offsets themselves are hardware while the coordinate that indexes them
above 1x is not: off the native lattice there is no hardware answer to
reproduce, which is the same reasoning that put the degeneracy clause at the
native sample point.

**Dithering could not close the gap, and the reason is arithmetic: it
redistributes quantisation error and cannot add levels** (true colour shipped
2026-09-12, against the same "the shadows look far rougher than DuckStation"
report). Every fragment passed through `ps1_pack`'s `>> 3` into a 16-bit
texture, so a Gouraud ramp had 32 stops per channel at every internal
resolution while DuckStation renders at 256 and ships **with dithering off**
(`settings.h:230`), emulating the 5-bit truncation in the shader only when true
colour is off (`gpu_hw.cpp:3448`). DuckStation can do that because its VRAM
*is* `RGBA8`, and it pays for it by sampling indexed texture data out of that
target and converting back down. We cannot: Gate 1's fixture hashes, Gate 2's
downsample-invariance and `PS1_LIVE_DIFF` all read VRAM and all require it
bit-exact.

So the eight-bit picture lives in a **display-only sidecar**: a second
`.rgba8Uint` texture, scaled like the render texture, written by the same
fragment invocation as `[[color(1)]]` and read only by `display_fragment`.
Texel fetch still reads `r16Uint`, so on that axis this is **more** accurate
than the reference. Five things are load-bearing:

- **Alpha is presence, per pixel**, and it replaces bookkeeping rather than
  adding some: DuckStation needs `m_vram_dirty_draw_rect` and
  `m_vram_dirty_write_rect` to tell GPU-drawn regions from CPU-written ones,
  and the alpha channel answers the same question exactly at rect boundaries
  for free. An absent pixel falls back to `c << 3 | c >> 2`, which is today's
  picture, so every invalidation degrades to the current behaviour rather than
  to a visible defect. `display_fragment`'s `unpack1555` was changed from
  `c / 31.0` to that same replication for exactly this reason: a one-level
  disagreement between the two expansions draws a seam along the boundary of
  every uploaded rect.
- **The residual encoding was considered and does not survive blending.** The
  cheaper shape: keep the low three bits per channel in an `r16Uint` sidecar
  and reconstruct as `vram << 3 | residual`: fails because a 5-bit blend is not
  the truncation of an 8-bit blend: `ps1_blend`'s integer halving differs from
  the same operation at eight bits by up to an LSB per layer, and after one
  transparent draw the two representations no longer reconstruct each other with
  no way to say so. A full parallel picture is *permitted* to drift sub-5-bit
  because nothing compares it.
- **The copy is one pass with two attachments**, never two passes. VRAM->VRAM
  copies wrap at the VRAM edges and self-overlap (DuckStation chunks an
  overlapping copy by rows (`gpu_hw.cpp:3660`) precisely because the ordering is
  observable), and a sidecar copied separately can resolve an overlap
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
- **The MODULATION had to be widened too, and shipping without it left the
  reported scene nearly unchanged** (fixed 2026-09-13, same report a third
  time). `ps1_modulate` crops its shade to five bits before multiplying
  (exactly DuckStation's `MODULATION_CROP`), so a textured surface's lighting
  ramp reached the sidecar with **17 distinct levels** over a full sweep at a
  bright texel, in steps of 16: *coarser* than the five-bit banding the sidecar
  exists to remove. Only untextured Gouraud draws ever saw 256, and they are
  **22.4%** of a real Crash frame against **77.5%** modulated textured triangles
  (`crash-bandicoot-warped.p1fx`, 28,036 against 8,116, and zero textured
  rectangles). VRAM keeps the crop; `out8` now takes the uncropped eight-bit
  shade, `(t5 * c8) >> 4`, which is DuckStation's true-colour `>> 7` written for
  a five-bit texel and measures 133-256 levels with a max step of 2. The two
  **agree exactly wherever the shade is five-bit exact** (at `c8 == c5 << 3`,
  `(t * c8) >> 4` IS `(t * c5) >> 1`), so it is a refinement between VRAM's own
  levels, not a second opinion about them. A textured RECTANGLE is deliberately
  unmoved: `gp0.zig` calls `Color.getColor16` before the sink and `Command` has
  nowhere else to put a 24-bit colour, so the sprite path passes `c5 << 3` and
  reproduces its old value bit for bit. Nothing in the corpus would have caught
  this: `aGouraudRampKeepsMoreThanThirtyTwoLevelsInTheSidecar` uses an
  UNTEXTURED triangle, and
  `aModulatedTexelKeepsMoreThanThirtyTwoLevelsInTheSidecar` is the rung that
  now gates the other 77.5%.

- **It is the default at every scale, 1x included, and that is not a relaxation
  of the testability rule that kept 1x the default resolution.** `.trueColor`
  writes VRAM byte-identically to `.off`, so no hash can move; `.scaled`
  knowingly trades Gate 2 above 1x and this trades nothing.
  `theCorpusRendersIdenticalVramInTrueColourAndOff` is the assertion, over both
  synthetic fixtures frame by frame.

**The Silent Hill "fog is rougher than DuckStation" report was `.native`
DITHERING SELECTED, not a defect** (2026-09-13). Measured over the fog region
of three same-scene captures, high-passed to isolate fine detail: `.trueColor`
**sd 1.25** with no coherent lattice, `.off` sd 1.97, the cross-hatched shot
**sd 4.66 with a lattice at period 6.50 px and phase coherence 0.82**, and
DuckStation **sd 0.84**. That picture was 1041 screen px for a 320-px display
(3.253 px per native pixel), so 6.50 px is exactly **2.0 native pixels**, the
period-2 sub-harmonic of the 4x4 table indexed by `nx`/`ny`. `.scaled` would
have given 3.25 px and `.trueColor` no lattice at all. DuckStation was on
nearest-neighbour filtering, so it had no smoothing advantage; at `.trueColor`
this scene is at parity and the mode was doing exactly what `DitherMode.swift`
says it does.

Two things are worth more than the conclusion. **A single DFT peak is not a
lattice: check PHASE COHERENCE across separated patches before calling
anything periodic.** Two hypotheses died here because a peak at ~6.4 px in a
broad noise spectrum was read as a dither pattern; the phases were 4.3, 3.9,
2.0, 3.6, 6.3 and the amplitude collapsed from 1.34 to 0.15 in narrow windows,
which says broadband noise. The coherence test that identified the real lattice
is the one that should have run first. And **a screenshot is a poor instrument**:
it is a resampled capture of differently-sized windows, and channel correlation
cannot separate quantisation noise from texture detail on a near-grey image,
because a grey ramp quantises all three channels together.

It also means **Milestone 2's benefit on THIS scene is inferred, not measured.**
It was built believing the artifact was blend banding at `.trueColor`; it was a
mode selection. The 47.9%-of-draws-are-composites figure is real and the change
is tested and free, but nobody has A/B'd true-colour Silent Hill with and
without it. Do that before quoting it as the fix for anything.

**Two consequences that read as regressions and are not.** `PS1_LIVE_DIFF` is
now as loud at the shipped default as it is at `.off`, because the software
shadow dithers and true colour does not: `.native` is still the mode to switch
to before reading anything into a run, exactly as it already was above 1x. And
**Gate 1's harness had been inheriting `DitherSetting.defaultMode`**, which was
harmless only because `.scaled` and `.native` are the same expression at 1x;
`MetalFixtureHarness.replay` now pins `.native` itself, and
`gateOneRunsAtADitheringModeRatherThanThePlayersDefault` keeps it pinned by
showing that the same replay at `.trueColor` diverges on purpose.

**Milestone 2 (the eight-bit blend path) SHIPPED 2026-09-13, and the scene
that gated it is Silent Hill's fog.** The gate was "find one scene that bands
*because of* layered blending", on the reasoning that most PS1 "fog" is GTE
depth cueing baked into vertex colour (a single Gouraud draw), and that the
composited case was only *assumed* to exist because later hardware works that
way. That reasoning was right about most games and wrong about this one.
Measured over `silent-hill-usa.p1fx`: of 86,285 recorded draws, **47.9% are
semi-transparent** (38,724 textured triangles plus 2,550 shaded, against 44,921
opaque), so about half the picture is a stack of composites and every layer of
it re-quantised to 32 levels. `ps1_blend8` is the same four modes and the same
integer shapes at eight bits; the background comes from the SIDECAR through tile
memory (`dst_side [[color(1)]]`: both attachments already load and store), and
falls back to `ps1_expand(dst)` exactly where `display_fragment` does, so a
region whose presence was invalidated composites onto the colour the player is
actually looking at. Three things are load-bearing. It is **gated on
`.trueColor`**, not applied unconditionally: in the three dithering modes the
sidecar's whole job is to hold precisely what the display would have expanded
from VRAM anyway, and an eight-bit composite there would quietly smooth a
picture the player asked to be five-bit; `aBlendedDrawStillFallsBackToFiveBitsOutsideTrueColour`
is that half, and it is the test to read before "simplifying" the branch away.
It is **not a refinement of `ps1_blend`** the way the widened modulation is a
refinement of the cropped one: mode 0's halving and mode 3's quarter each drop
a bit that eight bits keep, so a composite drifts from VRAM by up to an LSB per
layer, which is the whole point and is affordable only because nothing compares
the sidecar. And it is **free**: Gate 4 puts `silent-hill-usa` at 8x at
**33.7 ms/frame** against the 33.3 ms sidecar baseline below, and at 4x at
14.7 ms. `aBlendedDrawStillFallsBackToFiveBitsInMilestoneOne` is GONE, replaced
by `aBlendedDrawCompositesAtEightBitsInTrueColour`: it existed to be changed,
and changing it is what "milestone 1" meant.

**Cost, measured.** The sidecar doubles the render-target allocation: 2 MB at
1x, 18 MB at 3x, 134 MB at 8x, and the copy scratch pair the same again.
Gate 4 at 8x after the change: `silent-hill-usa` **33.3 ms/frame**, against its
18.6 ms baseline above; **1.79x**, past the ~1.3x a second colour attachment's
tile-store bandwidth alone would predict. That is a real, sizeable regression
at 8x and the number is written down plainly rather than softened; the remedy
is the player's internal-resolution setting, not a revert. `tr1-usa-v1-1` at 8x
measured **8.2 ms/frame**. It has no trustworthy prior baseline: the 8.2 ms
attributed to `crash-warped` earlier in this file is unsourced (see the caveat
there), so whether that digit match means "tr1 did not regress at all" or
nothing at all is **open**. Do not quote a tr1 regression ratio until a
pre-sidecar tr1 figure is measured at `4a64c99` (the last commit before
`522b892` added the sidecar texture); silent-hill's 1.79x is the only sidecar
cost in this file with both ends measured.

**That gate has one BLIND SPOT, and it is where the scale bugs live: it only
ever looks at top-left subtexels.** `readbackNative()` is the top-left
subtexel of each block, and at a top-left subtexel the sample point IS the
native pixel, so anything a fragment shader decides from `px`/`py` reproduces
its 1x answer there by construction and both gates pass whatever the other
`s*s - 1` subtexels do. Gate 2b's coverage ratio is a whole-frame average and
a corpus of mostly-large primitives dilutes a small-primitive defect away.
That is how `ps1_triangle_coverage`'s degeneracy clause ("and not all three
zero", written as `b_i < PS1_Q_BIAS_SCALE`) shipped evaluated at the SUBTEXEL
when it is a statement about a whole native pixel. The three terms sum to the
twice-area, so it fires for any triangle under 1.5 native px^2; above 1x the
terms stop being multiples of `PS1_Q_BIAS_SCALE` and the band around the
CENTROID, where all three are smallest, is refused while every subtexel nearer
an edge is kept. **A small triangle came out as a RING** (2 lost subtexels of
20 at 4x, 12 of 72 at 8x), and a distant character model, whose facets are all
about a pixel across, as scattered rims with the scene showing through
(reported on FF7's Cloud at 8x, 2026-09-02). The fix went through two wrong
shapes before landing (see the two paragraphs below), and is now simply that
the clause is asked at the native sample point and nowhere else.
The lesson generalises: **a new scaled-path test must assert something about
the interior of a block, not only its corner.** The one that caught this
(`aSmallTriangleIsSolidRatherThanHollowAtEveryScale`) asserts no unpainted
subtexel is enclosed by painted ones.

**Two earlier fixes are GONE, and the tests they left behind outlive them.**
Both tried to answer the clause per native pixel and hand the whole BLOCK that
answer; both rescued only the pixel's *owner*, since a non-owner's native
sample point lies outside it by definition, so every other facet covering that
pixel was refused there outright and a mesh of ~1px facets is nothing but
neighbours. Three tests pin the shapes that had to be got right along the way:
`aSmallTriangleIsSolidRatherThanHollowAtEveryScale` (no enclosed hole),
`aSubPixelMeshKeepsEveryNativePixelOneXPaints` (a mesh's hole reaches the
silhouette, which a single-triangle test cannot see) and
`aSubPixelFacetPaintsItsShareOfAPixelALargeNeighbourOwns` (the mixed case: a
large facet owns the pixel and paints only its own share, so the sub-pixel
facets covering the rest painted nothing at all).

**The clause is now asked at the NATIVE SAMPLE POINT and nowhere else**: that is
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
  every fragment is a native sample point, so Gate 1 cannot move either, and
  it did not: `ff7-mako-off` frame 6 at 1x is byte-identical before and after.
- **No `area` guard is needed and none is there.** `renderer.zig` asks the
  clause of every pixel unconditionally; the terms summing to the twice-area is
  what stops it firing on a large triangle. The old large path skipped it on
  that reasoning, which was sound but left the shader's structure saying
  something the reference does not.
- **A genuine sliver is still refused at every native sample point at every
  scale**, which is the half of the rule upscaling must not quietly undo, and
  `subPixelSliversAreRefusedAndPaintedIdenticallyAtEveryScale` still pins it:
  it asserts on `.native`, which IS the lattice. A sliver does now paint the
  off-lattice subtexels it covers. That is the price, it is 1/s^2 of a pixel
  apiece, and it is visible in the measurement as a handful of isolated
  unpainted lattice points inside otherwise solid geometry: 7 over Cloud's
  whole 30x30 native box at 8x, 5 of them on the lattice.
- **Blockiness was a consequence, not a goal.** A sub-pixel facet now paints
  its true share of every pixel it touches, so a mesh of them upscales as a
  mesh. What it costs is the over-paint the old rule added: on FF7's Cloud at
  8x, 303 subtexels that no paintable triangle covers lost their fill, against
  299 covered ones regained; a net 4 fewer painted subtexels and a silhouette
  that follows the geometry instead of the pixel grid.

**The FF7 "Cloud is full of holes at 8x" report was NOT one of the shapes
above, and not PGXP either: it was the degeneracy clause deleting real geometry at scale.
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
  the right answer: PGXP moves a vertex by a FRACTION of a pixel, so at 1x both
  sides of a crack round into the same pixel and nothing shows. Only a control
  at the SCALE the artifact appears at can rule anything out. (FF7 resolves
  98.3% of 1.3M vertices there, `mixed=0`: coverage was never the problem.)
- **A field character model is made of SUB-PIXEL facets.** Cloud is ~25 px tall
  and carries 232 triangles in that box: twice-areas of 0 (24 of them), 1 (88),
  2 (43), 3 (13), 4 (13), 5 (33), 6 (14), and four above. **67% are under 1.5
  native px^2** (the band the degeneracy clause governs), and 88 are the
  twice-area-1 "genuine sliver" that `subPixelSliversAreRefusedAndPainted…`
  requires be refused at EVERY scale.
- **The holes were geometry the clause deleted, not geometry that is absent.**
  Over the model's 1x-painted blocks at 8x: 4,989 subtexels painted, 643 not.
  Of those 643, **387 were covered by a triangle** and refused; only 256 were
  genuinely outside all geometry (ordinary silhouette refinement). Checked by
  re-implementing the shader's edge functions over the fixture's own records:
  on the worst pixel, all 64 subtexels are covered by some triangle and the
  shader painted 36. **Discount the TEXTURED triangles when repeating this**:
  a fixture window starts from a blank VRAM, so every textured draw discards
  on texel 0 and counting it as cover overstates the defect. Against the
  geometry the shader can actually paint the figure is **299, and it is 0
  after the fix**: the residual 136 in the all-triangles count is entirely
  textured cover the shader legitimately holes.
- **Gate 2 looked like it forbade the fix, and that reading was wrong: the
  mistake is worth more than the fix.** Refusing a sliver is CORRECT at 1x, and
  `readbackNative()` samples exactly the top-left subtexel, so letting a sliver
  paint AT THE LATTICE breaks downsample-invariance and the sliver rule
  together. From that it was concluded that strict parity and hole-free
  upscaling of a sub-pixel mesh are "incompatible". They are not: the
  conclusion silently generalised "let slivers paint" from the lattice, where
  the oracle looks, to the `s^2 - 1` subtexels where it does not and never
  did. Refusing at the lattice and painting off it satisfies both at once.
  **When an invariant appears to forbid a fix, check what it actually
  constrains before recording the impossibility**: this one cost a day and a
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
recorded expectation failure at all: the victims differed each time
(`twoTrianglesSharingAShallowEdge…`, `theMoverFixtures…`, and once
`aSidecarIsFoundForARawBinToo`, which touches no GPU), and every one of them
passed on its own. **The tell is `Failing tests:` with zero `✘` lines**; a
real failure prints the expectation. Re-run before believing it.

**`HazardTracker`'s rule is symmetric, and the second half arrived late.** A
read during a render pass resolves against device memory; a write during that
same pass reaches device memory only when its tile is stored. So a draw that
WRITES what an earlier draw in this pass SAMPLED is exactly as unordered as
the reverse, and until 2026-08-30 only the reverse was tracked. It presents
as a RACE, not as a stable wrong pixel: frame 6 of `synthetic-primitives`
hashed three different ways across three runs of one binary once a Phase C
shader edit perturbed scheduling, and correctly and stably before it. Read
rects are kept as a LIST where written rects are unioned, and that is worth
50x: a sampled rect is a whole 256-row texture page, so unioning two distant
pages covers most of VRAM and nearly every later write then intersects it;
over `silent-hill-usa`, 244 passes before, 266 with the list, 13,767 with a
union.

**The two opt-in Metal gates are switched by a FILE, not an environment
variable.** `zig-out/fixtures/PS1_DUMP_SCALED` (holding N) writes the
comparison PNGs and `zig-out/fixtures/PS1_SCALE_TIMING` prints the per-scale
replay cost. That is forced, not chosen: the shared scheme's TestAction
carries `shouldUseLaunchSchemeArgsEnv`, and the hosted test process sees
neither an exported variable nor one passed with xcodebuild's `TEST_RUNNER_`
prefix; verified with a probe that printed an empty environment for both.
`zig-out/` is gitignored, so a marker cannot be committed by accident. Run
them with `-parallel-testing-enabled NO`: swift-testing otherwise runs them
beside the scale-8 comparisons, and the GPU contention both skews the timing
and intermittently fails the run.

## Texture filtering (2026-10-02)

**Bilinear filtering is SIDECAR-ONLY.** VRAM, the hole (raw texel 0 discards)
and the STP bit are all decided by the NEAREST texel exactly as before; the
filtered colour reaches `color(1)` alone. That is forced by the same three
gates that shaped the sidecar: a filtered colour is not a value the console
can produce, and Gate 1, Gate 2 and `PS1_LIVE_DIFF` all need VRAM bit-exact
against the software rasterizer. The gate for it is
`theCorpusRendersIdenticalVramUnderBothFilters`: every fixture, every frame,
byte-identical VRAM under both filters. `MetalFixtureHarness.replay` pins
`.nearest`, as it pins `.native`, so Gate 1 never inherits a player default.
The setting is a runtime uniform (`texture_filter` in `Ps1RasterUniforms`),
not part of `ContentView`'s `.id()`.

**`u6 >> 6` is the nearest texel, taken at the CORNER.** `ps1_interp_attr` is
fed `u0 << 6` (and `v`), giving `u6` with six fractional bits; `u6 >> 6`
replaces the old truncated interpolant rather than sitting beside it. For
non-negative values `floor(floor(64x) / 64) == floor(x)`, so the integer
texcoord is bit-identical to what it was, on the affine and the perspective
path, and VRAM, the hole and STP read nothing else. Six bits is the ceiling:
`ps1_interp_w`'s numerator reaches 2^55 with an 8-bit attribute, so a 14-bit
one reaches 2^61, inside `long`; the affine numerator is `w * a` with
`w <= area`, far below. Both bounds are written beside the call.

**The filter interpolates its OWN texcoords, at the subtexel CENTRE**
(`ps1_centre_uv6`). The corner is the native sample point and the right place
for the nearest texel, but filtered there a 1:1-mapped polygon at 1x (the
default scale) samples every texel on its corner, `fu = fv = 32` everywhere,
and every pixel averages a 2x2 block half a texel up and to the left.
DuckStation samples at pixel centres and is exactly sharp at 1:1;
`aOneToOneMappingFiltersToTheNearestTexelAtOneX` pins that. The two points
come from one pair of helpers, so the second evaluation duplicates nothing:
`ps1_sample_point(p, s, px, py, halves)` is
`((2 * px + halves) * 16) / (2 * s)` box-relative (`halves = 0` is exactly the
old `(px * 16) / s`, `1` the centre, exact at power-of-two scales and floored
at 3, 5, 6, 7), and `ps1_barycentric` the sign-normalised unbiased weights.
The centre can sit just outside a triangle whose corner is inside, so its
weights may be negative and the interpolant extrapolates (the weights still
sum to `area`). That is bounded only while the negative weights are at most
half the positive ones, about one altitude: past it a sliver's extrapolation
overflows `int` and a perspective denominator can reach zero, so the corner's
`u6`/`v6` stand in.

**Samples are texel centres.** `Uc = u6c - 32`, base texel `floor(Uc / 64)`
(a real floor: `Uc` can be negative), weight `Uc & 63`. Each of the four
fetches goes through `ps1_window_fetch` (texture-window masking, then the
CLUT), the same path the nearest sample takes. **UV limits** (`ps1_uv_limit`)
clamp each sample BEFORE the window, so an atlas cell does not pull in its
neighbour; they come from the instance's own `u0..v2` and the record is
unchanged. The range is `[min, max - 1]`, because the PS1 never draws a
primitive's right or bottom edge: a cell mapped 0..32 never shows texel 32
nearest, and at 2x to 8x the last native pixel's subtexel centres lie past
31.5 and would weigh it (DuckStation's `ComputePolygonUVLimits`). A
degenerate range keeps its one texel, and the top widens to the nearest
texel wherever that reaches it (a mirrored mapping, or a pixel on the vertex
carrying the maximum), so the texel VRAM shows is always one the filter may
weigh. `uvLimitsKeepAtlasNeighboursOut` has red on both sides of a cell, at
1x magnified and 1:1 at 4x and 8x.

**A hole has weight zero and the remaining weights renormalise.** Filtering it
as black draws a dark fringe around every cut-out. The weight sum CAN be zero:
under minification the centre need not neighbour the nearest texel, and all
four may be holes or limited onto one. There `T` is the nearest texel's
`t5 << 3`, which is never a hole (the fragment would already have discarded).

**The filtered texel `T` is per channel in 1/8 of a five-bit step (0..248)**,
and every sidecar formula reduces to today's value at `T == t5 << 3`. That
invariant is what the uniform-texture test leans on. `ps1_filtered`:

| | modulated | raw texel |
|---|---|---|
| `.trueColor` | `(T * c8) >> 7` | `T + (T >> 5)` |
| `.off` / `.native` / `.scaled` | `expand(pack(((T * c5) >> 4) + dither_o))` | `expand(pack(T))` |

The dithering modes stay a five-bit, dithered picture, just a spatially smoother
one; raw texels are not dithered, as before. **`side5`** is the five-bit
filtered colour with the nearest texel's STP bit. In the dithering modes a
semi-transparent filtered draw blends `side5`
(`expand(ps1_blend(dst, side5, mode))`), because `expand(out)` would show the
UNFILTERED composite; `.trueColor` takes the filtered `src8` into
`ps1_blend8` unchanged.

**Scope.** Textured TRIANGLES only; rectangles stay nearest. (Superseded by
the 2026-10-03 section below: rectangles now filter under their own Sprite
setting, and the class of a primitive picks the setting.) Ships OFF. This
is DuckStation's "Bilinear (No Edge Blending)" and the picker says so. Edge
blending is possible and is the NEXT spec: at a hole pixel the fragment can
write `dst` back to VRAM unchanged (exactly what a discard leaves) and still
write a blended colour to the sidecar, so the gates still hold. The cost is that
a cut-out edge stays nearest-pixel-shaped at 8x until then.

**Cost, measured (Gate 4, ms/frame over 100 frames, Debug build, second of two
runs; the first is in brackets).**

| fixture | scale | nearest | bilinear | cost |
|---|---|---|---|---|
| `silent-hill-usa` | 4x | 14.0 (14.1) | 14.4 (14.5) | +2.6% (+3.3%) |
| `silent-hill-usa` | 8x | 38.7 (39.2) | 41.1 (42.0) | +6.4% (+7.1%) |
| `tr1-usa-v1-1` | 4x | 7.4 (7.4) | 7.8 (7.3) | +5.6% (-0.5%) |
| `tr1-usa-v1-1` | 8x | 8.1 (9.3) | 9.4 (9.5) | +15.1% (+3.1%) |

Silent Hill is stable across the two runs and costs 3 to 7%. tr1 is NOT: its
runs are short (under 1 s) and the two disagree, most visibly at 8x where the
nearest figure moved 8.1 to 9.3 ms between runs, so its ratios are
noise-bound: low single digits to ~15%. Within each run
`measuresReplayCostAtEachScale` alternates nearest and bilinear per scale;
the two runs were sequential. That test is the opt-in Gate 4 switched by
`PS1_SCALE_TIMING` (see "The two opt-in Metal gates" above), whose earlier
figures sit with the sidecar and blend notes. The filter is a second fetch loop on a textured
fragment, so it costs in proportion to textured overdraw (triangles only when
this was measured; rectangles join them under the 2026-10-03 section).

## Sprite texture filtering (2026-10-03)

**There are two filter settings, and the class of a primitive chooses only
WHICH applies.** "Texture Filtering" and "Sprite Texture Filtering" are the
one `TextureFilter` enum (`texture_filter` / `sprite_filter` in
`Ps1RasterUniforms`, now 16 bytes), and `ps1_filter_for` is
`ps1_is_sprite(p) ? uni.sprite_filter : uni.texture_filter`. The class never
changes what a filter does, so everything above carries over unchanged:
sidecar-only, the hole and STP from the nearest texel, VRAM byte-identical.
`theCorpusRendersIdenticalVramUnderEverySetting` is the gate, all four
combinations, and `MetalFixtureHarness.replay` pins BOTH to `.nearest`.

**`ps1_is_sprite` decides from the primitive's own instance fields.** A
textured rectangle is always a sprite. A triangle with `rw != 0` on all three
vertices is always 3D: a depth means 3D. Any other triangle is a sprite iff
its texture is screen-aligned (u constant down the screen, v constant across
it), tested in exact integers: `du1 * dx2 == du2 * dx1` and
`dv1 * dy2 == dv2 * dy1`, deltas from vertex 0. A triangle with no screen area
or no texture area has no derivatives and is 3D. That is DuckStation's
`zero_dudy && zero_dvdx` with its PGXP `is_3d` override. Scaled and mirrored
2D quads pass; rotated ones fail.

**Four differences from DuckStation** (`gpu_hw.cpp`
`IsPossibleSpritePolygon` ~2340 and the `is_3d` test ~2973), each rule then
reason:

- **A depth on all three vertices means 3D here; DuckStation's `is_3d` is
  "the three vertices' W differ".** Under PGXP an equal-W triangle (a
  GTE-projected billboard, a wall facing the camera squarely) is a sprite
  there and 3D here. Chosen because it keeps camera-facing PGXP walls on
  Texture Filtering (the spec's rule); the cost is that PGXP-on billboards
  follow Texture Filtering too.
- **A degenerate triangle (zero xy-area or zero uv-area) is 3D here;
  DuckStation keeps the current batch's mode.** The consequence: a 2D strip
  stretched from a single texel column or row (bars, borders) has zero
  uv-area and follows Texture Filtering. A known limitation; the guard is the
  spec's.
- **The classifier reads the integer `x0..y2`, not the sub-pixel
  `qx0..qy2`.** It matters only for a PGXP-resolved triangle without a depth
  (`rw != 0` is exactly "has a depth", and CPU-mode PGXP does not give
  game-built 2D one, so it is rare), which is judged by the derivative test
  here.
- **With PGXP off (the shipped default) a 3D wall facing the camera squarely
  has exactly aligned integer axes and is classed a sprite**, so it can
  switch filter from frame to frame as the camera turns. DuckStation shares
  this through the same derivative test.

**The existing triangle tests draw screen-aligned triangles**, which classify
as sprites. That is why `MetalScaleHarness.frame`'s `spriteFilter` defaults
to `filter` (nil means "same as `filter`"): a test of the triangle filter
must reach the setting its triangles actually follow.

**A rectangle samples at the subtexel CENTRE in the triangle's six-bit units,
unwrapped**, so at 1x it lands on the texel centre and filters to the nearest
texel exactly (Nearest-exact at 1x). Its limits are `ps1_wrap_limit`: the
256-texel segment holding the nearest texel, cut to the sprite's own span.
The high limit is `a0 + extent - 1`, the last column itself, with no `max - 1`:
a rectangle draws its right and bottom edge, a triangle does not. The segment
is why a rectangle crossing u/v = 256 does not read the neighbouring texture
page, and `ps1_bilinear` wraps each clamped sample `& 0xFFu` to land back in
the page. The wrap-segment test has red texels at pageX+256..263 so that
omission can fail.

**Cost, measured (Gate 4, ms/frame over 100 frames, Debug build; two
sequential runs, run 1 / run 2).** Columns are nearest/nearest,
bilinear/nearest, bilinear/bilinear.

| fixture | scale | nearest/nearest | bilinear/nearest | bilinear/bilinear |
|---|---|---|---|---|
| `silent-hill-usa` | 4x | 17.1 / 17.2 | 20.0 / 20.2 | 20.3 / 21.2 |
| `silent-hill-usa` | 8x | 54.0 / 52.3 | 62.9 / 62.1 | 63.7 / 63.4 |
| `tr1-usa-v1-1` | 4x | 7.2 / 6.6 | 7.5 / 7.0 | 7.2 / 7.5 |
| `tr1-usa-v1-1` | 8x | 9.2 / 9.2 | 11.0 / 11.4 | 12.7 / 12.7 |

All figures are Debug-build host runs. The sprite setting adds little over
triangle filtering alone: Silent Hill +1 to +5% at 4x and +1 to +2% at 8x
(bilinear/bilinear over bilinear/nearest); tr1's ratios are noise-bound at 4x only; at 8x both runs show +11 to +15%
(bilinear/bilinear over bilinear/nearest: 11.0 to 12.7 and 11.4 to 12.7).

**The 2026-10-02 triangle-filter cost (+2.6% at 4x, +6.4% at 8x) did not
reproduce in this session.** Bilinear/nearest over nearest/nearest here reads
+17% at Silent Hill 4x (17.1 to 20.0, 17.2 to 20.2) and +16.5% / +18.7% at 8x
(54.0 to 62.9, 52.3 to 62.1); the A/B table agrees (+14% to +16% at 8x, HEAD
and `661c206` alike).

**The classifier costs nothing measurable.** `ps1_filter_for` runs on every
textured fragment even with both settings Nearest, and Silent Hill 8x
nearest/nearest reads 52 to 54 ms against the 38.7 ms of the 2026-10-02 table.
An interleaved A/B on one machine (A, B, A, B) separates the two causes: A is
`Rasterizer.metal` at `661c206` (no classifier, no rectangle filter), B is
HEAD. ms/frame, run 1 / run 2:

| row | A (`661c206`) | B (HEAD) |
|---|---|---|
| `silent-hill-usa` 8x nearest/nearest | 52.3 / 54.2 | 52.3 / 53.3 |
| `silent-hill-usa` 8x bilinear/nearest | 60.5 / 62.6 | 59.6 / 62.0 |
| `silent-hill-usa` 4x nearest/nearest | 23.8 (outlier) / 17.3 | 17.3 / 17.2 |
| `tr1-usa-v1-1` 8x nearest/nearest | 9.1 / 9.7 | 9.8 / 9.4 |
| `tr1-usa-v1-1` 8x bilinear/nearest | 10.4 / 11.5 | 11.7 / 11.4 |

A and B agree within run-to-run spread. The 35 to 40% gap to the 2026-10-02
Silent Hill 8x figure is present in A, before any classifier existed, so it
belongs to the machine or the baseline and not to this work: compare columns
within a table, never across tables from different sessions. tr1 8x shows the
largest sprite-setting ratio (+11 to +15%) and is the noisiest fixture; the
cause of that ratio was not isolated.

## Perspective-correct texturing (PGXP Phase 3, 2026-09-15)

**`ps1_interp_w` sits beside `ps1_interp`, and the two rasterizers evaluate ONE
expression over identical integers.** `a = sum(w_i*rw_i*a_i) / sum(w_i*rw_i)`,
with `rw_i` the quantised reciprocal depth `gp0` decided once per triangle on
the CPU. The exactness is not a nicety: it is the only reason the PGXP-on
parity gate (`ps1-test-harnesses`) can be a STRICT equality rather than a
tolerance, so no float reformulation of it is acceptable on either side. Four
properties carry it:

- **`area` cancels.** Numerator and denominator are both first-order in `w`,
  which is also why `rw`'s normalisation constant cancels and a quad's two
  halves may normalise independently.
- **The denominator is provably positive.** Coverage gives every `w_i >= 0`
  with `w0+w1+w2 == area > 0`, and the CPU clamps every `rw_i` to at least 1.
  Without that clamp a pixel sitting exactly on a vertex whose `rw` rounded to
  zero would divide by zero.
- **`num >= 0`**, so plain truncating `/` in Metal agrees exactly with Zig's
  `@divFloor`. An attribute that can go negative (Phase 4's signed colour
  deltas) would need a real floor on the Metal side.
- **The divide was already paid.** The affine path divides by `area` per
  attribute anyway; the perspective path divides by a different denominator.

The `long` in `ps1_interp_w` does NOT break CLAUDE.md's "1/16 px is a ceiling,
more means `long` in the per-fragment loop": that rule is about the COVERAGE
math, which is `int` and stays `int`. The ATTRIBUTE math crossed into `long`
back in Phase 0.

**THE STALE COMMENT IS THE ONE TO READ TWICE.** `ps1_interp`'s doc comment
claimed the weights and the area both scale by `s^2` at internal resolution and
put `int32`'s ceiling at `s = 5`. Phase C inverted that arrangement
(`ps1_triangle_coverage` reduces the SAMPLE POINT to native 1/16-px units
(`qpx = (px * 16) / s`) instead of scaling the vertices up), so **neither the
weights nor the area carries a factor of `s`**, and every bound built on the
old comment was wrong, in the safe direction, for three phases. The overflow
derivation for `rw_one` (beside `primitive.rw_one`) depends on this: `w_i*rw_i`
reaches 2^45 and the numerator 2^55, at EVERY scale, which is what keeps them
inside `i64`/`long`.

**The blind spot applies here with a specific shape.** Both scaled-path gates
only ever look at top-left subtexels, where the sample point IS the native
pixel, so a perspective correction that fired only at the native lattice and
fell back to affine everywhere else would pass Gate 1 and Gate 2 unchanged
while every interior subtexel of every block sampled the wrong texel. The test
that catches it has to assert something about the INTERIOR of a block, the same
lesson the hollow-triangle ring taught. Note what cannot work as that
assertion: "the interior is not the same texel repeated" can never fail,
because `qpx` already varies by 2 q-units per subtexel at `s = 8` under affine
interpolation too.

**`Ps1PrimInstance` went 48 -> 51 words** for `rw0`/`rw1`/`rw2`, and
`Rasterizer.metal`'s `static_assert(sizeof(Ps1PrimInstance) == 4 * 51)` is what
stops the Swift builder and the shader disagreeing about the stride: a
disagreement that does not fail to compile, it just reads the next primitive's
fields.

**Textured RECTANGLES stay affine, permanently**, and which attributes take the
perspective path is a per-record decision, not a fixed list: texcoords under
`flag_texture_perspective`, vertex and modulation colour under
`flag_color_perspective` (`PS1_PRIM_TEXTURE_PERSPECTIVE` /
`PS1_PRIM_COLOR_PERSPECTIVE` on the instance). Every flat-shaded primitive is
affine too: `gp0` refuses it the colour bit, and both interpolants reproduce
three equal colours exactly in any case.

## The third attachment: the PGXP depth plane (Phase 5, 2026-09-25)

`color(2)` (`Ps1FragOut.depth`, `Rasterizer.metal:40`) is a THIRD render
target beside VRAM (`color(0)`, `.r16Uint`) and the true-colour sidecar
(`color(1)`, `.rgba8Uint`): one `.r32Uint` absolute reciprocal-depth value per
pixel, `Ps1PrimInstance` carrying it as `iz0`/`iz1`/`iz2` (51 -> 54 words,
`static_assert(sizeof(Ps1PrimInstance) == 4 * 54)`). It has to be a real
attachment, not a buffer a shader indexes by hand, because the test IS a
hardware depth compare shape (`iz >= stored`, `ps1_depth_passes`) running once
per fragment against whatever the last fragment at that pixel left behind.

**Memoryless while the setting is off, `.private` while it is on
(`MetalVram.init`, `depthDesc.storageMode = depthBuffer ? .private :
.memoryless`).** A memoryless texture costs no backing RAM at all and cannot
be loaded or stored across a pass boundary: the right cost for a plane every
game runs with disabled. Every RASTERIZER PIPELINE declares all three colour
formats unconditionally (`desc.colorAttachments[0/1/2].pixelFormat =
.r16Uint/.rgba8Uint/.r32Uint`, `MetalRasterizer.swift`), whether or not the
depth buffer is on, so **no function constant, and no second pipeline
variant, is needed**: the pipeline shape never changes, only which storage
mode the attachment behind `color(2)` uses. (A narrower pipeline built with
fewer declared attachments (`MetalMoverTests.swift`'s one-attachment mover
pipeline) creates without error even though the shared fragment functions
write all three outputs; Metal simply drops the ones with nothing behind
them. That disproves an earlier claim in this codebase that a declared output
with no attachment is a pipeline CREATION error: it is not, so the shared
three-format pipeline shape is justified by uniformity and cost, not by
avoiding a creation-time failure.) Toggling the setting rebuilds `MetalVram`
from scratch through `ContentView`'s `.id()`, the same mechanism `scale`
uses, rather than mutating the live texture.

**`clear_depth` needs no pass break either side of it**
(`PrimEncoders.swift`'s `encodeDepthClear`, contrast `encodeFill`'s
`breakPass()` calls). `ps1_depth_clear_fragment` passes colour and sidecar
straight through from tile memory (`dst`, `dst_side`) and writes only `0u`
(far) to `color(2)`, so nothing sampling VRAM or the sidecar can ever
observe it, and tile-memory read-modify-write order is submission order at
every pixel regardless of what pass it lands in.

**A VRAM-visible write resets depth in the SAME PASS as its colour**, on the
Metal side exactly as `Vram.maskedWrite`/`fillRectangle` do on the software
side: `ps1_fill_fragment`, `ps1_upload_fragment` (via `ps1_out_absent`) and
`ps1_copy_fragment` all return `0u` (far) for `color(2)` alongside their
colour output rather than leaving the old value in place, so a fill, an
upload or a copy can never leave a stale depth for a later polygon to test
against a texture that no longer exists at that pixel.

## Renderer performance (2026-10-05 spec)

Benchmark: `PS1_GPU_BENCH=<fixtures>` on the Release app (`GpuBench`), best
of 5, the player's own settings. GPU ms is per frame from command-buffer
timestamps with frames serialised; fps is pipelined throughput. Compare rows
within one table only.

Baseline (MacBook Air, Apple M1, 8 GB; dither trueColor / texture filter bilinear / sprite filter nearest):

```
[gpu-bench] crash-bandicoot-warped   1x current    gpu   2.17 ms  cpu   1.42 ms   503.9 fps  (100 frames)
[gpu-bench] crash-bandicoot-warped   4x current    gpu  11.06 ms  cpu   1.52 ms    88.4 fps  (100 frames)
[gpu-bench] crash-bandicoot-warped   6x current    gpu  22.65 ms  cpu   1.66 ms    43.1 fps  (100 frames)
[gpu-bench] crash-bandicoot-warped   8x current    gpu  37.49 ms  cpu   1.70 ms    25.9 fps  (100 frames)
[gpu-bench] silent-hill-usa          1x current    gpu   2.65 ms  cpu   1.49 ms   493.3 fps  (100 frames)
[gpu-bench] silent-hill-usa          4x current    gpu  12.02 ms  cpu   1.65 ms    80.0 fps  (100 frames)
[gpu-bench] silent-hill-usa          6x current    gpu  24.97 ms  cpu   1.71 ms    38.5 fps  (100 frames)
[gpu-bench] silent-hill-usa          8x current    gpu  41.45 ms  cpu   1.43 ms    23.3 fps  (100 frames)
[gpu-bench] tr1-usa-v1-1             1x current    gpu   0.45 ms  cpu   0.18 ms  2258.9 fps  (100 frames)
[gpu-bench] tr1-usa-v1-1             4x current    gpu   2.08 ms  cpu   0.24 ms   475.7 fps  (100 frames)
[gpu-bench] tr1-usa-v1-1             6x current    gpu   4.33 ms  cpu   0.24 ms   227.7 fps  (100 frames)
[gpu-bench] tr1-usa-v1-1             8x current    gpu   7.27 ms  cpu   0.26 ms   135.3 fps  (100 frames)
```

### Task 2: triangle hull (REVERTED)

**Drawing a triangle's miter-offset hull in place of its bounding box made
Silent Hill SLOWER at every scale the task targeted, so the hull is not in
the tree.** It was exact: the corpus lockstep (all eleven fixtures at 1, 2,
3, 4 and 6x, 8x every 10th frame, depth on at 4x) found full scaled VRAM and
sidecar identical to the box. It just did not pay. The rule was "current
faster than box at 4x and above"; two interleaved best-of-5 runs in one
session, same machine as the baseline (GPU ms, current / box):

| fixture | scale | run 1 | run 2 |
|---|---|---|---|
| `crash-bandicoot-warped` | 4x | 10.71 / 11.20 | 10.78 / 11.12 |
| `crash-bandicoot-warped` | 6x | 22.25 / 22.84 | 22.54 / 23.23 |
| `crash-bandicoot-warped` | 8x | 37.31 / 38.47 | 36.56 / 37.65 |
| `silent-hill-usa` | 4x | **12.87 / 12.56** | **12.35 / 12.01** |
| `silent-hill-usa` | 6x | **25.90 / 25.07** | **26.46 / 24.91** |
| `silent-hill-usa` | 8x | **43.64 / 42.65** | **42.71 / 41.52** |
| `tr1-usa-v1-1` | 4x | 2.01 / 2.10 | 2.02 / 2.13 |
| `tr1-usa-v1-1` | 6x | 4.27 / 4.38 | 4.28 / 4.37 |
| `tr1-usa-v1-1` | 8x | 7.15 / 7.33 | 7.15 / 7.36 |

Crash and tr1 gain 2-5%; Silent Hill loses 2-6%, in both runs, at every
scale from 4x up. Two things about the design explain why the win is small
even where there is one, and are worth knowing before trying again:

- **The hull never reaches the thin triangles it was meant for.** A thin
  triangle always has an acute apex, and the miter guard (`k = 1 - cos(theta)
  < 1/32`, i.e. a miter past 8 margins) sends every triangle with an angle
  under ~14.4 degrees back to the box. The plan's "200 px diagonal two pixels
  thick" has a ~0.4 degree apex and drew its box. A hull that wants those
  needs a different cap (a bevel, or clamping the hull to the box), not a
  looser cutoff.
- **The four hand-built tests in the plan all exercise the box, not the
  hull** (needle and thin diagonal by the miter guard, sliver by area,
  clipped giant by the area comparison), so they passed with the margin set
  to 0 and with every hull vertex collapsed to the origin. The test that
  actually gates the margin is a 45-45-90 triangle whose hypotenuse runs
  along (-1, 1), across the corner-to-centre offset (0.5, 0.5): it fails at
  margin 0 at every scale and passes at `margin = s`.

The corpus lockstep test costs **35 minutes** in a Debug host (2120 s), which
is far too slow for the full suite as written; scale it down before it lands
with the next reference switch.

### Task 4: specialised pipelines

**Primitives draw through 28 pipelines specialised by class, colour mode and
whether the destination is read, and that is 27-29% less GPU time per frame
on Crash and Silent Hill at every scale from 4x up.** `ps1_prim_fragment_dst`
and `ps1_prim_fragment_nodst` are thin entries over `ps1_prim_shade` with the
class (`PS1_FC_CLASS`, function constant 1) and true colour
(`PS1_FC_TRUE_COLOR`, 2) folded to constants; 0 stays reserved and unused.
`MetalRasterizer` keeps `[trueColour][PrimVariant]` tables, picks the table
from `ditherMode` per frame and coalesces only EQUAL variants into one
instanced draw, so a run now also ends at a variant change: the earlier
"nothing to break a batch on" holds per variant, not per frame. Instance and
uniform layouts are unchanged.

**`readsDst` is the exact set of things `ps1_prim_shade` reads the
destination for, and one of them carries no flag.** The shader reads `dst`,
`dst_side` or `dst_depth` in five places: `ps1_depth_passes` (only under
`PS1_PRIM_DEPTH_TEST`), the check-mask discard (`PS1_PRIM_CHECK_MASK`), the
5-bit blend, the 8-bit/filtered sidecar composite (both under `transparent`,
which starts as `PS1_PRIM_TRANSPARENT` and only narrows), and the depth
WRITE-BACK, `depth_write ? iz : dst_depth`. That last one is why a persisting
depth plane (`vram.depthPersists`) forces every draw onto the reading variant:
an opaque, untested draw in the `nodst` variant writes 0 where the uber shader
kept the stored depth, and the next depth-tested draw there passes when it
should be refused. `PS1_PRIM_DEPTH_TEST` is in the flag mask as well, although
the core sets it only while the depth buffer is on: a record carrying it can
still reach a memoryless plane (the `--pgxp-on` fixture replayed with the
plane off, or the frames either side of a toggle), and the flag is exactly the
guard `ps1_depth_passes` uses.

**The corpus cannot see the `depthPersists` term**: with it deleted, the
depth-on lockstep still passes, because no fixture puts an untested opaque
draw between a depth write and a later failing test at the same pixel.
`anUntestedDrawKeepsTheStoredDepthWhileThePlanePersists` is the hand-built
case that does, and it fails with the term deleted. Deleting the whole
destination read fails the corpus lockstep on frame 0 or 10 of every fixture
tried.

**Every variant is built in `init`, and a COLD build costs ~1.15 s** against
~210 ms for the uber pipeline alone (Debug host, M1, the app's Metal cache
deleted; warm, 3 ms against 0.8 ms). Metal caches compiled pipelines on disk
per bundle, so the cold figure is paid on the first launch after an install,
update or OS/driver change, and it lands on the thread that builds the
`MetalDisplayView` coordinator. Past the plan's 500 ms line: a background or
parallel pre-build is the follow-up, not part of this change.

`theSpecialisedVariantsPaintExactlyWhatTheUberShaderPainted` (the full-scaled
VRAM and sidecar lockstep against `.uberShader`) costs 299 s in a Debug host.
The brief's version measured ~2500 s; it compares every 10th frame (every
frame is still replayed) and runs 4x only for the first setting and the depth
run. All five settings, 3x for each, the depth run and the full corpus stay.

Benchmark, same machine as the baseline, two interleaved best-of-5 runs in
one session (GPU ms, current / uber):

| fixture | scale | run 1 | run 2 |
|---|---|---|---|
| `crash-bandicoot-warped` | 1x | 2.65 / 2.68 | 2.84 / 2.89 |
| `crash-bandicoot-warped` | 4x | 7.91 / 10.84 | 7.91 / 10.90 |
| `crash-bandicoot-warped` | 6x | 16.08 / 22.16 | 16.11 / 22.26 |
| `crash-bandicoot-warped` | 8x | 26.76 / 36.62 | 26.82 / 36.77 |
| `silent-hill-usa` | 1x | 3.27 / 3.27 | 3.27 / 3.53 |
| `silent-hill-usa` | 4x | 8.57 / 11.83 | 8.56 / 11.87 |
| `silent-hill-usa` | 6x | 17.66 / 24.69 | 17.64 / 24.64 |
| `silent-hill-usa` | 8x | 29.40 / 41.11 | 29.39 / 41.18 |
| `tr1-usa-v1-1` | 1x | 0.33 / 1.32 | 0.39 / 1.27 |
| `tr1-usa-v1-1` | 4x | 1.94 / 2.07 | 1.95 / 2.07 |
| `tr1-usa-v1-1` | 6x | 4.15 / 4.32 | 4.14 / 4.32 |
| `tr1-usa-v1-1` | 8x | 7.12 / 7.26 | 7.12 / 7.26 |

The `uber` column matches the baseline above within a few percent, so the
gain is the specialisation, not the session. tr1 gains 2-6% above 1x; it is
the least overdrawn fixture.
