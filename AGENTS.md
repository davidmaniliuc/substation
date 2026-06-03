# Antigravity: PS1 Emulator Project

_A high-performance PlayStation 1 emulator written in Zig._

## Project Philosophy

Antigravity aims for architectural clarity and cycle-accurate emulation where necessary. We prioritize maintainability by leveraging Zig’s comptime and safety features to map hardware registers directly to memory-mapped IO.

## Repository Structure

- `ps1-core/`: The heart of the emulator (CPU, GPU, SPU, CDROM, DMA).
- `src/`: Hardware implementation files.
- `tests/`: Integration tests and ROM-based hardware tests.

- `ps1-debug/`: CLI-based debugging harness for native development.
- `ps1-wasm/`: WebAssembly interface for browser-based playback.
- `test-roms/`: External suite for validation against known good hardware behavior.

---

## Escalation Path: How to Resolve "Lock-in"

When you hit a "Hard Wall" (an emulator freeze, a graphical glitch, or a register read/write that doesn't make sense), follow this hierarchy of resolution:

### 1. The "Golden" Sources (Primary References)

When logic breaks, stop guessing and check these in order:

1. **[NoCash PSX-SPX](https://psx-spx.consoledev.net/memorymap):** The "Bible" of PS1 hardware. If the behavior isn't documented here, it may not exist.
2. **[Lionel Flandrin's PSX Guide](https://github.com/simias/psx-guide):** Use this for understanding high-level system interactions and timing constraints.

### 2. Implementation Referencing (Comparative Analysis)

If you understand the theory but cannot figure out the _implementation_ in Zig:

1. **[JaCzekanski/Avocado](https://github.com/JaCzekanski/Avocado):** Use as the source of truth for C++ logic. When porting, look for how they handle timing, interrupt state machines, and FIFO management.
2. **[nupsx](https://www.google.com/search?q=https://github.com/mamedev/mame/tree/master/src/devices/cpu/psx) (or similar Zig projects):** Since your codebase is in Zig, refer to other Zig-based implementations for idiomatic ways to handle memory-mapped IO, volatile memory access, and `packed struct` union tricks.

### 3. The "Test-Driven" Debugger

If you are still stuck:

1. **Isolate the bug:** Write a minimal unit test in `ps1-core/tests/` that reproduces only the failure (e.g., a specific DMA transfer).
2. **Verify with `rom_test.zig`:** Check if any of the provided test ROMs cover the failing component.
3. **Trace Logging:** If a game is crashing, identify the last known good command. Use `std.log.warn` liberally to track the flow of `executeCommand` in `cdrom.zig` or `gpu.zig`.

---

## Roadmap / Next Steps

### 1. CPU & Coprocessors
- [ ] **R3000A Instruction Set:** Implement missing OPCODES, SPECIAL, and REGIMM instructions currently triggering warnings.
- [ ] **GTE (COP2):** Complete the geometry transformation engine math instructions (matrix/vector operations).
- [ ] **COP0 & Exceptions:** Ensure branch delay slots are accurately preserved during exceptions and interrupts.

### 2. GPU & Rendering Engine
- [ ] **GP1 Commands:** Handle unimplemented GP1 display control commands.
- [ ] **Texture Mapping:** Implement accurate TMU (Texture Mapping Unit) page caching, UV wrapping, and texture blending.
- [ ] **Dithering & Masking:** Support accurate 15-bit color dithering, transparency, and display mask bits.
- [ ] **VRAM Transfers:** Accurately implement VRAM-to-VRAM block copies and CPU-to-VRAM overlap logic.

### 3. SPU & Audio
- [ ] **ADSR Envelopes:** Implement accurate attack/decay/sustain/release curves for SPU voices.
- [ ] **Reverb & Delay:** Implement the SPU reverb matrix and delay effects.
- [ ] **CD-DA / XA-ADPCM:** Ensure audio streaming synchronizes perfectly with the SPU FIFO without drift.

### 4. CD-ROM & Disc Controller
- [ ] **Missing Commands:** Implement `GetID`, `ReadTOC`, `MotorOn`, `Stop`, and `Getparam` required by game boot sequences.
- [ ] **Error Handling:** Ensure invalid commands properly trigger `INT5` (Error) with the correct `0x40` error code instead of `INT3`.
- [ ] **Audio Modes:** Fully implement `ReadS` (Reading with no re-tries) and finalize XA-ADPCM sector filtering.

### 5. I/O & Peripherals
- [ ] **SIO (Serial I/O):** Add memory card file saving/loading and DualShock controller rumble logic.
- [ ] **MDEC:** Finalize the IDCT (Inverse Discrete Cosine Transform) logic for FMV (Full Motion Video) macroblock decoding.
- [ ] **Timers:** Verify root counter (Timers 0/1/2) precision against H-Blank and V-Blank synchronization.

### 6. Validation
- [ ] **Test ROMs:** Validate emulator behavior against community test suites (AmiDog, Peter Lemon, etc.) via `rom_test.zig`.

---

### Advice for the CD-ROM "Lock"

Since you are currently working on the CD-ROM:

- **Don't try to solve the whole thing at once.** Games typically boot by sending `0x01 (GetStat)` repeatedly. If your `GetStat` command returns the wrong status bits, the game's BIOS call will loop forever.
- **Check Avocado’s CDROM.cpp:** See exactly how they handle the `index` register. Many bugs in PS1 emulators stem from an incorrect `index` mapping, which causes commands to be written to the wrong internal register.
