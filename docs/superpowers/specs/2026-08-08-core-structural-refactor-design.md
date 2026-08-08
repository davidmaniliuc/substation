# Core structural refactor — design

**Date:** 2026-08-08
**Status:** approved, ready for planning
**Spec 1 of 3** on the road to a native macOS emulator.

---

## Why this exists

The long-term goal is a fully native macOS PS1 emulator: a SwiftUI frontend
driving `ps1-core` over a C ABI, with the GPU eventually rewritten in Metal.
`ps1-core` is not ready to be a library. It is ready to be an emulator — it
boots four real games — but its internals are dense enough that designing a
stable host-facing API against them, and later carving a Metal renderer out of
them, would mean fighting the code twice.

Measured state of `ps1-core/src` (20 files, 8,193 lines):

| Symptom | Measurement |
|---|---|
| Cast builtins | **1,089** (~13% of all lines) |
| Chained casts | **137** |
| Densest files | `alu.zig` and `gpu/renderer.zig` at 1 cast per 3 lines; `cop2.zig` and `spu.zig` at 1 per 4 |
| Largest struct | `CdRom` — **51 fields**, 23 methods, 1,067 lines |
| Next largest | `Spu` 38 fields, `Sio` 23, `Voice` 21, `Cpu` 20, `Gpu` 20 |
| Unnamed literals | `0xFF` ×48, `0x1F` ×46, `0x3FF` ×22, `0x8000` ×15, and so on |

## Sequencing

- **Spec 1 (this document):** core-wide structural refactor.
- **Spec 2:** native macOS app — C ABI static library, SwiftUI shell, emulator
  thread, CoreAudio output, GameController input, and a Metal *display* path
  (VRAM → texture → scaled blit). Ships a playable app on the existing software
  rasterizer.
- **Spec 3:** Metal *rasterizer* — primitive stream out of `gp0.zig`, VRAM as a
  render target, internal-resolution upscaling.

---

## The contract

Every commit in this work is **behaviour-identical and structurally different**.

Behaviour-identical means that for a fixed BIOS + disc + input script, the
emulator produces: the same instructions retired in the same order, the same
RAM and VRAM contents, the same SPU output samples, the same interrupt timing,
and the same device register values at every sample point.

It does **not** mean a small diff. Moving `CdRom`'s 51 fields into five
sub-structs rewrites hundreds of call sites. That is expected and in scope.

### In scope

All 20 files of `ps1-core/src`, including `cdrom.zig`, `cpu.zig`, `dma.zig` and
`memory.zig`:

- named constants for magic numbers
- extraction of repeated cast and bit-manipulation idioms
- deletion of duplicated code
- struct decomposition into sub-structs
- file splits mirroring `avocado_ref`'s layout

### Out of scope

- Any bug fix. Including the 5 red JaCzekanski tests and the open Crash
  Bandicoot level-select hang.
- Changing `Bus`'s inline ownership of devices. `Mdec` alone is ~768 KB by
  value; how devices are owned is a memory-layout decision, not cleanup.
- Converting `memory.zig`'s address dispatch from an ordered `if` chain into a
  declarative table (see Phase 8).
- The four frontends, beyond what a moved or renamed symbol mechanically forces.

### One consequence to accept

The refactor and the Crash blocker cannot proceed in parallel. Any intentional
behaviour change invalidates every trace golden. The order is: capture goldens →
refactor → re-capture → resume bug work.

---

## Step 1 — the trace-equivalence harness

**Nothing is refactored until this is built, green, and has captured goldens.**

The existing coverage — 9 unit-test files, JaCzekanski at 12/17, the PeterLemon
pixel ratchet — is strong for `cop2`, `spu` and `renderer`, and nearly absent
exactly where the riskiest refactors land. No automated test boots a game from
disc, so `cdrom.zig` and `cpu.zig` have no net at all. Those files are also the
ones CLAUDE.md fills with warnings ("ReadN's 1,000,000-cycle seek is
load-bearing — do NOT port it", "the keep-unread-bytes ACK logic is correct —
do not fix it"), which is precisely the class of thing a tidy-up breaks
silently.

### Shape

A new build step `zig build trace-golden`, backed by
`ps1-core/tests/trace_golden.zig` and a small runner. Two modes:

```
zig build trace-golden -- capture   # writes ps1-core/tests/goldens/trace/*.hash
zig build trace-golden -- verify    # exits nonzero on ANY divergence
```

`verify` output names the workload, the instruction count of the first
divergence, and which state region diverged:

```
  bios-only     240M instr   1920 hashes   OK
  croc.cue      240M instr   1920 hashes   OK
  silent-hill   240M instr   1920 hashes   OK
  spyro.cue     240M instr   1920 hashes   OK
  crash.cue     240M instr   1920 hashes   FAIL @ instr 41,500,000
                              first diff: cdrom
```

### What it hashes

Every M instructions (default 125,000 — about 1,920 samples over a
240M-instruction run), fold machine state into per-region hashes and append one
record:

```
{ instr_count,
  hash_ram, hash_scratchpad, hash_vram,
  hash_cpu,      // regs, pc/next_pc/current_pc, load-delay pairs, COP0, GTE
  hash_cdrom, hash_spu, hash_gpu, hash_dma,
  hash_timer, hash_sio, hash_mdec, hash_interrupt }
```

Two decisions that carry weight:

**Per-region hashes, not one blob.** When a refactor breaks something,
"first diff: `cdrom`" *is* the debugging session. A single whole-machine hash
tells you only that you are wrong.

**Device dumps are written by hand, never by reflection.** An
`inline for (std.meta.fields(T))` would be shorter, and it would silently change
what is covered the moment a refactor moves a field into a sub-struct — the
check would follow the refactor instead of policing it. An explicit list of what
to hash is the entire point. When a phase moves fields, the dump is updated in
the same commit to name the new paths, and the hashes must still match.

### Workloads

- `bios-only` — boots the BIOS with no disc. Always runnable on any machine,
  including a fresh clone with no game images.
- One entry per real disc: Croc, Silent Hill, Spyro, Crash Bandicoot.

Disc paths come from a gitignored `ps1-core/tests/trace_manifest.txt`:

```
croc        = /absolute/path/to/croc.cue
silent-hill = /absolute/path/to/sh.cue
```

A missing entry **skips with a printed warning** rather than failing, so the
harness is usable on a machine without disc images. `.cue` is required rather
than raw `.bin` wherever a game has audio tracks — `Disc.init`'s
single-data-track-at-LBA-0 fallback cannot represent them.

Input is deterministic: the existing `autostart` button script, driven off
instruction count rather than wall clock.

### Goldens

Checked in. Each record is 12 hashes plus an instruction counter — 104 bytes at
64-bit hashes — so a 1,920-sample workload is roughly 200 KB. They are reproducible
because the core has no wall-clock reads, no threading, and no uninitialised
state — `Bus.init` re-runs every device `.init()` after its `@memset(0)`.

Goldens are regenerated **only** when an intentional behaviour change lands, and
that regeneration is always its own commit whose message explains the diff.

### Validating the harness itself

Before the harness is trusted, deliberately flip one bit of behaviour — change
`ack_delay` in `cdrom.zig` from `50000` to `49999` — and confirm that `verify`
fails and names `cdrom`. Then revert. A verifier that has never failed is not
known to work. This check is part of Phase 0's definition of done.

---

## Phases

Nine phases, one commit each, ordered by **ascending risk**, so the extraction
vocabulary is settled on well-covered files before it reaches the landmines.

**Every phase must leave all four of these green:** `zig build test`,
`zig build test-roms-ja` (12/17, the same five red), `zig build test-roms-pl`,
and `zig build trace-golden -- verify`.

| Phase | Work | Verified by |
|---|---|---|
| **P0** | trace harness + captured goldens + injected-bug self-check | self |
| **P1** | new `constants.zig` and `bits.zig`; apply to `alu.zig` | `cpu_test`, `gte_test` |
| **P2** | `gpu/` — extract `color.zig` (blending, 15/24bpp, STP) and `primitive.zig` (vertex/tex decode) out of `renderer.zig` and `gp0.zig`, taking `renderer.zig` under 600 lines; clean `vram`, `registers` | PeterLemon ratchet, `gpu_test` |
| **P3** | `spu.zig` → `spu/{spu,voice,adsr,reverb,noise,gauss,regs}.zig` | reverb goldens, `spu_test` |
| **P4** | `cop2.zig` → `cop2/{cop2,math,opcodes}.zig` | 1,150 `gte/test-all` cases |
| **P5** | `mdec.zig` → `mdec/{mdec,algorithm}.zig`; clean `disc`, `timer`, `interrupt`, `sio` | `mdec_test`, `disc_test`, `sio_test` |
| **P6** | `cdrom.zig` → `cdrom/{cdrom,commands,fifo,xa,cdda}.zig` | **trace goldens only** |
| **P7** | `cpu.zig` → `cpu/{cpu,icache,exec}.zig` | **trace goldens only** |
| **P8** | `dma.zig`, `memory.zig` — naming only | **trace goldens only** |

### Mirroring avocado_ref

CLAUDE.md's standing rule is "diff against `avocado_ref` first". Matching its
file boundaries makes every future port and bug-hunt cheaper, so the splits
follow its real layout:

- `avocado_ref/src/device/spu/{spu,voice,adsr,reverb,noise,interpolation,regs}`
- `avocado_ref/src/cpu/gte/{gte,math,opcodes}`
- `avocado_ref/src/device/cdrom/{cdrom,commands,fifo}`
- `avocado_ref/src/device/mdec/{mdec,algorithm}`
- `avocado_ref/src/device/gpu/{gpu,psx_color,primitive,registers,render/}`

**Note:** CLAUDE.md currently states GTE lives at `avocado_ref/src/device/gte/`.
It does not — the real path is `avocado_ref/src/cpu/gte/`. Fix this in CLAUDE.md
as part of P4.

Two deliberate deviations from Avocado:

1. We split `xa.zig` and `cdda.zig` out of the CDROM even though Avocado keeps
   both inside `cdrom.cpp`. They are self-contained decoders and each has its
   own documented trap set.
2. We do **not** follow Avocado's seven-files-per-DMA-channel layout. Our single
   `Channel` struct is 14 fields; splitting it seven ways is cargo-culting.

### Why P8 is naming only

`memory.zig`'s read/write dispatch is a roughly 30-deep `if (paddr == ...)`
chain whose **order is load-bearing**. Special cases sit deliberately ahead of
the general ranges that would otherwise swallow them — the `0x1F801DA8`
word-read fixup that keeps the SPU transfer FIFO and SPUCNT apart, the
`0x1F801108` Timer1 shadow, the CDROM byte-lane handling at
`0x1F801800..0x1F801803`.

So P8 gives every literal a name (`Addr.gpu_stat`, `Addr.spu_range`,
`Addr.cdrom_base`) and changes nothing else. Converting the chain into a
declarative region table is excluded from this spec entirely: it is the one
change here capable of reordering precedence invisibly, and it deserves its own
spec with its own targeted tests.

---

## What gets extracted

The chief risk is trading cast soup for **helper soup** — forty tiny wrappers
nobody can remember. Two tiers, with an explicit bar.

### Tier A — no new API

Zig infers a cast's target from its result location, so:

```zig
const s = @as(i32, @bitCast(a));   // before
const s: i32 = @bitCast(a);        // after
```

This dissolves a large share of the 137 chained casts on its own, including most
of `alu.zig` (`@as(i32, @bitCast(a))` recurs in `add`, `sub`, `mult`, `div`).
No abstraction, no review burden. **Tier A is always preferred over Tier B.**

### Tier B — a named helper

Introduced only when an idiom is **three or more operations** *and* appears
**four or more times**. The ones that currently clear the bar:

| Helper | Replaces | Sites |
|---|---|---|
| `bits.sext16(u16) u32` | `@as(u32, @bitCast(@as(i32, @as(i16, @bitCast(v)))))` | `cop2.zig:48` and friends |
| `reverbAddr(reg) u32` | `@as(u32, @as(u16, @bitCast(reverb_regs[i]))) * 8` | ~20 lines, `spu.zig:565-590` |
| `Vram.index(x, y) usize` | `y * 1024 + x` | `vram.zig:75,114,158,170`, `renderer.zig:16` |
| `DrawingEnv.clipRect()` | the 4-line `@as(i16, @intCast(area_top_left & 0x3FF))` unpack | head of `putPixel`, re-derived per renderer entry point |
| `adsr.expStep()` | the signed-negate-around-shift dance | `spu.zig` ADSR paths |

### Constants, in two scopes

A shared `ps1-core/src/constants.zig` holds **only** genuine cross-module
hardware facts:

```zig
pub const vram_width = 1024;
pub const vram_height = 512;
pub const sector_bytes = 2352;
pub const lead_in_frames = 150;
pub const cpu_clock_hz = 33_868_800;
```

Everything else is a module-private `const` block at the top of its own file:
`stp_bit = 0x8000`, `coord_mask = 0x3FF`, the CDROM `ack_delay` family.

`0x1F` appearing 46 times is **not one constant** — it is a 5-bit colour channel
in `renderer.zig` and an ADSR shift field in `spu.zig`. Merging them would be
worse than leaving them bare.

### Anti-goals

- No helper for a single call site.
- **No hardware-quirk comment is deleted.** CLAUDE.md's landmine comments are
  the most valuable prose in the repository, and a tidy-up is exactly how they
  get lost. When code moves, its comment moves with it.
- No behaviour "improvement" noticed in passing. If a phase uncovers a real bug,
  it is written down and left alone until the refactor is finished.

---

## Error handling and failure modes

There is no runtime error handling to design here — the refactor introduces no
new failure paths. The failure modes that matter are process ones:

| Failure | Response |
|---|---|
| `trace-golden verify` fails mid-phase | Phase is not splittable further: `git reset` and redo in smaller steps. Never "fix" the golden. |
| A phase reveals a real bug | Record it in the spec's follow-ups list. Do not fix it during the refactor — it would invalidate every golden. |
| Goldens unavailable (no disc images) | `bios-only` still runs and still gates. Phases P6–P8 are **blocked** without at least two disc workloads, since those are the only net for `cdrom` and `cpu`. |
| A moved field breaks the hand-written state dump | Update the dump in the same commit; the hashes must still match. A dump that no longer compiles is the harness doing its job. |

---

## Testing

No new unit tests are written as part of this work — new tests would assert
behaviour, and behaviour is frozen. The verification story is entirely the four
existing gates plus the new trace harness.

One addition to the definition of done for the whole spec: after P8, re-run
`zig build test-roms-ja` and confirm the failure set is byte-identical to the
current five (`mdec/4bit`, `mdec/8bit`, `mdec/step-by-step-log`, `cdrom/timing`,
`cdrom/getloc`). A *changed* failure — even a newly passing test — means
behaviour moved and must be explained before the refactor is accepted.

---

## Definition of done

1. `zig build trace-golden -- verify` green on every available workload.
2. `zig build test` green (9 unit-test files).
3. `zig build test-roms-ja` at 12/17 with the identical five red.
4. `zig build test-roms-pl` green against current floors, with **no floor
   re-pinned** — a changed pixel count means changed behaviour.
5. All four frontends still build: `zig build` produces `ps1-debug`,
   `ps1-trace`, and the wasm `emulator`.
6. `zig fmt` clean.
7. CLAUDE.md updated: new file layout, the `avocado_ref` GTE path correction,
   and a section documenting the trace harness.
8. No file in `ps1-core/src` over ~600 lines.

## Follow-ups this spec deliberately defers

- `memory.zig` dispatch as a declarative region table.
- The Crash Bandicoot level-select hang.
- The 5 red JaCzekanski tests.
- Any bug discovered during the refactor and recorded rather than fixed.
