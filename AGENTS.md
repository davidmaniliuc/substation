# Antigravity: PS1 Emulator Project

_A high-performance PlayStation 1 emulator written in Zig._

## Project Philosophy

Antigravity aims for architectural clarity and cycle-accurate emulation where necessary. We prioritize maintainability by leveraging Zig’s comptime and safety features to map hardware registers directly to memory-mapped IO.

## Repository Structure

- `ps1-core/`: The heart of the emulator (CPU, GPU, SPU, CDROM, DMA).
- `src/`: Hardware implementation files.
- `tests/`: Integration tests and ROM-based hardware tests.

- `ps1-debug/`: CLI-based debugging harness for native development.
- `ps1-trace/`: Native execution-diff / component-boundary tracer used to chase real-game bugs.
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
2. **Verify with the ROM suites:** `zig build test-roms-pl` / `test-roms-ja` — check if any provided test ROM covers the failing component.
3. **Trace Logging:** If a game is crashing, identify the last known good command. `cdrom.zig`/`memory.zig` already carry logging gated on `cdrom.debug_enable`.
4. **Execution diff:** For real games, run `ps1-trace` headless and diff PCs against Avocado's tracer, anchored on an event (syscall, GP0 or CD command) — never on cycle counts, since Avocado bills 1 cycle per instruction and is waitstate-blind.

---

## Roadmap / Next Steps

### 1. CPU & Coprocessors
- [x] **R3000A Instruction Set:** Implement missing OPCODES, SPECIAL, and REGIMM instructions currently triggering warnings.
- [x] **GTE (COP2):** Complete the geometry transformation engine math instructions (matrix/vector operations).
- [x] **COP0 & Exceptions:** Ensure branch delay slots are accurately preserved during exceptions and interrupts.

### 2. GPU & Rendering Engine
- [x] **GP1 Commands:** Handle unimplemented GP1 display control commands.
- [x] **Texture Mapping:** Implement accurate TMU (Texture Mapping Unit) page caching, UV wrapping, and texture blending.
- [x] **Dithering & Masking:** Support accurate 15-bit color dithering, transparency, and display mask bits.
- [x] **VRAM Transfers:** Accurately implement VRAM-to-VRAM block copies and CPU-to-VRAM overlap logic.

### 3. SPU & Audio
- [x] **ADSR Envelopes:** Implement accurate attack/decay/sustain/release curves for SPU voices.
- [x] **Reverb & Delay:** `doReverb` is wired into the mix at 22.05 kHz behind `spu.reverb_enable` (default on), gated on SPUCNT bit 7, with a live CD send (bit 2) and an external send (bit 3) that's wired but inert — nothing produces external audio yet. Pinned against goldens generated from Avocado's own `spu::doReverb`.
- [x] **CD-DA / XA-ADPCM:** Ensure audio streaming synchronizes perfectly with the SPU FIFO without drift.

### 4. CD-ROM & Disc Controller
- [x] **Timing Accuracy:** Accurately implement command delays and interrupt queuing to match exact cycle delays from actual hardware (and references like Avocado). The current `ack_delay` and interrupt timing cause test failures and event timeouts.
- [x] **State Machine Fidelity:** Ensure the internal CDROM state machine accurately updates bits like `RXFIFO empty`, `Motor On`, and parameter push/pop lengths so that BIOS routines loop correctly.
- [x] **Missing Commands:** Implement `GetID`, `ReadTOC`, `MotorOn`, `Stop`, `Getparam`, `Forward`, `Backward`, `SetSession`, `Test` subcommands, and `Unlock` required by game boot sequences.
- [x] **Error Handling:** Ensure invalid commands properly trigger `INT5` (Error) with the correct `0x40` error code instead of `INT3`.
- [x] **Audio Modes:** Fully implement `ReadS` (Reading with no re-tries) and finalize XA-ADPCM sector filtering.
- [x] **Interrupt Edge Cases:** Correctly manage nested `CDROM_REG(3)` interrupt acknowledgments when polling vs BIOS handler event delivery. Queue popping fixed when FIFO is empty and ACK'd.
- [x] **DMA Transfers:** Fixed `1F801802` special exception for 32-bit DMA reads to correctly pull 4 bytes consecutively from the data FIFO.

### 5. I/O & Peripherals
- [~] **SIO (Serial I/O):** Memory-card read/write commands run against an in-memory 128 KB image, but **nothing persists it** to a file. The pad reports as digital only — the DualShock escape commands (`0x43`/`0x44`) and rumble are not implemented.
- [x] **MDEC:** Block decode ported from Avocado (qFactor, uploaded IDCT table, clamping, +128 bias, dense 24bpp pack) and unit-tested.
- [x] **Timers:** Verify root counter (Timers 0/1/2) precision against H-Blank and V-Blank synchronization.

### 6. Validation
- [~] **Test ROMs:** The PeterLemon/PSX suite (`zig build test-roms-pl`) runs green as a pixel-match ratchet. The JaCzekanski suite (`test-roms-ja`) exists but is shelved — most tests still fail.

### 7. Core Emulation Fidelity & Timing
- [x] **Instruction Fetch Timing:** Validate cycle penalties for instruction fetching across different memory regions (Scratchpad vs RAM vs ROM).
- [~] **DMA & Bus Arbitration:** Cycle-by-cycle stealing and chopping windows are implemented. **Channel priority is not** — `dma.zig` runs a fixed 0..6 loop (which matches Avocado). Chopping also mixes "words" and "cycles" as one counter.
- [x] **Cache Emulation:** Implement I-Cache line fetching behavior, miss penalties, and isolate execution timing variations. Validate 4-word burst reads from main RAM.
- [x] **Memory Waitstates:** Accurate waitstate emulation for BIOS/ROM area (Waitstate 1) and external peripherals (Waitstate 2).

### 8. Graphics Pipeline Accuracy
- [x] **GPU FIFO:** Add strict limits (16-word FIFO) to the GPU command FIFO and implement CPU stalls when writing to a full FIFO.
- [x] **Triangle Rasterization Rules:** Verify "top-left rule" rasterization consistency with actual hardware to eliminate seam rendering artifacts in adjacent polygons. Implement proper edge-walking logic or fixed-point rasterization precision.
- [x] **VRAM Display Masking:** Mask-bit handling lives in `putPixel`; a drawn pixel keeps its **source** texel's bit15. Note fill/copy rects still bypass it.
- [x] **VRAM Display Area:** Fix any alignment or wrap-around artifacts when drawing outside the physical 1024x512 VRAM coordinates.
- [x] **Interlaced Mode:** Implement the half-scanline offset for V-blank in interlaced video modes.

### 9. Audio Fidelity
- [x] **SPU Interpolation:** Transition from basic linear resampling to accurate 4-point Gaussian interpolation for SPU pitch shifting, utilizing the exact hardware lookup table.
- [x] **Noise Generator:** Validate noise generator frequency stepping and pseudo-random polynomial generation against hardware reference.
- [x] **Reverb Buffer Clamping:** Ensure all reverb matrix accumulated results clamp exactly as hardware does to prevent audio popping. Validate Reverb wrap-around behavior.
- [x] **SPU DMA Timing:** Synchronize SPU DMA block transfers (FIFO) to prevent audio skipping during intense CD-ROM loading sequences.

### 10. Front-End and Integrations
- [ ] **Save State Infrastructure:** Serialize all component states (CPU, GPU, RAM, Timers) for deterministic save states.
- [ ] **Debugger GUI Enhancements:** Connect memory view, disassembler, and VRAM viewer directly into the WASM interface.
- [ ] **CD-ROM Swapping:** Implement virtual lid open/close and disc swapping for multi-disc games.

### 11. Advanced WASM Integration
- [x] **Browser File System API:** The page loads BIOS, EXE, `.bin` and `.cue` directly, including via a directory picker.
- [ ] **Web Workers:** Move the core emulation loop into a Web Worker to prevent UI thread blocking and improve frame pacing.
- [ ] **Audio Worklets:** Use modern AudioWorklets to handle low-latency SPU audio output without buffer underruns.

### 12. Input & Peripherals Accuracy
- [ ] **Controller Polling Timing:** Refine the Serial I/O (SIO) timing behavior to accurately emulate DualShock poll cycles and baud rates.
- [ ] **Memory Card Edge Cases:** Ensure memory card file system saves match actual hardware behavior, avoiding corruption in strict games.

### 13. System Resilience
- [ ] **BIOS HLE (High-Level Emulation):** Implement an alternative HLE BIOS to allow booting games without requiring proprietary `SCPH-1001.BIN`.
- [ ] **Automated CI/CD:** Establish an automated GitHub Actions pipeline to run `psx-spx` and Avocado test suites on every commit.

---

### Advice for the Graphics & Timing "Lock"

As we transition into GPU and Timing fidelity:
- **GPU Rasterization:** Be incredibly careful with fixed point math. Differences between `floor` and `trunc` on fixed-point numbers will cause visual seams in games like *Crash Bandicoot* or *Tomb Raider*.
- **DMA Block Chopping:** The PS1 DMA isn't instant. It pauses the CPU, but when "chopping" is enabled, the CPU can interleave instructions. Do not block the entire CPU step for the duration of a DMA transfer.
- **Consult the Golden Sources:** Always cross-reference the timing section in `NoCash PSX-SPX` for cycle penalties!
