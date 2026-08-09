# Core Structural Refactor (P1–P8) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure all 20 files of `ps1-core/src` — named constants, extracted idioms, decomposed structs, `avocado_ref`-mirroring file splits — without changing a single bit of emulated behaviour.

**Architecture:** Eight phases ordered by ascending risk, one or two commits each. Every phase is gated by four existing checks plus the `ps1-golden` trace-equivalence harness. The riskiest phases (P3, P6, P7) are each split into an **a** step (move functions between files, fields stay flat) and a **b** step (group fields into sub-structs), because in Zig those are independent changes and separating them halves the search space when the gate goes red.

**Tech Stack:** Zig 0.16.0, no dependencies. `ps1-golden` (trace goldens), `jaczekanski_test.zig` / `peterlemon_test.zig` (ROM suites), 9 unit-test files.

**Source spec:** `docs/superpowers/specs/2026-08-08-core-structural-refactor-design.md`

---

## Global Constraints

- **Zig 0.16.0 exactly.** `std.Io.Dir.cwd()`, `std.process.Init`, `std.ArrayList(...).empty`, `addRunArtifact`.
- **Every commit is behaviour-identical and structurally different.** A large diff is expected and in scope; a behaviour diff is not.
- **No bug fixes.** Not the 5 red JaCzekanski tests, not the Crash level-select hang, not anything discovered in passing. Discoveries go in the Follow-ups section at the bottom of this plan, and nowhere else.
- **No hardware-quirk comment is deleted.** When code moves, its comment moves with it, verbatim. These comments are the most valuable prose in the repo.
- **Tier A over Tier B, always.** Tier A = let Zig infer the cast target from the result location (`const s: i32 = @bitCast(a);`). No new API, no review burden.
- **Tier B bar: an idiom must be 3+ operations AND appear 4+ times.** Count the sites with `grep -c` before extracting. If it is 2 sites, leave it bare. (The spec's Tier B table lists `DrawingEnv.clipRect()`, which is only 2 sites — see Task P2 Step 4.)
- **Constants in two scopes.** `ps1-core/src/constants.zig` holds only genuine cross-module hardware facts. Everything else is a module-private `const` block at the top of its own file. `0x1F` is *not* one constant — it is a 5-bit colour channel in `renderer.zig` and an ADSR shift field in `spu.zig`.
- **No file in `ps1-core/src` over ~600 lines** when done.
- **`zig fmt` clean** before every commit.
- **The frozen external API.** These are the only symbols the four frontends and the tests reach through `root.zig`. Verified by grep over `ps1-core/tests`, `ps1-debug`, `ps1-trace`, `ps1-wasm`, `ps1-golden`. Renaming any of them breaks a frontend silently:

  ```
  ps1_core.cpu.Cpu     ps1_core.cpu.Cop0    ps1_core.cpu.Reg
  ps1_core.memory.Bus  ps1_core.gpu.Gpu     ps1_core.mdec.Mdec
  ps1_core.cdrom.CdRom ps1_core.interrupt.InterruptController
  ps1_core.spu.Spu     ps1_core.spu.AdsrState   ps1_core.spu.decodeBlock
  ps1_core.disc.Disc   ps1_core.disc.MSF        ps1_core.disc.Track
  ```

  A file split changes which *file* defines a symbol; `root.zig` must keep re-exporting it under the same *path*. `pub const spu = @import("spu/spu.zig");` preserves `ps1_core.spu.Spu` even though the file moved.

---

## The gate, and what it costs

Four checks. Run from the repo root.

```bash
zig build test                                    # 9 unit files + golden_test + 2 ROM self-skips
zig build test-roms-ja  -Doptimize=ReleaseFast    # must stay 12/17, the SAME five red
zig build test-roms-pl  -Doptimize=ReleaseFast    # must pass with NO floor re-pinned
zig build trace-golden  -Doptimize=ReleaseFast -- verify
```

**Measured on this machine, 2026-08-09, against the current clean `master`:**

| Loop | Command | Time |
|---|---|---|
| Inner (per edit) | rebuild + one workload | **~30s** (10s rebuild + 18s verify) |
| Full trace gate | all 8 workloads | **2m30s** |
| Single workload | `./zig-out/bin/ps1-golden verify --filter=croc` | 18s |
| JA suite | `-Doptimize=ReleaseFast` | ~27s |

Baseline sweep, captured before any work started — **this is what green looks like**:

```
[golden] skip castlevania-symphony-of-the-night: cue declares 2 FILEs; Disc.initFromCue takes one data slice
[golden] skip tekken: cue declares 28 FILEs; Disc.initFromCue takes one data slice
  bios-only              600M instr   240 hashes   OK
  crash-bandicoot-europe-edc 600M instr   240 hashes   OK
  rayman-europe          600M instr   240 hashes   OK
  croc-legend-of-the-gobbos 600M instr   240 hashes   OK
  silent-hill-usa        600M instr   240 hashes   OK
  metal-gear-solid-special-missions-europe-enfrdeesit 600M instr   240 hashes   OK
  tr1-usa-v1-1           600M instr   240 hashes   OK
  spyro-the-dragon-usa   600M instr   240 hashes   OK
```

**Work the inner loop, not the full gate.** A 30-second answer per edit is what makes this refactor tractable: pick a grouping, apply it, ask. The full sweep is the phase-completion gate, not the per-edit one.

### What a green sweep means — and what it does not

A green sweep means **this commit did not change behaviour**. It never means **this behaviour is right**.

Every golden was captured against the code as it stood on 2026-08-08, bugs included. A bug present at capture time is baked into the baseline and will pass forever. The three dead fields this plan deletes, the write-only CD volume registers it leaves alone, the `mdec` region pinned at a constant value in 5 of the 8 workloads — none of that is validated by a green sweep, because the sweep only ever compares this build against the last one.

Hardware conformance is a different question with different owners, and they do not move during this refactor:

- **JaCzekanski suite** — golden `psx.log`s captured on real hardware. Must stay at **12/17 with the identical five red** (`mdec/4bit`, `mdec/8bit`, `mdec/step-by-step-log`, `cdrom/timing`, `cdrom/getloc`). A newly *passing* test is as much a failure signal as a newly failing one: it means behaviour moved.
- **PeterLemon ratchet** — per-test pixel-match floors. Must pass with **no floor re-pinned**. A changed pixel count is a changed renderer.

So: the harness tells you the refactor was faithful. It cannot tell you the thing you were faithful to was correct. Do not let eight OKs talk you into believing anything else.

### The rule when the gate goes red

`git reset` and redo the phase in smaller steps. **Never re-capture a golden to make a phase pass.** Goldens are re-captured exactly once in this plan (Task P8b), for a reason spelled out there.

---

## File Structure

```
ps1-core/src/
  constants.zig     NEW (P1)  cross-module hardware facts only
  bits.zig          NEW (P1)  Tier-B helpers that clear the 3-ops/4-sites bar
  alu.zig                P1   Tier A cast cleanup
  cop0.zig                    unchanged
  cpu/              NEW (P7)
    cpu.zig                   struct, step(), tickPeripherals(), exceptions, loadExe()
    icache.zig                CacheLine, fetchInstruction(), flush
    exec.zig                  execute()/special() dispatch + all opXxx
  cop2/             NEW (P4)
    cop2.zig                  struct, reg read/write, flags, executeCommand() dispatch
    math.zig                  divideUNR, recip table, MAC/IR saturation, matrix+vector helpers
    opcodes.zig               opRtps..opCc
  gpu/
    gpu.zig                P2 (light) timing, GPUSTAT, GP1
    gp0.zig                P2  command FSM only
    primitive.zig     NEW (P2) Point/Size/Texcoord/TexturedPoint + word decode
    color.zig         NEW (P2) getColor16, blend, texel fetch+modulate, dither
    renderer.zig           P2  rasteriser only, under 600 lines
    registers.zig          P2  DrawingEnv/DisplayEnv
    vram.zig               P2  + Vram.index()
  spu/              NEW (P3)
    spu.zig  voice.zig  adsr.zig  reverb.zig  noise.zig  gauss.zig  regs.zig
  mdec/             NEW (P5)
    mdec.zig  algorithm.zig
  cdrom/            NEW (P6)
    cdrom.zig  commands.zig  fifo.zig  xa.zig  cdda.zig
  disc.zig  timer.zig  interrupt.zig  sio.zig     P5 (naming only)
  dma.zig  memory.zig                             P8 (naming only)
  root.zig                                        re-export paths updated per phase
```

`spu_gauss.zig` becomes `spu/gauss.zig` in P3. Deleted files: none except by move.

---

## Task P1: `constants.zig`, `bits.zig`, and `alu.zig`

Establishes the extraction vocabulary on the two smallest, best-covered files before it reaches anything dangerous. `alu.zig` is 103 lines at roughly one cast per three lines, and is pinned by `cpu_test.zig` and `gte_test.zig`.

**Files:**
- Create: `ps1-core/src/constants.zig`
- Create: `ps1-core/src/bits.zig`
- Modify: `ps1-core/src/alu.zig` (whole file)
- Modify: `ps1-core/src/cpu.zig:65-71` (`signExtend16`/`signExtend8` → `bits`)

**Interfaces:**
- Produces: `constants.vram_width/vram_height/sector_bytes/lead_in_frames/cpu_clock_hz`, `bits.sext16(u16) u32`, `bits.sext8(u8) u32`. Later phases consume these.
- Consumes: nothing.

- [ ] **Step 1: Confirm the baseline is green before touching anything**

```bash
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify
```

Expected: the 8-line all-OK block quoted above, ~2m30s. If this is not green, stop — something is wrong before the refactor starts.

- [ ] **Step 2: Write `constants.zig`**

Only genuine cross-module hardware facts. Resist adding anything a single module owns.

```zig
//! Hardware facts shared by more than one module. A constant that only one
//! file uses belongs in a private `const` block at the top of that file.

/// VRAM is 1024x512 16-bit pixels (ABGR1555).
pub const vram_width = 1024;
pub const vram_height = 512;

/// Every sector on disc is 2352 bytes on the wire, whatever the mode.
pub const sector_bytes = 2352;

/// MSF 00:02:00 == LBA 0. `MSF.toLba` subtracts this; `fromLba` re-adds it.
pub const lead_in_frames = 150;

/// R3000A clock. The GPU's video clock is 11/7 of this (53.2224 MHz).
pub const cpu_clock_hz = 33_868_800;
```

- [ ] **Step 3: Write `bits.zig` with only what clears the bar**

`sext16` is the `@as(u32, @bitCast(@as(i32, @as(i16, @bitCast(v)))))` chain — 3 casts, and it appears in `cpu.zig:66`, `cpu.zig:553`, `cop2.zig`, and the load/branch paths. It clears both halves of the bar.

```zig
//! Bit and cast idioms that clear the extraction bar: 3+ operations AND 4+
//! call sites. Anything below that bar stays written out at its call site —
//! forty tiny wrappers nobody can remember is worse than the casts were.

/// Sign-extend a 16-bit value into a 32-bit register word.
pub fn sext16(v: u16) u32 {
    const signed: i16 = @bitCast(v);
    return @bitCast(@as(i32, signed));
}

/// Sign-extend an 8-bit value into a 32-bit register word.
pub fn sext8(v: u8) u32 {
    const signed: i8 = @bitCast(v);
    return @bitCast(@as(i32, signed));
}
```

- [ ] **Step 4: Apply Tier A throughout `alu.zig`**

Result-location inference dissolves the chains with no new API. Every function keeps its exact semantics — `add`/`sub` still return `?u32` and still use `@addWithOverflow`/`@subWithOverflow`, `div`/`divu` keep both PS1 quirks verbatim.

```zig
pub fn add(a: u32, b: u32) ?u32 {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    const result = @addWithOverflow(sa, sb);
    return if (result[1] != 0) null else @bitCast(result[0]);
}

pub fn mult(a: u32, b: u32) HiLo {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    const result: u64 = @bitCast(@as(i64, sa) * @as(i64, sb));
    return .{ .lo = @truncate(result), .hi = @truncate(result >> 32) };
}

pub fn slt(a: u32, b: u32) u32 {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    return if (sa < sb) 1 else 0;
}
```

Keep the doc comments on `div`/`divu` about the divide-by-zero and `INT_MIN / -1` quirks exactly as they are.

- [ ] **Step 5: Point `cpu.zig` at `bits.zig`**

Replace the two private helpers at `cpu.zig:65-71` with imports. Leave every call site spelled `signExtend16(...)` by aliasing, so this step's diff stays confined to the top of the file:

```zig
const bits = @import("bits.zig");
const signExtend16 = bits.sext16;
const signExtend8 = bits.sext8;
```

- [ ] **Step 6: Run the fast gate**

```bash
zig fmt ps1-core/src
zig build test
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify --filter=bios-only
```

Expected: tests pass; `bios-only ... OK` in ~18s.

- [ ] **Step 7: Run the full gate**

```bash
./zig-out/bin/ps1-golden verify
zig build test-roms-ja -Doptimize=ReleaseFast
zig build test-roms-pl -Doptimize=ReleaseFast
```

Expected: 8/8 OK; JA 12/17 with the same five red; PL passes with no floor re-pinned.

- [ ] **Step 8: Commit**

```bash
git add ps1-core/src/constants.zig ps1-core/src/bits.zig ps1-core/src/alu.zig ps1-core/src/cpu.zig
git commit -m "refactor(core): add constants.zig and bits.zig, apply Tier A casts to alu.zig

No behaviour change. Trace goldens green on all 8 workloads, JA 12/17
with the identical five red, PL floors unchanged.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P2: `gpu/` — extract `color.zig` and `primitive.zig`

`renderer.zig` is 625 lines with the texel-fetch-and-modulate block written out **twice** (`renderer.zig:471` inside the textured-triangle shader, `renderer.zig:579` in the textured-rectangle loop), and `getColor16` exists in two files (`gpu/gpu.zig:304` as a method with an unused `self`, `gpu/gp0.zig:554` at file scope). Verified by grep, not assumed.

**Files:**
- Create: `ps1-core/src/gpu/color.zig`
- Create: `ps1-core/src/gpu/primitive.zig`
- Modify: `ps1-core/src/gpu/renderer.zig` (target: under 600 lines)
- Modify: `ps1-core/src/gpu/gp0.zig:423-571` (helpers move out)
- Modify: `ps1-core/src/gpu/gpu.zig:304-310` (drop the duplicate)
- Modify: `ps1-core/src/gpu/vram.zig` (add `index`)

**Interfaces:**
- Consumes: `constants.vram_width/vram_height` from P1.
- Produces: `color.getColor16(u32) u16`, `color.blend(bg: u16, fg: u16, mode: u2) u16`, `color.fetchTexel(...) u16`, `color.modulate(...) u16`, `color.dither_table`, `Vram.index(x, y) usize`, and `primitive.{Point,Size,Texcoord,TexturedPoint}` + their `get*` decoders.

- [ ] **Step 1: Move the primitive decoders into `primitive.zig`**

These already sit at file scope in `gp0.zig:423-571` with no dependency on `Gp0Engine` — the boundary is already drawn, this step just moves it. Move `Point`, `Size`, `Texcoord`, `TexturedPoint`, `getCommandLength`, `getPoint`, `getSize`, `getTexcoord`, `getTexturedPoint`, `getClut`, `getTpage`, `isTransparent`, `getTexturedRectangleSize`, `getX`, `getY`. Make each `pub`. Leave the file-scope `drawTexturedTriangle` wrapper (`gp0.zig:519`) in `gp0.zig` — it calls the renderer, so it is command-layer glue, not decode.

- [ ] **Step 2: Write `color.zig`, folding both duplicates into one**

`getColor16` moves here (delete both copies). The texel fetch and the modulation block each become one function, called from both the triangle shader and the rectangle loop.

```zig
const std = @import("std");
const constants = @import("../constants.zig");
const Vram = @import("vram.zig").Vram;

pub const dither_table = [4][4]i8{
    .{ -4, 0, -3, 1 },
    .{ 2, -2, 3, -1 },
    .{ -3, 1, -4, 0 },
    .{ 3, -1, 2, -2 },
};

/// 24bpp command word -> ABGR1555.
pub fn getColor16(value: u32) u16 {
    const r = (value & 0xFF) >> 3;
    const g = ((value >> 8) & 0xFF) >> 3;
    const b = ((value >> 16) & 0xFF) >> 3;
    return @intCast((b << 10) | (g << 5) | r);
}

/// One texel, at any of the three depths. `tex_depth` is (tpage >> 7) & 3.
/// Coordinates are widened to usize here rather than at each call site — the
/// original wrote `@as(usize, tpage_y + final_v) * 1024 + ...` out by hand in
/// both the triangle shader and the rectangle loop.
pub fn fetchTexel(
    vram: *const Vram,
    tex_depth: u32,
    tpage_x: u16,
    tpage_y: u16,
    clut_x: u16,
    clut_y: u16,
    u: u32,
    v: u32,
) u16 {
    const px: usize = @as(usize, tpage_x);
    const py: usize = @as(usize, tpage_y) + @as(usize, v);
    const cy: usize = @as(usize, clut_y);
    if (tex_depth == 0) {
        const word = vram.data[Vram.index(px + @as(usize, u / 4), py)];
        const idx = (word >> @as(u4, @truncate((u % 4) * 4))) & 0xF;
        return vram.data[Vram.index(@as(usize, clut_x) + idx, cy)];
    } else if (tex_depth == 1) {
        const word = vram.data[Vram.index(px + @as(usize, u / 2), py)];
        const idx = (word >> @as(u4, @truncate((u % 2) * 8))) & 0xFF;
        return vram.data[Vram.index(@as(usize, clut_x) + idx, cy)];
    }
    return vram.data[Vram.index(px + @as(usize, u), py)];
}
```

**Preserve the bit15 semantics exactly.** `modulate` must keep `(texel & 0x8000)` on the result, and `blend` must keep `(color & 0x8000)` — carry the `renderer.zig:71-74` and `renderer.zig:77-84` comments across verbatim. Those two comments describe the Silent Hill mask-box bug; losing them is how it comes back.

- [ ] **Step 3: Add `Vram.index`**

15 sites compute `y * 1024 + x` by hand. Clears the bar comfortably.

```zig
/// VRAM is row-major, 1024 pixels per row. Callers pass unsigned coordinates
/// already known in range — clipping happens before this.
pub inline fn index(x: usize, y: usize) usize {
    return y * constants.vram_width + x;
}
```

- [ ] **Step 4: Do NOT extract `clipRect()` — verify the count first**

The spec's Tier B table lists `DrawingEnv.clipRect()`, but grep finds only **2** sites (`renderer.zig:8` and `renderer.zig:113`), and they differ in type (`i16` vs `i32`). Two sites is below the 4-site bar. Leave both written out. This step exists so the next reader does not "finish the job" the spec appears to ask for.

```bash
grep -c "area_top_left & 0x3FF" ps1-core/src/gpu/renderer.zig   # expect 2
```

- [ ] **Step 5: Rewrite the two textured paths against `color.zig`**

Both `drawTexturedTriangle`'s shader and `drawTexturedRectangle` now call `color.fetchTexel` + `color.modulate`. The rectangle path keeps its no-decomposition structure — it exists on purpose (CLAUDE.md), so do not route it through `rasterizeTriangle`.

- [ ] **Step 6: Check the line count came down**

```bash
wc -l ps1-core/src/gpu/*.zig
```

Expected: `renderer.zig` under 600 (from 625), `gp0.zig` well down from 571.

- [ ] **Step 7: Run the gate — PeterLemon is the one that matters here**

```bash
zig fmt ps1-core/src
zig build test
zig build test-roms-pl -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify
```

Expected: PL passes with **no floor re-pinned** — the ratchet is the sharpest instrument for this phase, since a changed pixel count is a changed renderer. Goldens 8/8 OK (`vram` and `gpu` regions move every sample in every workload, so a rasteriser bug cannot hide).

- [ ] **Step 8: Commit**

```bash
git add ps1-core/src/gpu ps1-core/src/constants.zig
git commit -m "refactor(gpu): extract color.zig and primitive.zig, de-duplicate texel fetch

Folds the twice-written texel-fetch/modulate block and the two getColor16
copies into one each. renderer.zig 625 -> under 600 lines. No behaviour
change: PL floors unchanged, trace goldens 8/8.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P3a: `spu.zig` → `spu/` file split (functions only)

892 lines, 38 fields on `Spu` plus 21 on `Voice`. Split the **files** first; leave every field exactly where it is. Zig lets `spu/reverb.zig` operate on `*Spu` without owning any of its fields, so the file move and the field move are independent changes — and separating them means a red gate points at one or the other, not both.

**Files:**
- Create: `ps1-core/src/spu/spu.zig` (from `spu.zig`), `voice.zig`, `adsr.zig`, `reverb.zig`, `noise.zig`, `regs.zig`
- Move: `ps1-core/src/spu_gauss.zig` → `ps1-core/src/spu/gauss.zig`
- Delete: `ps1-core/src/spu.zig`, `ps1-core/src/spu_gauss.zig`
- Modify: `ps1-core/src/root.zig`, `ps1-core/src/memory.zig:7`, `ps1-core/src/cdrom.zig:3`

**Interfaces:**
- Consumes: `bits`, `constants` from P1.
- Produces: `spu/spu.zig` exporting `Spu`, `Voice`, `AdsrState`, `decodeBlock` — the frozen names. `root.zig` keeps `pub const spu = @import("spu/spu.zig");` so `ps1_core.spu.Spu` is unchanged.

- [ ] **Step 1: Split by function, mirroring `avocado_ref/src/device/spu/`**

| New file | Takes |
|---|---|
| `voice.zig` | `Voice` struct, `read`, `write`, `keyOn`, `keyOff`, `fetchAndDecode`, `decodeBlock` |
| `adsr.zig` | `AdsrState`, `stepAdsr` (as `pub fn step(voice: *Voice)`) |
| `reverb.zig` | `wrapReverbAddr`, `readReverbSram`, `writeReverbSram`, `sat`, `doReverb` |
| `noise.zig` | the LFSR step out of `generateSample` |
| `regs.zig` | `Spu.read`/`Spu.write` register dispatch, `getStatus` |
| `gauss.zig` | the interpolation table (was `spu_gauss.zig`) |
| `spu.zig` | `Spu` struct + fields, `init`, `step`, `generateSample`, SRAM/DMA, `checkIrq`, `pushCdAudio`, `pushExtAudio` |

- [ ] **Step 2: Carry the four landmine comments across verbatim**

Non-negotiable, each is a shipped bug:
1. `reverb_enable` is a **host** toggle, not hardware (`spu.zig:333-336`).
2. SPUCNT bit 7 gates reverb SRAM **writes only** — the gate lives *inside* `writeReverbSram`, reads still happen and `reverb_curr_addr` still advances.
3. A write to `0x1F801DA2` **rewinds `reverb_curr_addr` to `base * 8`**.
4. Every reverb add/subtract **saturates to i16 individually** — that is what `sat()` is for. Summing into one i32 and clamping once gives a different answer.

And in `adsr.zig`, the signed-step comment: the exponential-decrease step must stay signed, because scaling a positive step and shifting right floors to 0, the envelope stalls above zero, `is_on` never clears, and all 24 voices are permanently busy.

- [ ] **Step 3: Update the three importers and `root.zig`**

```zig
// root.zig
pub const spu = @import("spu/spu.zig");
```
```zig
// memory.zig:7 and cdrom.zig:3
const Spu = @import("spu/spu.zig").Spu;
```

- [ ] **Step 4: Run the gate**

```bash
zig fmt ps1-core/src
zig build test                       # spu_test.zig + the two reverb goldens
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify
```

Expected: `spu_test` passes including both `doReverb` goldens (impulse + pseudo-random, 512 pairs each); goldens 8/8 (`spu` moves every sample in every workload).

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src
git commit -m "refactor(spu): split spu.zig into spu/{spu,voice,adsr,reverb,noise,gauss,regs}.zig

File split only — every field stays on Spu/Voice. Mirrors
avocado_ref/src/device/spu/. Reverb goldens and trace goldens green.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P3b: `Spu`/`Voice` field grouping

Now move fields. `Voice`'s 21 fields carry the clearest seam in the file: 8 are register-backed, 13 are decoder/envelope internals.

**Files:**
- Modify: `ps1-core/src/spu/spu.zig`, `voice.zig`, `adsr.zig`, `reverb.zig`
- Modify: `ps1-golden/src/state_hash.zig:276-341` (`hashSpu`) — **same commit**

**Interfaces:**
- Produces: `Voice.regs`, `Voice.adpcm`, `Voice.env`; `Spu.reverb`, `Spu.mix`, `Spu.noise`. Field *values* are unchanged, only their paths.

- [ ] **Step 1: Group `Voice`**

```zig
pub const Voice = struct {
    /// The 8 register-backed words software reads and writes (0x1F801C00+).
    regs: struct {
        vol_l: i16 = 0,
        vol_r: i16 = 0,
        pitch: u16 = 0,
        start_addr: u16 = 0,
        adsr1: u16 = 0,
        adsr2: u16 = 0,
        adsr_vol: i16 = 0,
        loop_addr: u16 = 0,
    } = .{},

    /// ADPCM decode position and predictor history.
    adpcm: struct {
        current_addr: u32 = 0,
        current_fraction: u16 = 0,
        old: i32 = 0,
        older: i32 = 0,
        decoded_buffer: [28]i16 = [_]i16{0} ** 28,
        history: [4]i16 = [_]i16{0} ** 4,
        buffer_index: usize = 28, // starts at 28 to trigger the first decode
    } = .{},

    /// Envelope state machine.
    env: struct {
        state: AdsrState = .Off,
        current_ad_vol: i32 = 0, // 0..0x7FFF
        cycles: u32 = 0,
    } = .{},

    is_on: bool = false,
    ignore_samples: bool = false,
    has_reached_endx: bool = false,
};
```

- [ ] **Step 2: Update `hashSpu` in the same edit**

The dump is hand-written on purpose — it must be *made* to follow, which is the point. Same fields, same order, new paths. Order matters: it feeds a streaming hash.

```zig
for (&spu.voices) |*v| {
    s.int(v.regs.vol_l);
    s.int(v.regs.vol_r);
    s.int(v.regs.pitch);
    s.int(v.regs.start_addr);
    s.int(v.regs.adsr1);
    s.int(v.regs.adsr2);
    s.int(v.regs.adsr_vol);
    s.int(v.regs.loop_addr);
    s.int(v.adpcm.current_addr);
    s.int(v.adpcm.current_fraction);
    s.int(v.adpcm.old);
    s.int(v.adpcm.older);
    s.bytes(std.mem.asBytes(&v.adpcm.decoded_buffer));
    s.bytes(std.mem.asBytes(&v.adpcm.history));
    s.int(v.adpcm.buffer_index);
    s.flag(v.is_on);
    s.flag(v.ignore_samples);
    s.flag(v.has_reached_endx);
    s.tag(v.env.state);
    s.int(v.env.current_ad_vol);
    s.int(v.env.cycles);
}
```

**The hash must be byte-identical after this edit.** Same values in the same order through the same `Sink` = same `Wyhash`. If the gate goes red here, you dropped a field, added one, or reordered — not a behaviour bug.

- [ ] **Step 3: Group `Spu`'s reverb/mix/noise fields**

`reverb`: `regs`, `base`, `curr_addr`, `counter`, `out_l`, `out_r` (leave `reverb_enable` at top level — it is a host toggle, and `hashSpu` deliberately excludes it). `mix`: `cd_vol_l/r`, `ext_vol_l/r`, `current_cd_l/r`, `current_ext_l/r`. `noise`: `timer`, `lfsr`, `level`.

- [ ] **Step 4: Inner loop, then full gate**

```bash
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify --filter=croc   # ~30s
./zig-out/bin/ps1-golden verify
zig build test
```

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src ps1-golden/src/state_hash.zig
git commit -m "refactor(spu): group Voice and Spu fields into sub-structs

Field paths change, values do not; state_hash.zig updated in lockstep and
the hashes are unchanged. Trace goldens 8/8.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P4: `cop2.zig` → `cop2/{cop2,math,opcodes}.zig`

1,115 lines, and the single best-covered file in the repo: **1,150 `gte/test-all` cases**. That suite is the ratchet — it will catch a transcription error faster than the trace goldens will.

**Files:**
- Create: `ps1-core/src/cop2/cop2.zig`, `math.zig`, `opcodes.zig`
- Delete: `ps1-core/src/cop2.zig`
- Modify: `ps1-core/src/cpu.zig:5`
- Modify: `CLAUDE.md` (the `avocado_ref` GTE path correction)

**Interfaces:**
- Produces: `cop2/cop2.zig` exporting `Cop2`; `cpu.zig` keeps `pub const Cop2 = @import("cop2/cop2.zig").Cop2;` so `ps1_core.cpu.Cop2` is unchanged.

- [ ] **Step 1: Split**

| File | Takes |
|---|---|
| `math.zig` | `recip`, the UNR table, `divideUNR`, `extendMac`, `accumulateMac`, `storeMac`, `setMac0`, `checkMacOverflow`, `saturateToIr`, `saturateSxy`, `saturateColor`, `clampColor`, `matrixFromCtrl`, `vertex`, `irVector`, `rgbcScaled`, `backgroundColor`, `farColor`, `multiplyMatrixByVector`, `multiplyVectors` |
| `opcodes.zig` | `doPerspectiveTransform`, `opRtps`, `opRtpt`, `opNclip`, `opMvmva`, `opSqr`, `opAvsz`, `opNcs`/`opNct`/`ncsSingle`, `opNcds`/`opNcdt`/`ncdsSingle`, `opNccs`/`opNcct`/`nccsSingle`, `opCdp`, `opCc`, `applyLighting`, `depthCueWithRgbc`, `depthCueColor`, `pushRgb`, `pushColorFromMac` |
| `cop2.zig` | `Cop2` struct + `data_regs`/`ctrl_regs`/`macs`, `init`, `readData`/`writeData`/`readCtrl`/`writeCtrl`, `irgbValue`, `isI16Ctrl`, `setFlag`, `updateErrorFlag`, `executeCommand` dispatch |

- [ ] **Step 2: Carry the four GTE landmines across verbatim**

1. **MAC0..3 live in `macs: [4]i64`, not `data_regs[24..27]`, but they are 32-bit registers** — `storeMac` narrows on the way in. Everything reading a MAC back (`mfc2`, the colour FIFO's `>> 4`, GPL's `<< sf`) must see the narrowed value.
2. **IR saturation raises the same FLAG bit in both directions** (24/23/22, never the colour-FIFO bits 21/20/19).
3. **IR is clipped from the low 32 bits of MAC**, which at sf=0 routinely disagrees in sign with the whole.
4. **MVMVA's `mx=3` and `cv=2` select documented hardware *bugs*** — OP crosses IR with the RT diagonal, not its third column. And the matrix/translation selector bits were once swapped; if 3D geometry goes subtly wrong, re-check the operand decode first.

Also keep `try_` (Zig keyword collision) named exactly that.

- [ ] **Step 3: Fix the `avocado_ref` GTE path in CLAUDE.md**

CLAUDE.md's "Reference material" section says GTE lives at `avocado_ref/src/device/gte/`. It does not — the real path is `avocado_ref/src/cpu/gte/`. Fix it here, as the spec directs.

- [ ] **Step 4: Run the GTE ratchet first, it is the fastest signal**

```bash
zig fmt ps1-core/src
zig build test-roms-ja -Doptimize=ReleaseFast -Drom-filter="gte"
```

Expected: all 1,150 `gte/test-all` cases pass. If any fail, the diff is in `math.zig` — a saturation helper or a MAC narrowing lost in the move.

- [ ] **Step 5: Full gate**

```bash
zig build test                       # gte_test.zig, 1291 lines
zig build test-roms-ja -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify
```

Expected: JA 12/17 same five red; goldens 8/8 (`cpu` region covers `cop2.data_regs`/`ctrl_regs`/`macs` and moves every sample).

- [ ] **Step 6: Commit**

```bash
git add ps1-core/src CLAUDE.md
git commit -m "refactor(gte): split cop2.zig into cop2/{cop2,math,opcodes}.zig

Mirrors avocado_ref/src/cpu/gte/. Also corrects CLAUDE.md's GTE reference
path, which said device/gte. All 1150 gte/test-all cases still pass.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P5: `mdec/` split, plus naming in `disc`/`timer`/`interrupt`/`sio`

Low risk, and a good place to spend the naming vocabulary before P6. **Note the coverage gap before starting:** `mdec` is pinned at one constant value for all 240 samples in 5 of the 8 workloads. Only `croc`, `silent-hill` and `tr1` decode FMV. A bug in the non-FMV MDEC paths passes 5 goldens silently — so `mdec_test.zig` is the real net here, not the sweep.

**Files:**
- Create: `ps1-core/src/mdec/mdec.zig`, `algorithm.zig`
- Delete: `ps1-core/src/mdec.zig`
- Modify: `ps1-core/src/disc.zig`, `timer.zig`, `interrupt.zig`, `sio.zig` (naming only)
- Modify: `ps1-core/src/memory.zig:5`, `root.zig`

- [ ] **Step 1: Split `mdec.zig`**

`algorithm.zig` takes `idct`, `decodeBlock`, `signExtend10`, `ycrcb_to_rgb`, `assembleMacroblock`, `decodeAllMacroblocks`. `mdec.zig` keeps the `Mdec` struct (~768 KB by value — two 131,072-entry FIFOs, held by value in `Bus`; do not change that, per the spec's out-of-scope list), status/control registers, and the FIFO plumbing.

- [ ] **Step 2: Carry the MDEC landmines**

- **MDEC_STAT bit 31 means data-out FIFO *empty*, not "data ready".** It was inverted once; every decoder poll loop spins waiting for it to go low, so the inversion hangs the caller outright.
- The register follows Avocado's `MDEC::Status`: bits 30/29 recomputed per read, 28/27 the DMA request bits gated by MDEC_CTRL 30/29, 26-23 the output format, 15-0 remaining parameter words **minus one**.
- **Only the 24bpp and 15bpp colour paths exist.** 4bpp/8bpp are monochrome one-block layouts; the decoder mis-parses them and emits nothing. That is why `mdec/4bit` and `mdec/8bit` hang — leave it.

- [ ] **Step 3: Naming pass on `disc`/`timer`/`interrupt`/`sio`**

Named constants only, module-private. In `disc.zig` reach for `constants.lead_in_frames` and `constants.sector_bytes`. **Do not touch the BCD/MSF conversion logic** — `fromLba` re-adds the 150-frame lead-in, `fromFrames` does not, and mixing them shifts positions by two seconds. In `sio.zig` name the `ack_delay = 500` and the digital-pad ID `0x41`, and keep the deferred-/ACK comment: the BIOS pad routine clears both JOY_CTRL bit 4 and I_STAT bit 7 before polling, so a synchronous interrupt is swallowed by the routine's own acknowledge.

- [ ] **Step 4: Gate**

```bash
zig fmt ps1-core/src
zig build test                       # mdec_test, disc_test, sio_test
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify
```

Expected: unit tests pass; goldens 8/8 — and note that `croc`/`silent-hill`/`tr1` are the three carrying real `mdec` signal.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src
git commit -m "refactor(mdec): split into mdec/{mdec,algorithm}.zig; name constants in disc/timer/interrupt/sio

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P6a: `cdrom.zig` → `cdrom/` file split (functions only)

**The riskiest file in the repo**, and the one with no automated coverage before the harness existed. 1,067 lines, 51 fields, and CLAUDE.md's densest concentration of "do not fix this" warnings. Verified by the trace goldens only — `cdrom_test.zig` covers the interrupt-line model but nothing that boots.

Split files first. Fields stay flat. `cdrom/commands.zig` takes `*CdRom` and reaches through it exactly as the methods do today.

**Files:**
- Create: `ps1-core/src/cdrom/cdrom.zig`, `commands.zig`, `fifo.zig`, `xa.zig`, `cdda.zig`
- Delete: `ps1-core/src/cdrom.zig`
- Modify: `ps1-core/src/memory.zig:2`, `root.zig`

**Interfaces:**
- Produces: `cdrom/cdrom.zig` exporting `CdRom`, `DriveState`, `IrqAction`. `root.zig` keeps `pub const cdrom = @import("cdrom/cdrom.zig");` so `ps1_core.cdrom.CdRom` is unchanged (`cdrom_test.zig` and `ps1-debug` depend on it).

- [ ] **Step 1: Split by function**

| File | Takes | Lines (approx) |
|---|---|---|
| `fifo.zig` | `PendingInterrupt`, `InterruptQueue` (`push`/`pushAction`/`pop`/`peek`/`peekMut`/`clear`), `pushParameter`, `readResponse`, `readData` | ~150 |
| `commands.zig` | `executeCommand`, `processCommand` (the whole 0x01..0x56 switch), `ack_delay` and its per-command exceptions | ~260 |
| `xa.zig` | `xa_zigzag_table`, `isXaAudioSector`, `playXaAudioSector`, `decodeXaPacket`, `interpolateXa`, `zigzagXa`, `XaChannel` | ~230 |
| `cdda.zig` | the `.Playing` branch of `readNextSector` — the report cadence and the Red Book 588-frame decode | ~70 |
| `cdrom.zig` | `CdRom` struct + all fields, `init`, `setDisc`, `read`, `write`, `step`, `readNextSector`, `getStatus`, `getDriveStatus`, `updateInterrupts`, `updateSubchannelQ`, `synthesizeHeaderAndQ`, `queueIrq`, `pushXaSample` | ~380 |

**`pushXaSample` stays in `cdrom.zig`, not `xa.zig`, despite the name.** Both decoders call it: `playXaAudioSector` (XA) and the CD-DA branch of `readNextSector` (Red Book). It is the shared audio sink, not part of either decoder. This is the first finding that shapes P6b.

- [ ] **Step 2: `cdda.zig` has no state of its own — confirm before writing it**

Grep the CD-DA branch: it reads `mode`, `last_subchannel_q`, `disc`, `muted` and writes only through `queueIrq` and `pushXaSample`. It owns **zero fields**. So `cdda.zig` is a pure function over `(*CdRom, lba, raw_sector)`, not a struct. Do not invent a `CddaState` to make the five files look symmetric.

- [ ] **Step 3: Carry the CDROM landmines — every one of these is a shipped bug**

1. **The drive asserts a level; I_STAT latches the edge.** `updateInterrupts` computes the line and calls `interrupts.trigger(.Cdrom)` **only on a low→high transition**. Re-latching on the level delivers a phantom second interrupt (the BIOS acks I_STAT before writing the CDROM IFR); a once-only per-item latch loses interrupts queued while masked. Both halves load-bearing, both pinned by `cdrom_test.zig`.
2. **Writing the CDROM IFR forces `irq_line = false`**, so the next queued response makes a fresh edge.
3. **The keep-unread-bytes ACK/`readResponse` retain logic is correct** — an acked-but-undrained item keeps its bytes readable but reports 0 in the IFR. Do not "fix" byte loss there.
4. **ReadN's 1,000,000-cycle seek is not Avocado's and must not be "ported"** — porting it faithfully kills Crash Bandicoot.
5. **The data FIFO is latched on Request(0x80), not filled on sector arrival**, and only when `data_fifo_empty`. Re-latching mid-transfer splices a newer sector into an in-flight DMA — that hung Crash's Jungle Rollers.
6. **`ack_delay` is 50000, not 1000.** Acking ~50x too fast broke Crash's boot.
7. **`executeCommand` forces `busy_for = 0`** where Avocado sets 1000. Known divergence, deliberate — setting it asserts STAT bit7 and blocks CdStatus polls.
8. **GetlocL's error response is `{stat|0x01, 0x80}`** — matches PSX-SPX, ours is right and Avocado's is not. Leave it.
9. **CD-DA report gate is mode bit2 (`0x04`), not bit4**, and reports fire on a frame cadence (absolute every 0x20 frames, relative offset 0x10), not once per sector.
10. **`Play` takes an optional track parameter** and must seek to that track's INDEX 01, or the drive sits in the previous track's pregap — silence.
11. **XA submode masks** distinguish video/audio/form2; wrong masks silently drop all in-game music.

- [ ] **Step 4: Inner loop on the workload that actually exercises this**

```bash
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify --filter=croc
```

Expected: `croc-legend-of-the-gobbos ... OK` in ~18s. **Croc is the right first probe** — its first `ReadN` lands around 90-100M instructions, and the injected-bug self-check (`ack_delay` 50000 → 49999) is caught on it at `FAIL @ instr 97500000`, attributed to `cdrom`. `bios-only` would tell you almost nothing here: a disc-less boot barely touches the command path.

- [ ] **Step 5: Then the CD-DA workload, which nothing else covers**

```bash
./zig-out/bin/ps1-golden verify --filter=tr1
```

Expected: OK. Tomb Raider (1 data + 56 audio tracks) is the *only* coverage the Red Book path has anywhere in the repo. If `cdda.zig` lost the `Play(track)` seek or the bit2 report gate, this is what catches it.

- [ ] **Step 6: Full gate**

```bash
./zig-out/bin/ps1-golden verify
zig build test                                    # cdrom_test.zig pins the three IRQ behaviours
zig build test-roms-ja -Doptimize=ReleaseFast
```

Expected: 8/8; `cdrom_test` passes; JA still 12/17 with `cdrom/getloc` and `cdrom/timing` red **for the same reasons as before** — `getloc` can never pass (its golden was captured against a psxcd built with `MAX_RESULT_SIZE == 7`), and `cdrom/timing` hangs after `psxcd: Init Ok!`.

- [ ] **Step 7: Commit**

```bash
git add ps1-core/src
git commit -m "refactor(cdrom): split cdrom.zig into cdrom/{cdrom,commands,fifo,xa,cdda}.zig

File split only — all 51 fields stay on CdRom. pushXaSample stays in
cdrom.zig: both the XA and CD-DA decoders feed it. cdda.zig owns no state.
Trace goldens 8/8 including croc (XA) and tr1 (Red Book).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P6b: `CdRom`'s 51 fields → sub-structs

This is the grouping the spec left open, and the reason the harness had to exist first. **Decided below** — grounded in which functions actually touch which fields, not in what makes five tidy piles. Two of the groupings fall out of real constraints found while reading the code (`pushXaSample`'s two callers; `cdda.zig`'s zero fields), and one field family turns out to be dead.

**Files:**
- Modify: `ps1-core/src/cdrom/*.zig`
- Modify: `ps1-golden/src/state_hash.zig:198-272` (`hashCdrom`) — **same commit**

### The grouping

```zig
pub const CdRom = struct {
    // Host-only; excluded from the state hash on purpose.
    debug_enable: bool = false,
    // Read-only input. Excluded from the hash: it holds a slice whose address
    // varies per run, and a `tracks` array undefined past `track_count`.
    disc: ?disc.Disc = null,

    regs: Regs = .{},        // software-visible register state
    fifos: Fifos = .{},      // parameter / response / data FIFOs + IRQ queue
    drive: Drive = .{},      // mechanism: position, timers, mode, status
    audio: AudioOut = .{},   // the SHARED sink both decoders push into
    xa: Xa = .{},            // XA-ADPCM decoder + resampler state

    // Command dispatch. Ticked in step(), executed by commands.zig.
    pending_command: ?u8 = null,
    pending_command_delay: u32 = 0,
};
```

| Sub-struct | Home | Fields |
|---|---|---|
| `Regs` | `cdrom.zig` | `index`, `irq_enable`, `busy_for`, `last_response_byte`, `volume_ll`, `volume_lr`, `volume_rl`, `volume_rr` |
| `Fifos` | `fifo.zig` | `parameter_fifo`, `parameter_len`, `irq_queue`, `irq_line`, `last_raw_sector`, `sector_buffer`, `sector_buffer_ptr`, `sector_buffer_len`, `data_fifo_empty` |
| `Drive` | `cdrom.zig` | `drive_state`, `sector_timer`, `seek_timer`, `read_after_seek`, `status`, `mode`, `seek_target`, `current_pos`, `last_sector_header`, `last_subchannel_q`, `loc_l_valid`, `muted`, `sectors_delivered` |
| `AudioOut` | `cdrom.zig` | `audio_fifo_l`, `audio_fifo_r`, `audio_fifo_read`, `audio_fifo_write`, `audio_tick_counter` |
| `Xa` | `xa.zig` | `xa_filter_file`, `xa_filter_channel`, `xa_old_l`, `xa_older_l`, `xa_old_r`, `xa_older_r`, `xa_ringbuf`, `xa_ring_p`, `xa_sixstep` |

**Why `AudioOut` is its own group and not part of `Xa`.** `pushXaSample` has two callers on opposite sides of the file split — `playXaAudioSector` in `xa.zig` and the Red Book branch in `cdda.zig` — and `step()` drains the same FIFO to the SPU on its own 768-cycle counter. Putting it inside `Xa` would make `cdda.zig` reach through `self.xa` to emit Red Book audio, which is exactly backwards. It is the mixer input, not a decoder's scratch space.

**Why `Regs` holds the four volume bytes.** `volume_ll/lr/rl/rr` are written by the register writes at `cdrom.zig:284/290/291/347` and **read by nothing** — grep confirms zero read sites. They are write-only registers today: CD audio volume is not applied. That is a real gap, and it is **not fixed here** (see Follow-ups). Grouping them with the other register state records what they are without changing what they do.

**Why `drive_state` is not merged with `pending_command`.** Drive state is set *synchronously* by commands and survives the `irq_queue.clear()` every command byte performs; the Seeking→Reading transition is driven by `seek_timer` in `step()`, gated on `read_after_seek`. That decoupling is load-bearing — a polling loop would otherwise lose the transition. Keeping the drive mechanism in one struct and command dispatch outside it makes the boundary visible.

- [ ] **Step 1: Do the three dead fields LAST, not here**

`xa_adpcm_filter`, `is_reading`, and `autoreport_is_absolute` each appear **exactly once** in `cdrom.zig` — their declaration. Never read, never written after init.

```bash
grep -c xa_adpcm_filter ps1-core/src/cdrom/*.zig    # expect 1 (the declaration)
grep -c is_reading ps1-core/src/cdrom/*.zig         # expect 1
grep -c autoreport_is_absolute ps1-core/src/cdrom/*.zig  # expect 1
```

Deleting them is behaviour-neutral but **not hash-neutral**: `hashCdrom` folds all three in (`state_hash.zig:219,225,238`), so removing them changes every `cdrom` hash and turns the goldens red for a non-behavioural reason. That forces a re-capture, and re-captures are the one thing this refactor must not do casually.

So: **carry all three through P6b unchanged**, hash and all. They are deleted in Task P8b, in a commit that does nothing else.

- [ ] **Step 2: Apply the grouping**

Hundreds of call sites. `self.status` → `self.drive.status`, `self.irq_queue` → `self.fifos.irq_queue`, and so on. The compiler finds every one; the risk is not a missed site but a *plausible* wrong one — `self.xa.old_l` where `self.xa.older_l` was meant. That class of typo compiles cleanly and changes audio output, which is precisely what the `croc` (XA) and `tr1` (Red Book) goldens exist to catch.

- [ ] **Step 3: Update `hashCdrom` in the same edit — same fields, same order**

```zig
const cd = &bus.cdrom;
var s = Sink.init();
s.int(cd.regs.index);
s.int(cd.regs.irq_enable);
s.bytes(&cd.fifos.parameter_fifo);
s.int(cd.fifos.parameter_len);
s.int(cd.regs.last_response_byte);
s.bytes(&cd.fifos.last_raw_sector);
s.bytes(&cd.fifos.sector_buffer);
s.int(cd.fifos.sector_buffer_ptr);
s.int(cd.fifos.sector_buffer_len);
s.flag(cd.fifos.data_fifo_empty);
s.int(cd.drive.status);
s.int(cd.drive.mode);
s.int(cd.drive.seek_target.m);
// ... unchanged order through the rest ...
```

Do **not** reorder to match the new struct layout, however tempting. The `Sink` is a streaming hash: order is the hash. Reordering is a guaranteed red gate with no behavioural cause, and you will spend an hour proving it was nothing.

- [ ] **Step 4: Inner loop — croc, then tr1**

```bash
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify --filter=croc
./zig-out/bin/ps1-golden verify --filter=tr1
```

~18s each. If `cdrom` diverges and `cpu`/`ram` move with it, you have a real behavioural change; if `cdrom` alone moves at sample 0, you almost certainly reordered the dump.

- [ ] **Step 5: Full gate**

```bash
./zig-out/bin/ps1-golden verify
zig build test
zig build test-roms-ja -Doptimize=ReleaseFast
```

- [ ] **Step 6: Commit**

```bash
git add ps1-core/src ps1-golden/src/state_hash.zig
git commit -m "refactor(cdrom): group CdRom's fields into regs/fifos/drive/audio/xa

AudioOut is its own group, not part of Xa: both the XA and Red Book
decoders push into it and step() drains it. The four CD volume bytes go
in Regs — they are write-only today (never read), recorded not fixed.
The three dead fields are carried through unchanged; they are removed in
a later commit that re-captures goldens for that reason alone.

state_hash.zig updated in lockstep, field order unchanged, hashes
unchanged. Trace goldens 8/8.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P7a: `cpu.zig` → `cpu/` file split (functions only)

992 lines. Verified by trace goldens only — no unit test drives `step()` from a CD boot. `cpu_test.zig` covers instruction semantics, not the master loop.

**Files:**
- Create: `ps1-core/src/cpu/cpu.zig`, `icache.zig`, `exec.zig`
- Delete: `ps1-core/src/cpu.zig`
- Modify: `ps1-core/src/memory.zig`, `root.zig`

**Interfaces:**
- Produces: `cpu/cpu.zig` exporting `Cpu`, `Reg`, and re-exporting `Cop0`/`Cop2`. `root.zig` keeps `pub const cpu = @import("cpu/cpu.zig");` — `ps1_core.cpu.{Cpu,Cop0,Reg}` all stay valid.

- [ ] **Step 1: Split**

| File | Takes |
|---|---|
| `icache.zig` | `CacheLine`, `fetchInstruction`, the I-cache flush loop from the MTC0 SR path |
| `exec.zig` | `execute`, `special`, `opRegimm`, every `opXxx`, `rOp`/`rOpChecked`/`hiLoOp`/`shift`/`shiftV`/`iOp*`, `Instruction`, `decode`, `LoadType`/`StoreType` |
| `cpu.zig` | `Cpu` struct + fields, `init`, `step`, `tickPeripherals`, `readReg`/`writeReg`/`getIdx`, `exception`/`enterException`, `isInstructionBusErrorAddress`, `isCacheIsolated`, `loadExe`, `Reg`, `bios_hit_count` |

- [ ] **Step 2: `step()` and `tickPeripherals()` stay together in `cpu.zig`, intact**

The CPU is the master clock; there is no `Bus.step()`. Do not reorder anything inside `tickPeripherals`. The fan-out order is **`SPU → GPU → SIO → Timer0/1/2 → CDROM`** and it is load-bearing: Timer0 consumes GPU dotclock ticks and Timer1 consumes GPU hblank ticks produced *earlier in the same call*. `cdrom.updateInterrupts()` runs immediately after `cdrom.step()`. `dma.tickCpuWindow(delta_cycles)` runs back in `step()`.

- [ ] **Step 3: Carry the CPU landmines**

1. **The GPU 11/7 clock scale with its carried remainder (`gpu_clock_frac`) is verified correct against the BIOS's own vblank counter — do not "fix" it.** The frame period is NTSC-exact (~571,212 CPU cycles). Without the scale the BIOS VSync wait times out during KERNEL SETUP.
2. **Load/store waitstates are billed one step late** — `delta_cycles` is snapshotted right after fetch, so waitstates `execute()` adds land on the next `step()`. Not a bug.
3. **An interrupt taken discards the fetched instruction and does not advance PC.**
4. **Interrupts are never taken in or just before a delay slot** (`safe_to_interrupt`).
5. **An explicit `writeReg` during `execute()` cancels a pending load** (`writeReg` clears `delay_r`), matching Avocado's `setReg()`.
6. **I-cache tags are virtual** (`vaddr & 0xFFFFF000`), so KUSEG/KSEG0 alias to different lines; KSEG1 is uncacheable; a RAM miss burst is a hardcoded **+7 cycles**.
7. **`opSlti`/`opSltiu` are dead code** — the live path is `iOpSignExt` + `alu.slt`/`sltu`. Move them, do not wire them up. (They are removed in P8b with the other dead code.)
8. **The TTY intercept is a PC hack, not a syscall** — `physical_pc == 0xA0/0xB0` with `t1` selecting putchar.

- [ ] **Step 4: Inner loop, then full gate**

```bash
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify --filter=bios-only
./zig-out/bin/ps1-golden verify
zig build test
zig build test-roms-ja -Doptimize=ReleaseFast
zig build test-roms-pl -Doptimize=ReleaseFast
```

`bios-only` is a fine first probe *for this phase* — every workload exercises the CPU from instruction zero, so a dispatch or pipeline error shows up in the first few samples of the cheapest workload.

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src
git commit -m "refactor(cpu): split cpu.zig into cpu/{cpu,icache,exec}.zig

step() and tickPeripherals() stay intact in cpu.zig; the peripheral
fan-out order is unchanged. Trace goldens 8/8.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P7b: `Cpu` field grouping

20 fields. Smaller and cleaner than `CdRom`: the pipeline registers form one obvious group and the load-delay pairs another.

**Files:**
- Modify: `ps1-core/src/cpu/cpu.zig`, `exec.zig`, `icache.zig`
- Modify: `ps1-golden/src/state_hash.zig:167-192` (`hashCpu`) — **same commit**
- Modify: `ps1-debug`, `ps1-trace`, `ps1-wasm`, `ps1-golden` only where a moved field forces it

- [ ] **Step 1: Group**

```zig
pub const Cpu = struct {
    regs: [32]u32 = [_]u32{0} ** 32,

    /// Triple-PC pipeline. Models the branch-delay slot: `current_pc` is the
    /// instruction being executed, `pc` the one fetched, `next_pc` the one after.
    pipeline: struct {
        pc: u32 = 0xbfc00000,
        next_pc: u32 = 0xbfc00004,
        current_pc: u32 = 0xbfc00000,
        is_delay_slot: bool = false,
        next_is_delay_slot: bool = false,
    } = .{},

    /// Dual load-delay pairs. A load lands one instruction late; an explicit
    /// writeReg to the same register during execute() cancels it.
    load_delay: struct {
        load_r: u5 = 0,
        load_v: u32 = 0,
        delay_r: u5 = 0,
        delay_v: u32 = 0,
    } = .{},

    hi: u32 = 0,
    lo: u32 = 0,
    cop0: Cop0 = Cop0.init(),
    cop2: Cop2 = Cop2.init(),
    bus: *Bus,
    cycles: u64 = 0,
    gpu_clock_frac: u32 = 0,
    tty_context: ?*anyopaque = null,
    tty_write_fn: ?*const fn (context: ?*anyopaque, char: u8) void = null,
    icache: [256]CacheLine = [_]CacheLine{.{}} ** 256,
};
```

- [ ] **Step 2: Check what the frontends touch**

```bash
grep -rn "\.current_pc\|\.next_pc\|\.load_r\|\.delay_r\|\.is_delay_slot" ps1-debug ps1-trace ps1-wasm ps1-golden
```

`ps1-trace` reads PC for its execution diff. Update only what this grep finds — the spec scopes frontend changes to "what a moved or renamed symbol mechanically forces", nothing more.

- [ ] **Step 3: Update `hashCpu`, order unchanged**

```zig
for (cpu.regs) |r| s.int(r);
s.int(cpu.pipeline.pc);
s.int(cpu.pipeline.next_pc);
s.int(cpu.pipeline.current_pc);
s.flag(cpu.pipeline.is_delay_slot);
s.flag(cpu.pipeline.next_is_delay_slot);
s.int(cpu.load_delay.load_r);
s.int(cpu.load_delay.load_v);
s.int(cpu.load_delay.delay_r);
s.int(cpu.load_delay.delay_v);
// ... rest unchanged ...
```

Keep the two exclusion comments on `hashCpu` verbatim: host pointers (`bus`, `tty_context`, `tty_write_fn`) are excluded, and `bios_hit_count` is excluded because it is a `pub var` in the *namespace* — one process-global counter shared by every machine ever constructed.

- [ ] **Step 4: Gate**

```bash
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify --filter=bios-only
./zig-out/bin/ps1-golden verify
zig build test && zig build   # confirm all four frontends still build
```

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src ps1-golden/src/state_hash.zig ps1-trace ps1-debug ps1-wasm
git commit -m "refactor(cpu): group pipeline and load-delay fields into sub-structs

state_hash.zig updated in lockstep, order unchanged, hashes unchanged.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P8a: `dma.zig` and `memory.zig` — naming only

**Naming only. No restructuring.** `memory.zig`'s read/write dispatch is a ~30-deep `if (paddr == ...)` chain **whose order is load-bearing**: special cases sit deliberately ahead of the general ranges that would swallow them. Converting it to a declarative region table is excluded from this spec entirely — it is the one change capable of reordering precedence invisibly, and it needs its own spec and its own tests.

**Files:**
- Modify: `ps1-core/src/dma.zig`, `ps1-core/src/memory.zig`

- [ ] **Step 1: Name the addresses in `memory.zig`**

A module-private block: `Addr.gpu_stat`, `Addr.spu_range`, `Addr.cdrom_base`, and so on. **Substitute names for literals in place. Do not move a single branch.**

- [ ] **Step 2: Keep the three precedence comments loud**

- The `0x1F801DA8` word-read fixup that keeps the SPU transfer FIFO and SPUCNT apart. A CPU word read spanning it covers two 16-bit *registers*, whereas DMA4 pops the FIFO twice — that is why `Bus.dmaRead32` exists as a separate path.
- The `0x1F801108` Timer1 mode shadow (`0x3C045678`) and the `0xC0C00000` SIO spoofs — magic values that satisfy BIOS/test patterns, not real hardware.
- The CDROM byte-lane handling at `0x1F801800..0x1F801803`: it is an 8-bit device, a wider store hits the *addressed* port once per byte lane (it does **not** walk 0x1800..0x1803, which would drop a byte into the command register), and a word read mirrors one status byte across all four lanes.

- [ ] **Step 3: Name the DMA constants**

Keep every warning: sub-word stores to DMA registers must be **shifted into the addressed byte lane** (an unshifted latch killed Croc's FMV); DICR is a **full-word latch**, not byte-granular; sync mode 3 must start **no transfer at all**; channel priority is not implemented (fixed 0..6 loop, matching Avocado); and mode 1 hands the bus back between blocks **only on the SPU channel** (`blockPacingCyclesPerWord`), because channels 2 and 3 carry the bulk of real game traffic and pacing them changes CPU/DMA interleaving everywhere.

- [ ] **Step 4: Gate**

```bash
zig fmt ps1-core/src
zig build test                       # dma_test.zig, 453 lines
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify
zig build test-roms-ja -Doptimize=ReleaseFast    # cpu/io-access-bitwidth lives here
```

- [ ] **Step 5: Commit**

```bash
git add ps1-core/src
git commit -m "refactor(bus): name address and DMA constants; dispatch order untouched

Naming only. The if-chain's order is load-bearing and every branch stays
exactly where it was.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P8b: Delete dead code — the one commit that re-captures goldens

Isolated deliberately, because it is the only change in this plan that is **behaviour-neutral but not hash-neutral**. Removing a field from `state_hash.zig` changes every hash in that region from sample 0 onward, even though the field was a constant nobody read.

**Files:**
- Modify: `ps1-core/src/cdrom/cdrom.zig` (3 dead fields), `ps1-core/src/cpu/exec.zig` (2 dead functions)
- Modify: `ps1-golden/src/state_hash.zig`
- Modify: `ps1-core/tests/goldens/trace/*.txt` (all 8, re-captured)

- [ ] **Step 1: Prove the goldens are green immediately before**

```bash
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify
```

Expected: 8/8 OK. **This must be green before you delete anything** — it is what lets the next step's re-capture be attributed to the deletion and nothing else.

- [ ] **Step 2: Delete the three dead `CdRom` fields**

`xa_adpcm_filter`, `is_reading`, `autoreport_is_absolute`. Each is declared and never touched again.

- [ ] **Step 3: Delete the two dead CPU functions**

`opSlti` and `opSltiu`. Implemented, never dispatched — the live SLTI/SLTIU path is `iOpSignExt` + `alu.slt`/`sltu`. These affect no hash (they hold no state), so they could ride in any commit; they go here to keep all deletions together.

- [ ] **Step 4: Remove the three fields from `hashCdrom`**

Delete `s.int(cd.xa_adpcm_filter);`, `s.flag(cd.is_reading);`, `s.flag(cd.autoreport_is_absolute);`.

- [ ] **Step 5: Confirm the gate goes red, and only in `cdrom`**

```bash
zig build -Doptimize=ReleaseFast && ./zig-out/bin/ps1-golden verify
```

Expected: **FAIL on every disc workload at the first sample, first diff `cdrom`**. This is the correct and expected result. If any region *other* than `cdrom` diverges, stop — you changed behaviour, not just the dump.

- [ ] **Step 6: Verify the other three gates did NOT move**

```bash
zig build test
zig build test-roms-ja -Doptimize=ReleaseFast
zig build test-roms-pl -Doptimize=ReleaseFast
```

Expected: all green, JA 12/17 with the identical five red, no PL floor re-pinned. **These three are the actual evidence that the deletion was behaviour-neutral**, because the trace goldens have been given up as an oracle for this one commit. Do not skip them.

- [ ] **Step 7: Re-capture**

```bash
zig build trace-golden -Doptimize=ReleaseFast -- capture
git diff --stat ps1-core/tests/goldens/trace/
```

Expected: all 8 goldens change; each stays 245 lines (5 header + 240 samples).

- [ ] **Step 8: Verify against the new baseline**

```bash
./zig-out/bin/ps1-golden verify
```

Expected: 8/8 OK.

- [ ] **Step 9: Commit — with the re-capture justified in the message**

```bash
git add ps1-core/src ps1-golden/src/state_hash.zig ps1-core/tests/goldens/trace
git commit -m "refactor(core): delete dead fields and dead SLTI/SLTIU ops; re-capture goldens

Removes three CdRom fields that were declared and never read or written
(xa_adpcm_filter, is_reading, autoreport_is_absolute) and two CPU
functions that were implemented but never dispatched (opSlti, opSltiu).

Goldens are re-captured here because hashCdrom folded those three fields
in, so dropping them changes every cdrom hash for a NON-behavioural
reason. This is the only re-capture in the P1-P8 refactor. Evidence the
deletion is behaviour-neutral comes from the other three gates, which did
not move: unit tests green, JA 12/17 with the identical five red, PL
passing with no floor re-pinned.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Task P9: Final verification and CLAUDE.md

- [ ] **Step 1: All four gates, from a clean build**

```bash
rm -rf .zig-cache zig-out
zig build
zig build test
zig build test-roms-ja -Doptimize=ReleaseFast
zig build test-roms-pl -Doptimize=ReleaseFast
zig build trace-golden -Doptimize=ReleaseFast -- verify
```

- [ ] **Step 2: Confirm the JA failure set is byte-identical to the starting five**

The five: `mdec/4bit`, `mdec/8bit`, `mdec/step-by-step-log`, `cdrom/timing`, `cdrom/getloc`. **A newly *passing* test is a failure of this refactor** — it means behaviour moved and must be explained before the work is accepted.

- [ ] **Step 3: Check every file is under ~600 lines**

```bash
wc -l ps1-core/src/*.zig ps1-core/src/*/*.zig | sort -rn | head -20
```

- [ ] **Step 4: Confirm all four frontends build**

`zig build` must produce `ps1-debug`, `ps1-trace`, `ps1-golden`, and the wasm `emulator`. Then check the wasm export ABI is intact — it is a hard contract with `ps1-wasm/www/index.html`, and a renamed export breaks the browser page silently:

```bash
grep -o "allocCdBuffer\|allocCueBuffer\|loadCdFromBuffer" ps1-wasm/src/main.zig | sort -u
```

- [ ] **Step 5: Update CLAUDE.md**

Rewrite the "Repository layout" tree for the new `cpu/`, `cop2/`, `gpu/`, `spu/`, `mdec/`, `cdrom/` directories. Confirm the GTE path correction from P4 landed. Add `constants.zig` / `bits.zig` and the Tier A/Tier B rule with its 3-ops/4-sites bar. Update the per-subsystem cheat-sheet's file references — every landmine note must point at the file that now holds the code.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for the post-refactor core layout

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01V94mWoqNcbbApv8hESVT7z"
```

---

## Definition of done

1. `zig build trace-golden -- verify` green on all 8 workloads.
2. `zig build test` green (9 unit files + `golden_test` + 2 ROM self-skips).
3. `zig build test-roms-ja` at **12/17 with the identical five red**.
4. `zig build test-roms-pl` green with **no floor re-pinned**.
5. All four frontends build; wasm exports unchanged.
6. `zig fmt` clean.
7. CLAUDE.md updated (layout, GTE path, Tier A/B rule).
8. No file in `ps1-core/src` over ~600 lines.
9. Goldens re-captured **exactly once**, in P8b, for a documented non-behavioural reason.

## Follow-ups — record here, fix after the refactor

Discovered while writing this plan, against the real code. **None of these are fixed during P1–P8.**

- **CD audio volume is not applied.** `volume_ll`, `volume_lr`, `volume_rl`, `volume_rr` are written by the ATV0-3 register writes and read by nothing. CD-XA and Red Book audio bypass the volume matrix entirely.
- **`memory.zig` dispatch as a declarative region table** — needs its own spec and its own precedence tests.
- **Multi-`FILE` cue support.** `Disc.initFromCue` takes one data slice, so Castlevania (2 FILEs) and Tekken (28 FILEs) cannot load. Becomes a real requirement for spec 2 — a game library that silently fails on multi-file rips is not shippable.
- **The Crash Bandicoot level-select hang.**
- **The 5 red JaCzekanski tests**, three of which are hangs, not mismatches.
- **`mdec` coverage gap:** pinned at one constant value in 5 of the 8 trace workloads. A bug confined to the non-FMV MDEC paths passes 5 goldens silently.
- **Whatever Metal Gear Solid: Special Missions turns out to break** — never run before the harness; its goldens pin current behaviour, bugs and all.
