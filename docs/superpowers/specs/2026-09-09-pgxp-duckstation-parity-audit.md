# PGXP: DuckStation parity audit

Phase 1 of the "match DuckStation's PGXP" programme. This document is the
reference the later phases are specced against: what DuckStation's PGXP
actually consists of, how each part works, and where our implementation
stands against it.

Reference checked out at `duckstation_ref/` (gitignored, same arrangement as
`avocado_ref/`), sparse to `src/`, at commit `3b30876` (2026-09-09). The code
audited is `src/core/cpu_pgxp.{cpp,h}` (1,750 lines), `src/core/gte.cpp`'s
`Execute_RTPS`/`Execute_NCLIP_PGXP`, and `src/core/gpu_hw.cpp`'s consumers.

## Licence — read this before porting anything

`duckstation_ref/LICENSE` is **CC-BY-NC-ND-4.0**, and `cpu_pgxp.cpp` carries
that SPDX header per file. ND is *No Derivatives*: a translation of that file
into Zig is a derivative work, and the licence does not permit distributing
one. This is a stricter position than `avocado_ref/`, which is GPL-2.0 — a
copyleft licence that does permit derivatives on its own terms.

So this programme is specified as **behavioural equivalence**, not
transcription: the reference is read to establish what each feature does and
which numbers it uses, and the implementation is written against this
document. Where a constant is a hardware fact (`GTE::MAX_Z`, the 11-bit vertex
truncation) it is a fact, not an expression. Where DuckStation made a taste
decision (the 2048x2048 vertex cache, the -1 tolerance default) this document
records the decision and the reasoning so the implementation can arrive at it
independently — or deliberately differ.

## The eleven settings

DuckStation exposes PGXP as eleven settings (`src/core/settings.h:90-145`).
Defaults are DuckStation's own:

| Setting | Default | What it does |
|---|---|---|
| `gpu_pgxp_enable` | off | Master switch: geometry correction. |
| `gpu_pgxp_culling` | **on** | NCLIP computed in float from precise vertices, so backface culling does not flip on a sub-pixel-degenerate triangle. |
| `gpu_pgxp_texture_correction` | **on** | Perspective-correct texture interpolation, using the per-vertex W. |
| `gpu_pgxp_color_correction` | off | Perspective-correct Gouraud interpolation. Mutually exclusive with the "no-perspective colour" fast path. |
| `gpu_pgxp_vertex_cache` | off | Second lookup keyed on the integer position, for vertices whose memory word cannot be found. |
| `gpu_pgxp_cpu` | off | Propagation through CPU arithmetic, not just loads/stores. |
| `gpu_pgxp_preserve_proj_fp` | off | Projects from float IR1/IR2/SZ3 instead of the hardware-rounded registers. |
| `gpu_pgxp_depth_buffer` | off | Writes W into a real depth buffer so polygons sort by depth instead of by draw order. |
| `gpu_pgxp_disable_2d` | off | Skips correction for primitives judged 2D. |
| `gpu_pgxp_transparent_depth` | off | Whether transparent primitives participate in the depth buffer. |
| `gpu_pgxp_tolerance` | -1 (off) | Max distance in pixels a precise vertex may sit from the integer one before it is rejected. |

Note what the defaults say about intent: **texture correction and culling
correction are the picture**, and CPU mode and the vertex cache are per-game
workarounds that ship off. Our implementation today has neither the picture
half nor the workarounds — see the gap table.

## How DuckStation's PGXP works

### The value

```c
struct PGXPValue { float x, y, z; u32 value; u32 flags; };
```

`x` is the precise value of the register's **low halfword**, `y` of its **high
halfword**, `z` the depth term. For a packed SXY word those are screen x, screen
y and W; for anything else they are just two precise halves, which is what makes
arithmetic propagation possible at all. `value` is the 32-bit integer the entry
was recorded against.

`flags` carries `VALID_X`/`VALID_Y`/`VALID_Z`, plus `VALID_LOWZ`/`VALID_HIGHZ`
(which half a Z came from, so a half-word write can retire it) and
`VALID_TAINTED_Z` (x/y have been altered, so z is no longer trustworthy and
loses to an untainted z in `SelectZ`).

### Staleness

`Validate(psxval)` clears **all** flags when `value != psxval`: the entry is
kept only while the register or memory word still holds exactly the integer it
was recorded for. Half-word loads validate only the half they touch
(`ValidateAndLoadMem16`).

This is DuckStation's entire safety net, and it is a different mechanism from
ours — see "Fork 1" below.

### Where values live

Shadows for: the 32 GPRs (`g_state.pgxp_gpr`), COP0, the GTE registers
(`g_state.pgxp_gte`), and one entry per 32-bit word of scratchpad + RAM
(`s_mem`, `GetPtr`). Optionally a 2048x2048 vertex cache keyed on the packed
integer position (~83 MB, allocated only when the setting is on).

### Production

`GTE::Execute_RTPS` computes the projection a **second time in float** and
hands it to `PGXP::GTE_RTPS(precise_x, precise_y, precise_z, sxy2_word)`:

```
precise_z       = max(H / 2, precise_sz3)
precise_h_div_sz= H / precise_z
precise_x       = IR1 * precise_h_div_sz + OFX/65536      (clamped -1024..1023)
precise_y       = IR2 * precise_h_div_sz + OFY/65536      (clamped -1024..1023)
```

with IR1/IR2/SZ3 taken from the hardware registers, or — under
`preserve_proj_fp` — from the unrounded float MAC values. `precise_z` is the W
every downstream consumer uses. The result is pushed through the same SXY FIFO
shift the integer registers get.

### Consumption

The GPU asks `GetPreciseVertex(addr, value, x, y, xOffs, yOffs, &x, &y, &w)`:
look up the RAM address the vertex word came from, require
`flags & VALID_XY` and `value == word`, truncate the position to 11 bits
(`TruncateVertexPosition`, matching the GPU's own command parsing — needed for
Jet Moto and Racingroovy VS), add the drawing offset, and set
`w = z / GTE::MAX_Z`. If the tolerance check fails, or the address misses, fall
back to the vertex cache when enabled, and finally to the integer position with
`w = 1.0`. The return value is whether **Z** is valid, which is what gates the
depth buffer independently of x/y.

`Execute_NCLIP_PGXP` recomputes the cross product in float from the three
precise SXY entries, requiring all three to carry `VALID_XYZ`, and nudges a
result whose magnitude lands in (0.1, 1.0) away from zero so a thin triangle
does not round to "degenerate".

### CPU mode

Hooks, per `cpu_pgxp.h`: `LW/LH/LHU/LBx/LWx (LWL/LWR)`, `SB/SH/SW/SWx`,
`MFC2/MTC2/LWC2/SWC2`, `MFC0/MTC0`, `MOVE`, `ADDI/ADDIU/ANDI/ORI/XORI/SLTI/SLTIU/LUI`,
`ADD/ADDU/SUB/SUBU/AND/OR/XOR/NOR/SLT/SLTU`, `MULT/MULTU/DIV/DIVU`, and
`SLL/SRL/SRA/SLLV/SRLV/SRAV`. Arithmetic is done on the halves in `double`,
with `f16Sign`/`f16Unsign`/`f16Overflow` modelling carry between the halves and
16-bit wrap.

## Where we stand

| DuckStation feature | Us today |
|---|---|
| Per-half precise value | **No.** `pgxp.Precise` is a coupled (x, y) pair in 16.16 describing one packed SXY word. Splitting a word loses everything. |
| Z / W term | **No.** Nothing in `Precise`, and nothing in `gpu.command.Vertex`. |
| RAM + scratchpad shadow | Yes (`Bus.shadowLoad`/`shadowStore`/`shadowInvalidate`). Word-granular, no half-word path. |
| GPR shadow | Yes (`Cpu.gpr_shadow`, plus load-delay shadows). |
| GTE register shadow | Partial: `Cop2.precise_sxy[3]` only, not all 64. |
| Staleness model | **Different.** `Precise.resolves(ix, iy)` checks `px >> 16 == ix`; DuckStation compares the whole 32-bit word and applies an optional tolerance. |
| Projection source | **Different.** We keep the hardware MAC0 before its `>> 16`; DuckStation recomputes in float. |
| CPU arithmetic propagation | **No.** One idiom: `or`/`addu` against `$zero` (`exec.zig:73`). |
| Loads/stores | `lw`/`sw` word only. No `lh`/`lhu`/`sh`/`lb`/`swl`/`swr`. |
| GTE moves | `mfc2`/`mtc2`/`lwc2`/`swc2`, SXY0-2 only. |
| Vertex cache | **No.** `Gp0Engine.weldPoint` is a cousin — a per-frame integer-keyed table that makes a frame agree with itself — but it is not a fallback lookup. |
| Tolerance | **No.** The identity check is exact. |
| Culling correction (float NCLIP) | **No.** |
| Texture correction | **No.** |
| Colour correction | **No.** |
| Depth buffer | **No.** |
| Preserve projection precision | **No.** |
| Disable 2D / transparent depth | **No.** |

Two of ours have no DuckStation counterpart and must survive the rework:
`unify` (a primitive's vertices come from one coordinate space) and
`thinIntegerTriangle` (a sub-pixel move must not delete geometry hardware
draws). Both are consequences of our integer rasterizers and are documented in
CLAUDE.md.

## The three forks the later phases must decide

**Fork 1 — staleness.** Our identity check is exact and self-correcting: a
stale entry either fails it or agrees to within a pixel, which is why we have
no invalidation hooks on OTC/MDEC/CD DMA. DuckStation's word-match is stronger
against staleness but says nothing about the position, which is why it needs a
tolerance knob. The two are not composable as-is, because DuckStation's float
projection **does not** generally reproduce the hardware's `MAC0 >> 16`, so our
predicate would reject its values outright. Adopting DuckStation's numbers
means adopting its predicate, and giving up the "invalidation is coverage,
never correctness" property that the current design leans on.

**Fork 2 — numeric format.** DuckStation is float end to end. We are 16.16 in
the records and 1/16 px in both rasterizers, deliberately, because raising it
puts 64-bit math in Metal's per-fragment loop. Pixel-identical output to
DuckStation is therefore not reachable without changing that; behavioural
equivalence is.

**Fork 3 — texture correction and the parity gate.** Perspective-correct
texturing is a per-fragment divide. Our software and Metal rasterizers are
pinned byte-for-byte against each other; DuckStation has no such gate. Either
the software rasterizer takes floats on the PGXP path, or the feature is
Metal-only and parity becomes a PGXP-off guarantee. Deferred to Phase 3.
