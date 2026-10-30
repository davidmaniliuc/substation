# Booting executables (PS-X EXE, CPE, ELF) — design

Project 1 of 4 in the DuckStation format-parity work. The order, agreed
2026-10-30: **executables → easy disc formats (`.iso`/`.img`, `.ccd`, `.ecm`,
`.m3u`) → hard disc formats (`.pbp`, `.mds`) → PSF music player**. Each gets its
own design.

## Intent

DuckStation parity. DuckStation opens a bare executable as a game
(`core/system.cpp` `IsExePath`, `core/bus.cpp` `SideloadEXE`); we do not. The
owner has no particular workload in mind: the bar is "what DuckStation does",
not any one program working.

## Goals

- The macOS app opens `.exe`, `.psexe`, `.ps-exe`, `.psx`, `.cpe` and `.elf`
  from the library and the Open panel, and plays them like a game: a library
  tile, the shared memory cards, savestates, resume, runahead, rewind and every
  video/PGXP setting.
- The real BIOS boots with no disc in the drive. The moment the kernel finishes
  initialising, the program is put in RAM and run, with no shell and no logo,
  as DuckStation does.
- A `libps.exe` beside a PS-X EXE is loaded first, without taking the PC, as
  DuckStation does.
- The BIOS region comes from the PS-X EXE header's marker string
  (`"Sony Computer Entertainment Inc. for North America area"` / `Japan` /
  `Europe`, `bios.cpp` `GetPSExeDiscRegion`). Anything else, CPE and ELF
  included, falls back to the app's existing default BIOS choice.

## Non-goals

- PSF/miniPSF (project 4), any disc format (projects 2 and 3).
- The browser package, `ps1-trace`, `ps1-debug`. App only.
- Pairing an EXE with a disc (DuckStation's `-exe` override on a disc boot),
  and swapping a disc into a running EXE.
- Debug symbols from CPE/ELF.

## Anti-goals

- **No golden moves.** The JaCzekanski and PeterLemon suites and
  `ps1-golden`'s `.exe` workloads keep their current loader and their fixed
  instruction-count boot. Repointing them at the new path would be a behaviour
  change that needs a recapture, and that is a separate decision.
- **No savestate format bump** if it can be avoided (see Savestates).
- An EXE that fails to parse must be refused when it is opened, with an error,
  never booted into a hang.

## How it works (decided)

### The core: a loader module

A new `ps1-core/src/exe.zig` (re-exported from `root.zig`) parses the three
formats into one shape: a list of `(address, bytes)` segments, zero-fill
ranges, and an entry state (`pc`, and optionally `gp`, `sp`/`fp`). The format
is decided by the file's **content**, not its extension: `"PS-X EXE"`,
`"CPE\x01"` (`CPE_MAGIC` 0x01455043), `"\x7FELF"`. The extension only decides
which files the app offers. *(My call: DuckStation dispatches on the
extension, and a renamed file then fails for no visible reason.)*

- **PS-X EXE**: as `Cpu.loadExe` reads it today, plus the header's memfill
  range (`memfill_start & ~3`, `memfill_size` rounded down to 4) zeroed BEFORE
  the copy, and `fp = sp` whenever `sp != 0`. `bios.cpp` `IsValidPSExeHeader`
  is the validation reference.
- **CPE**: the chunked Psy-Q format (PSX-SPX "CDROM File Psy-Q CPE Files";
  `bus.cpp` `InjectCPE` is the behaviour reference).
- **ELF**: 32-bit little-endian MIPS, `PT_LOAD` segments, `memsz > filesz`
  zeroed, entry point as PC; no `gp`/`sp` (DuckStation sets none).

Every segment must land in main RAM (any KUSEG/KSEG0/KSEG1 mirror), or the
file is refused at parse time.

### When it runs: the kernel-init POST code

The BIOS writes its POST code to EXP2 `0x1F802041/42` (and EXP3
`0x1FA00000`); code **7** means the kernel is initialised. That write is the
trigger (`bus.cpp` `KernelInitializedHook`). Today the core treats EXP2 as
open bus and ignores the write.

- The armed program is **host configuration** on `Bus`, like `bios_patch`:
  never in a savestate. Arming it is "inject at the next POST 7"; injecting
  disarms it; a reset re-arms it.
- The MMIO write only RAISES the request. Injection happens between
  instructions/blocks, never inside a block: it rewrites RAM behind
  `Bus.write` and moves the PC, and the JIT rules forbid a handler doing
  either mid-block. The block cache is flushed (or the written pages dropped)
  and the I-cache reset, as `Cpu.loadExe` does.
- It works with BIOS fast boot on or off: the fast-boot patch skips the shell,
  which comes after kernel init.

### Savestates

The identity is BIOS hash + serial + PPF fingerprint. An EXE has no serial,
so its identity must carry a hash of the program bytes (the main EXE and any
`libps.exe`), so that a state from one program is refused on another
(`PS1_ERR_STATE_DISC`). The 16-byte serial field fits a tagged 64-bit hash
(for example `"EXE:"` + 8 hash bytes); prefer that over a container bump.
Because the armed program is not in the state, a state saved after injection
resumes correctly, and one saved before injection injects at the POST code
as a fresh boot would.

### The C ABI and session

- `ps1.h`: `ps1_load_exe(Ps1*, bytes, len, libps, libps_len)`, the bytes
  COPIED (they are small), returning a new `PS1_ERR_BAD_EXE` for a refused
  file. `ps1_identify_exe` returns the region and the identity hash, for the
  app's library scan, like `ps1_identify_disc`.
- `ps1_session.h`: the session settings carry the executable instead of a
  disc. This changes `Ps1SessionSettings`' size, which the existing size check
  already handles. Disc swap requests on an EXE session are refused.
- `ps1-wasm` keeps its error codes in step with `ps1.h` (`codes.zig`,
  `ps1-web/src/errors.ts`), as the rule requires, even though it gains no
  export.

### The app

- `GameScanner` and the Open panel accept the six extensions; `DiscKind`
  gains `.exe` (one case for all three formats, since the core sniffs).
- A tile is titled by the file name without its extension and gets the
  generic cover; covers already fall back to `pathKey` when there is no serial.
- Per-game settings and resume states key on the path, as for a serial-less
  disc today.
- A `libps.exe` beside an EXE is found the way a `.sbi` is, and is not itself
  listed as a game.

## Testing

- Unit tests per format in `ps1-core/tests/exe_test.zig` (added to
  `unit_test_files`), with tiny hand-built CPE and ELF buffers.
- A core test that boots the BIOS with an armed PeterLemon ROM through the new
  path and reaches its first frame, under the interpreter and `.jit`.
- `trace-golden -- verify`, both ROM suites, `capi_test` and the Swift suite
  unchanged.
- By hand in the app: one PS-X EXE, one CPE, one ELF; a savestate saved and
  resumed; a state from one EXE refused on another.

## Left to the builder

- Where exactly the injection runs between blocks (`Cpu.run`/`runFor` or the
  scheduler), as long as the JIT rules hold and `snapshot --engine=jit`
  stays green.
- Whether `Cpu.loadExe` becomes a thin wrapper over `exe.zig` for the
  harnesses, as long as their behaviour does not change.
- Where test CPE/ELF fixtures come from (hand-built in the test, or a
  committed file under `ps1-core/tests/`).
