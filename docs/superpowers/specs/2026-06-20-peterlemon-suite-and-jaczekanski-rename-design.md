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
3. Adds a framebuffer verification path for the PeterLemon ROMs (they are
   graphical demos with no `psx.log`) that compares our rendered display region
   against the **real reference image** shipped with each demo.

## Non-goals (YAGNI)

- No running of a second emulator (Avocado/Duckstation). The PeterLemon repo
  already ships a hardware-accurate 320×224 reference `.png` next to every demo;
  that is the gold standard. (Avocado has `GPU::dumpVram()` but it is GUI-only;
  building it headless would be redundant work.)
- No PNG decoder in Zig. Reference PNGs are pre-converted to raw RGB24 at import
  time with `ffmpeg`; the Zig harness only reads raw bytes.
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
- `peterlemon/` — PeterLemon/PSX (graphical demos, framebuffer-vs-reference-image).

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
    <category>/<rom>/
      <rom>.exe            (committed, PS-X EXE)
      reference.png        (committed, upstream 320×224 reference)
      reference.rgb        (committed, ffmpeg-converted raw RGB24, 215040 bytes)
      floor.txt            (committed golden: min matching-pixel count)
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
- Each ROM dir also gets the upstream `reference.png`, its `ffmpeg`-converted
  `reference.rgb`, and a committed `floor.txt` golden (see §3).

## 3. Verification harness (framebuffer vs. real reference image)

The gold standard is each demo's upstream 320×224 reference PNG. Our software
rasterizer diverges from hardware by design, so we compare **tolerantly**:
count how many display pixels match the reference, and pass if that count meets a
committed per-ROM floor (pinned to the currently-measured value). The reference
PNG is the oracle; the floor is only a regression guard on the conformance gap.

Add to `ps1-core/tests/rom_test.zig`, alongside the existing TTY harness:

### `runPlTest(allocator, exe_path, ref_rgb_path, floor_path, max_cycles)`

1. Gated by `options.enable_rom_tests` (same as `runRomTest`).
2. `Bus.init` → load `SCPH-1001_BIOS_1995_US.bin` → boot 25M cycles to init jump
   tables (same prelude as `runRomTestWithMode`).
3. `cpu.loadExe(exe_data)`.
4. Run a fixed `max_cycles` (no early-exit — demos render in an infinite loop;
   the frame is complete after a fixed cycle budget).
5. Extract the display region and count matches against the reference:
   - Constants `PL_W = 320`, `PL_H = 224` (the reference dimensions).
   - Display origin: `bus.gpu.disp_env.vram_x_start`, `.vram_y_start`.
   - `vram = bus.gpu.getVramPtr()` (`[*]const u16`, indexed `vy * 1024 + vx`).
   - Read `ref_rgb_path` (raw RGB24, `PL_W * PL_H * 3 = 215040` bytes).
   - For each `(x, y)` in `[0,320)×[0,224)`: read VRAM at
     `((oy + y) & 0x1FF) * 1024 + ((ox + x) & 0x3FF)`; decode RGB555
     (`r5 = v & 0x1F`, `g5 = (v>>5) & 0x1F`, `b5 = (v>>10) & 0x1F`); read the
     reference triple and reduce to 5-bit (`>>3`); increment `matches` when all
     three channels are equal. (Comparing in 5-bit space neutralizes
     ABGR1555→RGB888 expansion ambiguity, leaving only genuine raster
     differences.) Total pixels `PL_W * PL_H = 71680`.
6. Resolve the golden from `floor_path`:
   - **Update mode (`PS1_UPDATE_GOLDENS=1` in env):** write `matches` (decimal
     integer) to `floor_path` and pass, printing the match percentage. Detected
     via `std.process.getEnvVarOwned` (absent/empty ⇒ compare mode).
   - **Compare mode (default):** parse the integer floor from `floor_path`; print
     `matches`/71680 and the percentage; pass iff `matches >= floor`. Missing
     floor file → fail telling the user to run with `PS1_UPDATE_GOLDENS=1`.

Comparing matching *counts* (not floats) keeps the gate exact: rendering is a
pure function of executed cycles (no VRAM-touching RNG), so `matches` is
identical run-to-run and `matches >= floor` holds deterministically once pinned.

### Test cases

Add one `test "PL: <category> - <name>"` per curated ROM, each calling
`runPlTest(...)` with the ROM's `.exe`, `reference.rgb`, `floor.txt`, and a
per-ROM `max_cycles` (start ~10M, tune so the frame is fully drawn).

These bodies are **live** (not `if (false)`). After the one-time
`PS1_UPDATE_GOLDENS=1` pin they pass deterministically. The committed
`floor.txt` values double as a visible record of how close each demo currently
renders to real hardware — raise them as rasterizer fidelity improves.

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

1. Restructure + import ROMs (`.exe` + `reference.png` + `ffmpeg`→`reference.rgb`).
2. `PS1_UPDATE_GOLDENS=1 zig build rom-test` to generate `floor.txt` goldens.
3. `zig build rom-test` again to confirm the PeterLemon cases pass against the
   pinned floors.
4. `zig build test` still passes (ROM tests self-skip there).
5. Leave changes in the working tree (the user commits ROMs, goldens,
   restructure, and harness together themselves — agents do not run git).

## Affected files

- `test-roms/**` (restructured via plain `mv`; new `peterlemon/` tree; new
  top-level `README.md`). Git detects renames at the user's commit.
- `ps1-core/tests/rom_test.zig` (path updates + `runPlTest` + PL test cases).
- `build.zig` (step description only).
