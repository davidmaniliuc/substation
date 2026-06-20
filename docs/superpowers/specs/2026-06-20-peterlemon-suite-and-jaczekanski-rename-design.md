# Design: Add PeterLemon/PSX suite + rename JaCzekanski suite

Date: 2026-06-20
Status: Approved (pending spec review)

## Goal

The `test-roms/` directory currently holds a single ROM suite — JaCzekanski's
`ps1-tests` — dumped directly at the top level and consumed by
`ps1-core/tests/rom_test.zig` via a TTY-output-vs-`psx.log` text comparison.

This change:

1. Restructures `test-roms/` so each suite lives in its own subdirectory.
2. Adds a second suite, a curated starter set from
   [`github.com/PeterLemon/PSX`](https://github.com/PeterLemon/PSX).
3. Adds a framebuffer-hash verification path for the PeterLemon ROMs, since they
   are graphical demos with no `psx.log`.

## Non-goals (YAGNI)

- No PNG dumping for human inspection — hash comparison only.
- No Avocado/real-hardware conformance goldens. Our software rasterizer is
  documented to diverge from hardware (no texture/CLUT cache, hand-tuned cycle
  costs, quad diagonal seams), so the goldens are **self-pinned regression
  baselines**, not correctness oracles.
- No raw-binary loader. PeterLemon demos are PS-X EXE format and load via the
  existing `cpu.loadExe()`.
- Do **not** re-enable the shelved JaCzekanski / `cdrom/getloc` test bodies.
  They keep their current `if (false)` state.

## 1. Directory restructure

Move the entire current contents of `test-roms/` into `test-roms/jaczekanski/`
using `git mv` (preserves history):

- Category dirs: `cdrom/ cpu/ dma/ gpu/ gte/ gte-fuzz/ input/ mdec/ spu/
  timer-dump/ timers/ tools/`
- Suite docs: `README.md`, `CONTRIBUTORS.md`

Create `test-roms/peterlemon/` for the new suite.

Add a new top-level `test-roms/README.md` describing the two suites and their
upstream sources:
- `jaczekanski/` — JaCzekanski/ps1-tests (hardware-conformance, TTY/`psx.log`).
- `peterlemon/` — PeterLemon/PSX (graphical demos, framebuffer-hash regression).

Resulting layout:

```
test-roms/
  README.md                (new, describes both suites)
  jaczekanski/
    README.md              (moved, original suite readme)
    CONTRIBUTORS.md        (moved)
    cdrom/ cpu/ dma/ gpu/ gte/ ...   (moved)
    tools/                 (moved)
  peterlemon/
    <Category>/<Rom>/
      <rom>.exe            (committed, PS-X EXE)
      vram.hash            (committed golden)
```

## 2. PeterLemon suite contents (curated starter set)

Fetch ~5–8 ROMs from `github.com/PeterLemon/PSX` covering subsystems the
emulator supports well: one CPU test plus GPU primitive demos. Intended
coverage (exact upstream filenames/paths confirmed during fetch):

- A CPU arithmetic/basic test.
- GPU Polygon (flat + gouraud if available as separate demos).
- GPU Line.
- GPU Sprite / Rectangle.
- GPU Texture.

Storage rules:

- Commit each executable with an **`.exe`** extension. The repo's `.gitignore`
  excludes `*.bin`; using `.exe` (as JaCzekanski already does) avoids editing
  `.gitignore` or force-adding. If an upstream file is named `.bin`, rename to
  `.exe` on import — the bytes are unchanged PS-X EXE.
- Each ROM dir gets a committed `vram.hash` golden (see §3).

## 3. Verification harness (framebuffer hash, self-pinned)

Add to `ps1-core/tests/rom_test.zig`, alongside the existing TTY harness:

### `runPlTest(allocator, exe_path, golden_path, max_cycles)`

1. Gated by `options.enable_rom_tests` (same as `runRomTest`).
2. `Bus.init` → load `SCPH-1001_BIOS_1995_US.bin` → boot 25M cycles to init jump
   tables (same prelude as `runRomTestWithMode`).
3. `cpu.loadExe(exe_data)`.
4. Run a fixed `max_cycles` (no early-exit — demos render in an infinite loop;
   the frame is complete after a fixed cycle budget).
5. Hash VRAM: read `bus.gpu.getVramPtr()` as `[*]const u16` over
   `1024 * 512` halfwords (1 MB), hash with `std.hash.Wyhash` using a fixed seed
   (e.g. `0`). Format as a lowercase hex string.
6. Read the golden from `golden_path`:
   - **Compare mode (default):** mismatch → print expected vs got hash and
     `return error.RomOutputMismatch`. Missing golden file → fail with a clear
     message telling the user to run with `PS1_UPDATE_GOLDENS=1`.
   - **Update mode (`PS1_UPDATE_GOLDENS=1` in env):** write the computed hash to
     `golden_path` (creating it) and pass. Detected via
     `std.process.getEnvVarOwned` (treat absent/empty as compare mode).

Determinism: rendering is a pure function of executed cycles. The only RNG in
the core is SPU noise, which never writes VRAM, so a fixed `max_cycles` yields a
stable VRAM hash across runs.

### Test cases

Add one `test "PL: <category> - <name>"` per curated ROM, each calling
`runPlTest(...)` with `test-roms/peterlemon/.../<rom>.exe`,
`test-roms/peterlemon/.../vram.hash`, and a per-ROM `max_cycles` (start ~10M,
tune so the frame is fully drawn).

These bodies are **live** (not `if (false)`): goldens are self-pinned, so after
the one-time `PS1_UPDATE_GOLDENS=1` pin they pass deterministically.

Existing JaCzekanski test bodies are untouched (remain `if (false)`), only their
path strings change to `test-roms/jaczekanski/...`.

## 4. Path + build updates

- `rom_test.zig`: update every `"test-roms/..."` literal in the JaCzekanski test
  cases to `"test-roms/jaczekanski/..."`.
- `build.zig`: the ROM paths are not referenced here (they live in
  `rom_test.zig`), so only the step description changes:
  `"Run JaCzekanski PS1 ROM integration tests"` →
  `"Run PS1 ROM integration tests (JaCzekanski + PeterLemon)"`. A single
  `rom-test` step continues to run both suites' cases.

## 5. One-time pin + verification

1. Restructure + import ROMs.
2. `PS1_UPDATE_GOLDENS=1 zig build rom-test` to generate `vram.hash` goldens.
3. `zig build rom-test` again to confirm the PeterLemon cases pass against the
   pinned goldens.
4. `zig build test` still passes (ROM tests self-skip there).
5. Commit ROMs, goldens, restructure, and harness together.

## Affected files

- `test-roms/**` (restructured via `git mv`; new `peterlemon/` tree; new
  top-level `README.md`).
- `ps1-core/tests/rom_test.zig` (path updates + `runPlTest` + PL test cases).
- `build.zig` (step description only).
