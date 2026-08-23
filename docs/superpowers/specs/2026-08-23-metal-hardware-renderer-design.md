# Metal hardware renderer with internal-resolution upscaling — design

**Date:** 2026-08-23 (revised 2026-08-23 after design review)
**Status:** approved; to be implemented across several plans (see § Phases)

## Goal

Render PS1 graphics on the GPU so the internal resolution can exceed 1×, while
the software rasterizer stays exact and keeps working.

**This is not a replacement.** `ps1-core/src/gpu/` remains the renderer for
`ps1-wasm`, `ps1-debug`, `ps1-trace` and the ROM suites, and it is the reference
the Metal backend is diffed against. "Fully Metal" would mean deleting the only
oracle this project has for GPU behaviour.

## Decisions taken

1. **Hardware renderer first, PGXP second.** PGXP is an independent subsystem
   (`cop2/`, `cpu/exec.zig`, GPU vertex intake) that needs no Metal and would
   improve the software rasterizer on its own. It is sequenced second because it
   *deliberately changes output*: it moves every `trace-golden` baseline and
   makes `test-roms-pl` meaningless. Landing it first would leave the renderer
   work with no oracle, and every rendering bug afterwards confounded between
   the two. PGXP gets its own spec.
2. **Accuracy-first; upscaling is opt-in.** At scale 1× the Metal backend must
   be byte-identical to the software rasterizer. Scale > 1 is a separate mode
   that is permitted to diverge (dithering off, and nothing else deliberately).
   **This is only achievable after Phase 0** — see § The 1× gate.
3. **Dual-rasterize: the 1× CPU shadow is always complete.** `ps1-capi` runs the
   software rasterizer *and* records the command stream. The scaled GPU texture
   is authoritative only for what the GPU itself samples. Every readback path is
   served from the CPU shadow. See § Ownership and sync.

## The 1× gate

The original spec asserted byte-identical output at 1× and treated blend
arithmetic as the only obstacle. That was wrong, and the error was structural
rather than cosmetic: **the software rasterizer is neither an edge-function
rasterizer nor an integer one**, so no GPU triangle setup reproduces it.

Two specifics, both load-bearing:

- **Coverage is a scanline span search intersected with the edge test.**
  `renderer.zig:120-149` intersects all three edges with `py` using `@divTrunc`,
  takes the min/max of the intersections, clamps that to the drawing area, and
  only then applies the edge functions with the top-left bias at `:159-161`.
  Hardware triangle setup produces the edge-function coverage set alone. The two
  agree on most triangles and disagree on exactly the degenerate ones that
  matter.
- **Interpolation is `f32` and truncating.** `renderer.zig:224-226` computes
  barycentrics as `@floatFromInt(w) / @floatFromInt(area)`; the textured shader
  at `:428-429` truncates `@abs(f0*tu0 + f1*tu1 + f2*tu2)` straight to a texel
  coordinate; `color.zig`'s modulate is `f32` too. Reproducing that on the GPU
  requires disabling fast-math and hand-blocking FMA contraction, and it would
  still be a float algorithm defended by luck.

**Phase 0 therefore converts the software rasterizer to integer edge-function
rasterization before any of this work starts**: edge functions with a top-left
fill rule replace the span search, and fixed-point interpolation replaces the
`f32` paths. Both sides then evaluate the same integer formulas and
byte-identical becomes a gate that can actually be met.

This is the one deliberate output change in the project, and confining it to its
own phase is the point: it recaptures `trace-golden` and re-pins the PL floors
**once**, up front, with the software renderer as its own before/after oracle.
Every phase after it runs against a frozen baseline. The conversion also moves
the renderer *towards* hardware, which is fixed-point.

## Architecture

### The seam

`gpu/gp0.zig` decodes GP0 commands and calls **seven** entry points on the
`Renderer` namespace — `drawTriangle`, `drawShadedTriangle`,
`drawTexturedTriangle`, `drawRectangle`, `drawTexturedRectangle`, `drawLine`,
`drawShadedLine` (`gp0.zig:210-437`) — each passing a `*const DrawingEnv`.

`Renderer.putPixel` is **not** an eighth entry point and must not be modelled as
one. `gp0.zig` never calls it; every call site is inside `renderer.zig` itself
(`:168`, `:275`, `:296`, `:338`, `:367`, `:532`). It is the shared back end
where the drawing-area clip, the mask check, the blend and the STP-bit OR all
live (`renderer.zig:8-46`). **It is the model for the Metal fragment shader**,
not a stream command.

The stream carries triangles only. Quads are already decomposed into two
triangles by `gp0.zig` before any `Renderer` call (`:221-222`, `:248-249`,
`:276-277`, `:304-305`), and each half is judged separately by the
oversized-primitive rule.

That `DrawingEnv` is **live mutable state** — E1–E6 writes mutate it between
draws (`gpu/registers.zig:21-31`). A list of draw calls is therefore *not*
replayable on its own. The command stream must be ordered and must carry the
state changes interleaved with the draws, exactly as a display list does.

`gp0.zig` stops calling `Renderer` directly and emits into a **sink**, selected
at comptime so the existing path pays nothing:

- **`SoftwareSink`** — rasterizes immediately. Today's code, today's behaviour,
  no buffering. Used by `ps1-wasm`, `ps1-debug`, `ps1-trace` and both ROM
  suites.
- **`RecordSink`** — appends typed POD commands to a per-frame buffer.
- **`DualSink`** — both, in that order. **This is what `ps1-capi` builds with**,
  which is why the macOS app can always fall back to the software renderer and
  why no runtime branch is needed anywhere.

Adding a sink field to `Gp0Engine` touches a struct whose `ps1-golden` state
dump is **hand-written by policy**. The same commit must either add the field to
`state_hash.zig`'s dump or document why it is excluded, alongside the existing
exclusions for host pointers and `cdrom.debug_enable`.

### What the stream carries

Five categories, in submission order.

- **Draws** — the seven primitives. Triangles carry three vertices, colours,
  `clut`, `tpage`, `opcode` and the transparency flag; rectangles additionally
  carry `w`/`h` and `tu`/`tv` (`renderer.zig:473-487`).
- **Explicit state** — E1–E6 writes (`draw_mode`, `tex_window`, `area_top_left`,
  `area_bot_right`, `offset`, `mask_bit` — `registers.zig:5-10`) plus GP1(09)'s
  `texture_disable_allowed` latch.
- **Implicit state** — **the texpage latch a textured polygon performs on
  itself.** `gp0.zig:260`, `:270`, `:285` and `:298` call
  `latchPolygonTexpage(tpage)` *before* the draw, and `e1_texpage_mask` is
  `0b0000_1001_1111_1111` (`registers.zig:19`), which covers bits 0-8 —
  **including bits 5-6, the semi-transparency mode that `putPixel` reads at
  `renderer.zig:31`**. So a textured polygon's blend mode comes from its own
  tpage word, not from the last E1 write. Bit 9 (dither) is *not* in the mask,
  so dithering still comes from E1. **Rectangles do not latch** — `gp0.zig:342`
  reads `draw_env.draw_mode & 0x1FF` instead. A backend that reconstructs state
  purely from recorded E1–E6 writes gets the blend mode wrong for every textured
  polygon that carries its own tpage.
- **Resets** — GP1(00) wholesale-assigns `draw_env = .{}` and clears
  `vram.write_active` (`gpu.zig:239,244`); GP1(01) clears `write_active`
  (`gpu.zig:259`). Both are ordered state changes and can terminate a transfer
  mid-flight.
- **VRAM access that never touches the `Renderer` seam** — three mutations and
  one read, all omitted or under-specified by the original spec, and
  collectively the reason Decision 3 exists:
  - **GP0(02) Fill Rectangle** — `gp0.zig:72` → `vram.fillRectangle`
    (`vram.zig:183`). **Deliberately unmasked**: it writes `self.data[idx] =
    color` directly and ignores GP0(E6), because hardware does. At scale N it is
    its own pass with its own mask semantics.
  - **GP0(80) VRAM→VRAM** — `gp0.zig:76` → `vram.copyRect` (`vram.zig:150`).
    Masked via `maskedWrite`, wraps coordinates (`& 0x3FF` / `& 0x1FF`,
    `vram.zig:161-164`), and **reverses iteration order when the rectangles
    overlap** (`vram.zig:154`). A self-overlapping copy on the scaled texture is
    a read/write hazard on one resource — see § The feedback loop.
  - **GP0(A0) CPU→VRAM** — the payload arrives **word by word** through
    `gp0.zig:25-27`, dispatched before command decode. A single fat `A0` command
    cannot represent a transfer that GP1(00)/GP1(01) aborts mid-payload, so the
    stream records the setup and the payload words as separate items. (E6 cannot
    change mid-payload — `write_active` swallows every GP0 word — so
    `Mask.fromE6` may be captured once at setup.)
  - **GP0(C0) VRAM→CPU** — recorded for completeness but **served from the CPU
    shadow**, never from the GPU. See below.

The command records are fixed-stride POD. `A0` pixel data is **not** inline: it
lives in a side payload buffer, referenced by offset and length, because a
single transfer can be the full 1024×512 (`axisExtent` maps a zero extent to the
whole axis, `vram.zig:47-49`). The original claim that "commands are plain data
with no pointers, so the buffer crosses the C ABI as a flat array" was wrong on
this point: it is two flat buffers, not one.

### VRAM on the GPU

**The VRAM texture is `R16Uint` at `1024·N × 512·N`. It is not RGBA8, and that
is the decision the rest of the renderer hangs on.**

PS1 VRAM is simultaneously framebuffer, texture memory and CLUT storage. A game
draws into it and then samples the result as 4bpp, 8bpp or 16bpp indexed data.
Storing upscaled RGBA8 destroys the bit patterns that texture sampling depends
on. Keeping the raw 16-bit value and decoding ABGR1555/CLUT **in the fragment
shader** preserves them, and is also what lets the shader see bit 15 — the
mask/STP bit whose semantics `renderer.zig:36-45` and `vram.zig:83-87` already
implement carefully and which must not regress.

Texture *data* is never upscaled. At scale N a texel at `(u, v)` reads subtexel
`(u·N, v·N)`; only rendered geometry gains resolution.

Note this is a **new** texture, not the existing display one. The display
texture is `.shaderRead` / `.managed` (`MetalDisplayView.swift:93-94`) and
cannot be a render target; the render texture needs `.renderTarget |
.shaderRead` and `.private` storage.

### The feedback loop

**PS1 VRAM is the render target and the texture source at the same time.**
`renderer.zig:453-454` passes one `vram` pointer as both, and `Color.fetchTexel`
(`color.zig:70-93`) performs a tpage read followed by a *dependent* CLUT read at
arbitrary VRAM addresses while the same draw is writing elsewhere in that VRAM.

In Metal, a texture bound as `[[color(0)]]` and simultaneously `read()` at a
different coordinate is a hazard with undefined results. **This is resource
aliasing, not batching**, and it exists for a single draw call. The original
spec's "the Metal backend must not reorder or batch across a region it will
later read" describes an ordering problem that is not the one we have.

**Design: per-draw hazard detection with render-pass splitting.** The backend
tracks the dirty rectangle written so far in the current render pass. A draw
whose sampled region (tpage + CLUT, or the source rect of an `80` copy)
intersects that dirty rect ends the pass and begins a new one. Ordering is
preserved by construction, and pathological content degrades into many small
passes rather than into wrong pixels.

Programmable blending is unaffected by this and stays: the four
semi-transparency modes need the *destination* pixel, which `[[color(0)]]`
supplies through tile memory. That is a different mechanism from sampling an
arbitrary VRAM address, and only the latter is a hazard.

### Semi-transparency

The four modes are `B/2+F/2`, `B+F`, `B−F`, `B+F/4`.

**It must be integer arithmetic on 5-bit channels, not Metal's fixed-function
blending.** `gpu/color.zig`'s `blend(bg, fg, mode)` works on `u16` ABGR1555 with
expressions like `(br + fr) / 2` — integer division, truncating. Fixed-function
blending operates on normalized floats and rounds differently, so it cannot be
bit-exact at 1×. The shader must decode to 5-bit integers, apply the same
truncating arithmetic, and re-encode.

The blend mode comes from `(draw_mode >> 5) & 3` (`renderer.zig:31`) — which,
per § What the stream carries, a textured polygon may have just overwritten with
its own tpage word.

Dithering runs in-shader at 1× and is disabled above it.

### Ownership and sync

**The CPU shadow is always complete, because `ps1-capi` rasterizes into it.**
`DualSink` runs `SoftwareSink` alongside `RecordSink`, so `Vram.data` holds
correct 1× pixels for draws, fills, copies and uploads alike — not the partial
VRAM a record-only sink would leave, which would have contained fills and
uploads but no geometry.

Consequences, all of which delete a problem the original design had:

- **`ps1_copy_vram` (`ps1-capi/src/root.zig:146-149`) keeps working unchanged**,
  and with it `EmulatorRunner`'s existing frame publication.
- **GP0(C0), GPUREAD and `Gpu.readData` are served from the shadow and never
  stall.** There is no GPU→CPU sync point anywhere on the audio-paced thread. In
  particular the sync point the original spec placed at `C0` was the wrong
  instant regardless: software polls GPUSTAT bit 27 (`vramReadPending`,
  `gpu.zig:182-184`) *before* reading, so the stall would have landed on the
  status poll.
- **Readback is exact rather than downsampled.** A game that reads VRAM back and
  re-uploads or checksums it gets the same bytes at N > 1 as at 1×. Downsampling
  a scaled region, which is what the original design specified, is lossy and
  would have silently violated Decision 2 for any such title.
- **A second, live oracle exists for free.** Reading the render texture back at
  N=1 and diffing it against the shadow is a per-frame comparison that can be
  left on in a debug build, on any game, with no fixture. It does not replace
  Phase B's fixture gate — that one is reproducible and runs in CI, this one is
  exploratory and runs on whatever the user is playing — but it is how a
  divergence gets *localised* to a frame and a primitive once the gate has
  caught it.

The scaled texture is authoritative for exactly one thing: **what the GPU itself
samples**, i.e. render-to-texture at scale. That is the case the shadow cannot
serve and the whole reason the GPU holds VRAM at all.

Cost: the software rasterizer's time is paid always. The app already pays it
today at playable speed.

### Frame pacing

Today a skipped frame is invisible because a VRAM snapshot is idempotent
(`EmulatorRunner.swift:11-14`). **A command stream is not** — it is a set of
incremental mutations, so the existing publication, which overwrites
`slots[next]` and flips `newest` whether or not the renderer consumed the
previous one (`:180-188`), would lose mutations permanently.

**Design: drain-all, present-newest.** Streams go into a bounded queue. The
render thread executes *every* queued stream in order into the scaled texture,
then presents only the newest. Execution is never skipped; presentation still
is, so 59.94-against-60 and 120 Hz ProMotion stay as invisible as they are now.

**The emulator thread never blocks on the renderer.** Audio remains the single
master clock, per `EmulatorRunner`'s existing contract.

On queue overflow — the renderer stalled, or the window backgrounded — the
backlog is discarded and the 1× shadow is uploaded into the scaled texture,
replicated N×N, as a resync. The picture is momentarily 1× and then resumes at
N. This is the same recovery path used when a per-frame stream buffer overflows,
and it exists only because Decision 3 guarantees the shadow is complete.

### Buffers

Fixed-capacity per-frame arena for command records, plus a fixed-capacity side
buffer for `A0` payloads. **No allocation on the emulator thread**, which runs
at `.userInteractive` QoS (`EmulatorRunner.swift:89`). A frame that exceeds
either capacity marks its stream incomplete; the renderer discards it and
resyncs from the shadow.

This project already has a documented pathological frame — Tekken 3 builds a
self-referential ordering table, guarded by `ll_node_limit` at 65,536 nodes — so
"a frame cannot be that large" is not an assumption available here.

### The C ABI

`ps1.h` states three contract rules because getting them wrong is silent. The
stream handoff needs a **fourth**:

> 4. `ps1_take_frame_stream` returns a CORE-OWNED buffer pair (records and
>    payload). It is valid until the next `ps1_run_frame` on the same handle.
>    The caller must not free it and must not retain it across a frame.

This is a third ownership mode alongside caller-owned buffers and the borrowed
disc `.bin`, and it belongs in the header as prose, not merely in the signature.

`Ps1Display` (`ps1.h:54-64`) is unchanged: `width`/`height` still come from
`getVisibleWidth/Height` (`registers.zig:106-124`), the programmed display area.
At scale N those are multiplied for sampling the scaled texture and **not**
multiplied for the aspect math.

### Display and scanout

**24bpp scanout stays on the 1× shadow permanently.**
`DisplayShader.metal:59-75` reconstructs 24bpp pixels by byte-packing across
*adjacent 16-bit VRAM words* (`byte_off >> 1`, `w0`/`w1`, a parity branch). Once
CPU→VRAM uploads are replicated N×N in the scaled texture, that arithmetic is
meaningless and FMV becomes garbage. 24bpp content is FMV — MDEC output uploaded
through `A0` — and was never upscaled geometry, so scanning it out from the
shadow loses nothing. Croc and Silent Hill both depend on this path.

The 15bpp scanout path reads the scaled texture, and its `& 511` / `& 1023`
wraps (`DisplayShader.metal:57`, `:79`) become `& (512N-1)` / `& (1024N-1)`. A
display window that crosses the VRAM edge at scale is not N independent 1×
wraps; Phase C must check this explicitly.

`build.zig:208-215` compiles exactly one `.metal` file into `libps1shaders.a`,
surfaced to Swift through one symbol pair (`ps1_display_metallib_ptr/len`). The
rasterizer shader needs a second source, a merged metallib or a second symbol
pair, and a header change in `Sources/CPs1/include/`.

## Phases

Each phase is its own implementation plan. They are strictly ordered.

### Phase 0 — integer rasterizer conversion (no Metal, no stream)

Replace `renderer.zig`'s scanline span search with edge functions and a top-left
fill rule; replace the `f32` barycentric and texcoord interpolation, and
`color.zig`'s modulate, with fixed-point.

**Gate:** visual A/B on Croc, Spyro, Silent Hill and Crash, plus a reasoned
review of the PL per-test pixel-match deltas — an improvement or a wash is
expected, a regression is a bug. Then `zig build trace-golden -- capture` and
`PS1_UPDATE_GOLDENS=1 zig build test-roms-pl`, as their own commit, with the
diff explained in the message.

**This is the only phase permitted to change output.** Everything after it runs
against a frozen baseline.

### Phase A — the command stream (no Metal)

Introduce the sink seam, the command types, `RecordSink`, `DualSink`, and a
replay function that feeds a recorded stream back into the software rasterizer.

**Gate:** replaying a recorded stream produces a framebuffer **byte-identical**
to rasterizing directly, across the PeterLemon ROMs and several thousand frames
of real-game boot. Plus `zig build trace-golden -- verify` green and
`test-roms-pl` green — the seam must not change core behaviour.

This phase contains no GPU code and is fully testable headlessly. It exists
because "the stream is lossless" is the assumption every later phase rests on,
and it is much cheaper to falsify here than through a Metal backend.

### Phase A2 — the fixture bridge

Phase B has no runnable gate without this. **Metal runs only under
`ps1-macos/test.sh`; the ROM suites run only in Zig behind the compile-time
`enable_rom_tests` flag and load via `cpu.loadExe`. No Swift test can boot a ROM
and no Zig test can run Metal.**

Define the fixture format and both ends of it: a Zig capture tool that emits,
per test, the serialized command stream plus the reference VRAM **hashed**, and
a Swift loader that reads it. Hashes, not images — thousands of frames of
real-game boot at 1 MB each is gigabytes, and the fixtures must be generated
rather than committed.

**Gate:** a Swift test loads a fixture, replays it through a stub backend that
simply applies the stream to a CPU VRAM array, and matches the recorded hashes.
This proves the bridge before any Metal rasterization exists to confound it.

### Phase B — Metal backend at 1×

Extend `ps1-capi/include/ps1.h` with the command-buffer handoff and its
ownership rule. Build the Swift renderer: `R16Uint` render texture, in-shader
decode of 4/8/16bpp and CLUT, programmable blending with the integer arithmetic
above, dithering, mask-bit and STP handling, drawing-area clip, texture window
wrap, per-draw hazard detection with render-pass splitting, and the
`02`/`80`/`A0` passes with their respective mask semantics.

**Gate:** for a recorded stream, the Metal VRAM at 1× is byte-identical to the
software one, per frame, on the PL ROMs and on real-game captures, via the Phase
A2 fixtures. Note this compares **full 1024×512 VRAM**, which is a different and
stronger check than `test-roms-pl` — that suite compares a 320×224 display
window reduced to 5-bit against a per-test floor (`peterlemon_test.zig:26-46`)
and is a ratchet, not an equality test.

### Phase C — upscaling

Scale factor N: geometry coordinate scaling, subtexel texture reads, scale-aware
scanout wraps, dirty-region tracking, dithering disabled, the N×N
shadow-replication resync path.

**Gate:** 1× remains byte-identical (Phase B's test re-run at N=1). At N > 1
there is no golden, so the gate is a checklist of the failures upscaling
actually produces, each checked on Croc, Spyro, Silent Hill and Crash:

- no seams along quad diagonals;
- no texture bleeding across texture-page or CLUT boundaries;
- no gaps between adjacent primitives;
- render-to-texture content sampled at scale rather than at 1×;
- **the oversized-primitive drop rule (`>=1024` horizontally / `>=512`
  vertically) still applied in *native* units, not scaled ones** — all five
  sites: `renderer.zig:77-78` (per triangle, so each quad half is judged
  separately), `:265` (rectangle), `:491` (textured rectangle), `:291` (line)
  and `:321` (shaded line). Note there are two rectangle paths, not one;
- a display window that wraps the VRAM edge scans out correctly at scale;
- 24bpp FMV still correct, i.e. still scanned out from the shadow.

Readback stalls are no longer on this list: Decision 3 removes them.

### Phase D — frontend integration

Scale setting in the app, interaction with the 4:3 aspect lock and the letterbox
path in `MetalDisplayView`, persistence of the choice, and the 1×-software mode
(present the shadow — today's exact path, always available because `ps1-capi`
builds with `DualSink`).

## Risks

- **Phase 0 changes output.** It is the deliberate, isolated exception to the
  project's usual rule, and its blast radius is every `trace-golden` baseline
  and every PL floor. Mitigation is sequencing: it lands first, alone, with its
  own recapture commit, so nothing downstream is confounded by it.
- **Pass-splitting cost.** A game that alternates draw and sample over the same
  VRAM region forces a render pass per draw. Correct but potentially slow;
  measure on Croc and Silent Hill before optimising, and do not weaken the
  hazard test to buy speed.
- **Behavioural leakage.** The sink seam touches `gp0.zig`, which every frontend
  depends on. `trace-golden` is the guard and must stay green in every phase
  after Phase 0.
- **Batching versus correctness.** Many small draws with differing state are
  slow, but merging them across state changes breaks the ordering guarantee.
  Batch only within a run of identical state *and* within a single render pass.

Two risks from the original draft are gone, designed away rather than mitigated:
**readback stalls** (Decision 3 — no GPU→CPU sync exists) and
**render-to-texture ordering** (subsumed by per-draw hazard detection, which is
strictly stronger than the batching rule it replaces).

## Out of scope

PGXP (its own spec, sequenced after this), texture filtering, widescreen hacks,
24bpp display *enhancement* — note that 24bpp display must keep *working*, which
is in scope and specified above — and any change to the software rasterizer's
output after Phase 0.
