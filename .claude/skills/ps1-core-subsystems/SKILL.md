---
name: ps1-core-subsystems
description: Use when touching ps1-core CPU, COP0, ALU, GTE/COP2, SPU, DMA, MDEC, memory.zig, interrupt.zig, timer.zig or sio.zig, or ps1-core/src/savestate/ - the per-subsystem sharp edges. Covers the load-delay pipeline and I-cache, GTE MAC/IR saturation rules, SPU reverb and ADSR, DMA transfer rates and sync modes, MDEC status bits, the memory card and pad protocols, and per-peripheral ACK delays.
---

# Core subsystem cheat-sheet

**CPU / COP0 / ALU** (`cpu/{cpu,icache,exec}.zig`, `cop0.zig`, `alu.zig`)
- Triple-PC pipeline (`pc`/`next_pc`/`current_pc`) + dual load-delay pairs
  (`load_r/v`, `delay_r/v`) model branch-delay and load-delay slots. Interrupts
  are never taken in/just-before a delay slot.
- I-cache: 256 direct-mapped lines, cacheable only KUSEG/KSEG0 (not KSEG1), tag =
  vaddr & `0xFFFFF000` (virtual, so KUSEG/KSEG0 alias to different lines). Miss
  burst from RAM is a hardcoded **+7 cycles** (`cpu/icache.zig:37`). SR IsC rising edge
  flushes the whole I-cache.
- **An interrupt is never taken on a GTE command instruction**
  (`is_gte_command`, `cpu/cpu.zig`). Hardware has already issued the operation
  when the exception is recognised, so the BIOS handler *deliberately returns to
  EPC+4*: it reads the instruction at EPC and skips it when
  `(instr >> 24) & 0xFE == 0x4A`, the COP2-command encoding (kernel handler at
  `0x00000cc0`). Discard the instruction here and the handler's skip drops the
  operation outright: the GTE silently keeps its previous result. That is how
  Silent Hill got a stale colour-FIFO entry whose CODE byte turned an 8-word
  POLY_G4 into a 12-word POLY_GT4 and tore the rest of the display list.
  **Avocado has this bug too** (`CPU::checkForInterrupts`, no GTE case), so it is
  not an oracle here; diffing against it shows nothing. Pinned by a test in
  `cpu_test.zig`.
- PS1 div/mult quirks in `alu.zig:53-77` (div-by-0, INT_MIN/-1); computed instantly.
- SLTI/SLTIU dispatch through `iOpSignExt` + `alu.slt`/`sltu`. The unused
  `opSlti`/`opSltiu` that used to shadow that path were deleted in the P1-P8
  refactor; don't reintroduce them.
- **The scheduler** (`cpu/scheduler.zig`, state on `bus.sched`) is exact, and
  `scheduler_test.zig` proves it against a machine forced onto the slow path
  every step, byte for byte through a savestate. Three things keep it exact:
  `deadline` names every device countdown; every MMIO access (and `dmaRead32`'s
  SPU branch) calls `sync` first, so `downcount = 0` makes the step in progress
  re-derive the deadline after the access; and a DMA-stalled step is always
  slow, because a DMA word can arm a block gap or chop turn without touching a
  register. A host-side poke that zeroes a device countdown (`catchUp`) must
  `sync` first, as `ps1-golden`'s sample point does. Measured on 2026-10-03:
  Croc 3.30x -> 4.31x, PGXP-on 2.76x -> 3.65x; interpreter share 13.6% (xctrace).

**GTE / COP2** (`cop2/{cop2,math,opcodes}.zig`): **now a faithful Avocado port**, not the old
heuristic implementation. It has the real UNR reciprocal table + Newton-Raphson
`divideUNR` (`cop2/math.zig:23`), proper RTPS/RTPT projection with IR0 and
depth cueing, `farColor()` and the shared `depthCueWithRgbc` path used by
NCDS/NCDT/NCCS/CC/CDP (which correctly fold in the RGBC vertex colour), and
MAC1..3 write back the **sf-shifted** value so `mfc2` reads what hardware reads.
**It passes all 1150 `gte/test-all` cases**: treat that suite as the ratchet
before touching anything here.

MAC0..3 live in a separate `macs: [4]i64`, **not** `data_regs[24..27]`, but they
are **32-bit registers**: `storeMac` narrows on the way in, because the 44-bit
width belongs to the accumulator, not the register. Everything that reads a MAC
back (`mfc2`, the colour FIFO's `>> 4`, GPL's `<< sf` re-scale) must see the
narrowed value. Two more rules that cost real debugging time: **IR saturation
raises the same FLAG bit in both directions** (24/23/22, never the colour-FIFO
bits 21/20/19), and **IR is clipped from the low 32 bits of MAC**, which at sf=0
routinely disagrees in sign with the whole. MAC overflow trips at ±2^43.

`try` → field `try_`. The MVMVA matrix/translation selector bits were once
swapped: if 3D geometry is subtly wrong, re-check the operand decode first.
MVMVA's `mx=3` and `cv=2` select documented hardware *bugs*, not a second copy
of RT and an ordinary far-colour translation; OP crosses IR with the RT
diagonal, not its third column.

**SPU** (`spu/`): **reverb is live.** `doReverb` runs at 22.05 kHz (even
samples only; the odd sample re-adds the held `reverb_out_l/r`), after the
CD/external mixes and before main volume, behind `reverb_enable` (default on:
a host toggle, not hardware). Three rules that were all wrong before: SPUCNT
bit 7 gates the reverb SRAM **writes only**; reads still happen and
`reverb_curr_addr` still advances, so the gate lives inside `writeReverbSram`;
a write to 0x1F801DA2 must **rewind `reverb_curr_addr` to `base * 8`**; and
every reverb add/subtract **saturates to i16 individually**, because Avocado's
`Sample` type clamps on each `+`/`-` but not on `*`; summing the four comb
terms into one i32 and clamping once gives a different answer. `doReverb` is
pinned by two goldens (impulse + pseudo-random, 512 pairs each) generated from
Avocado's own `spu::doReverb`; regenerate via
`avocado_ref/build_headless.sh` → `build_headless/reverb_golden ps1-core/tests/goldens`,
and keep `ps1-core/tests/goldens/reverb_preset.zig` in step with the copy of the
preset inside `reverb_golden.cpp`.
**"Reverb disabled" does not mean "reverb silent."** Bit 7 gating the writes but
not the reads is faithful, and its consequence is sharp: with the reverb
registers unprogrammed and `reverb_vol_l/r` non-zero, both APF stages collapse to
`R(reverb_curr_addr)` and the stage reads raw voice-sample bytes back out as
full-scale noise; swept across all 512 KB, since `reverb_base` defaults to 0.
Avocado does the same, so real games presumably never sit in that state (libspu
zeroes the reverb volume in `SpuInit`), but no automated test boots a game, so a
regression here would surface as noise in a real title and nowhere else.
`reverb_enable` (default on) is the isolation switch; it has no setter, so
reaching it needs a recompile.
Two known gaps, both shared with Avocado: reverb SRAM accesses don't run
`checkIrq`, so a game using SPU IRQ as a timer with its IRQ address inside the
reverb work area would miss it; and an `sb` to 0x1F801DA2 now rebases
`reverb_curr_addr` onto a corrupted base, because `memory.zig` widens sub-word
SPU stores by re-dispatching the zero-extended byte at the unaligned address;
Avocado only rebases on the high-byte write to 0x1F801DA3. libspu uses 16-bit
stores throughout, so neither is known to fire.
Noise
+ ADSR are duckstation-style approximations, not Avocado's model. CD audio has its
*own* 768-cycle counter separate from the SPU's, so the two can drift. SPU IRQ is
level-style. Volume sweeps are not implemented (bit15 masked off). `decodeBlock`
is exported + unit-tested: keep its signature stable.
**The exponential-decrease step must stay signed.** Avocado keeps a decreasing
envelope's step negative and arithmetic-shifts it (`voice.cpp:67-73`), which
guarantees a magnitude of at least 1 and therefore that a release terminates.
Our step is positive, so `stepAdsr` negates around the shift. Scaling a positive
step and shifting right floors to **0**: the envelope stalls at a small non-zero
level, `is_on` never clears, and all 24 voices are permanently "busy"; a game
polling for a free voice then stops triggering sound effects entirely.

**DMA** (`dma.zig`): cooperative, **one word per `step()`**. An active channel
stalls the CPU, so anything that leaves a channel active without a sane
`words_remaining` is a hard hang; sync mode 3 (reserved) must therefore start
no transfer at all (Avocado dispatches only modes 0/1/2).
**A linked-list chain that closes into a ring is a real thing real games build,
and it is guarded, not fixed** (`ll_node_limit`, 65,536 nodes: above the 512K
distinct nodes 2 MB of RAM could hold in principle and 4x the largest ordering
table any game allocates). Tekken 3 emits one fighter twice on the frame its
round-phase machine leaves state 4, which links a chain's tail to its own head;
**Avocado builds the identical ring on the identical store** and survives only
because `dma_channel.cpp` carries the same guard ("GPU DMA transfer loop
detected, breaking"). Hardware survives it differently and this is the one place
our CPU-stall model is knowingly unfaithful: **hardware does not halt the CPU
during DMA**, it steals bus cycles, so the next frame's `DrawOTag` restarts the
channel on a fresh list and the ring costs a dropped frame instead of the
machine. Real CPU/DMA interleaving would be the faithful fix; it would move
interleaving in every game and needs a rate nobody has measured, so it has not
been attempted. Do not "improve" the guard into a behaviour change without that
measurement, and do not read the guard as a claim about hardware. Channel priority is
*not* implemented (fixed 0..6 loop: matches Avocado). **Sub-word stores to DMA
registers must be shifted into the addressed byte lane**; latching the raw value
unshifted killed Croc's FMV entirely. DICR is a full-word latch, not byte-granular.
The CDROM 32-bit data path is a 4×8-bit-FIFO read special-cased in
`memory.zig:229`. Chopping mixes "words" and "cycles" as one counter (known
inaccuracy). There is a latent SPU-DMA overflow around `dma.zig:260`.
MDECin/PIO DMA effectively stubbed.
**Sync mode 1 hands the bus back between blocks, but only on the SPU channel**
(`blockPacingCyclesPerWord`). Mode 1 syncs to *device requests*, so the gap
between blocks is set by how fast the device asks for the next one: a
per-device rate, not a global one. Channel 3 already models its own request
signal (the `data_fifo_empty` check); the SPU gets a timed one at 32 cycles per
word end-to-end, which is the only rate we have a hardware measurement for
(`spu/memory-transfer`). Channels 2 (GPU) and 3 (CDROM) are deliberately left
unpaced: they carry the bulk of real game traffic, pacing them changes CPU/DMA
interleaving everywhere, and no disc image is present to smoke-test Croc or
Crash against it. A gap must be long enough for software to run a poll loop:
an earlier attempt granted one instruction per gap and changed nothing.
**A DMA word costs a per-channel hardware rate, NOT the memory map's wait
states** (`transferCyclesPerWord`, PSX-SPX "DMA Transfer Rates": 1 clk/word for
MDECin/MDECout/GPU/OTC, 4 for SPU, 20 for PIO, 24 for CDROM). Wait states
describe what the *CPU* pays to touch an address; the controller has its own
path to RAM. Summing both ends billed ~6 cycles for a GPU or MDECout word that
hardware moves in one, and because a DMA-stalled CPU still ticks the peripherals
with whatever the DMA billed, the overcharge came straight out of the CPU's
budget between CDROM sector interrupts. Croc's FMV starved on exactly that: it
missed roughly one STR chunk per frame, so the RLE stream feeding the MDEC
desynced and the decoder emitted 240 or 301+ macroblocks instead of 300; a torn
right-hand side, plus a `MDEC_in_sync timeout` (leftover words keep MDEC_STAT
bit 29 busy) that froze video for ~1.7s. Fixed 2026-08-13; the give-away is that
`ps1-trace` showed sectors arriving ~40k instructions apart instead of ~143k
while the *cycle* cadence stayed constant. The wait states are still collected
into `bus.wait_cycles` around the transfer and discarded, so they leak into
neither clock.

**MDEC** (`mdec/{mdec,algorithm}.zig`): **ported from Avocado and unit-tested** (`mdec_test.zig`;
these were the first tests this module ever had). It now honours the per-block
`qFactor` from the DCT word, the uploaded scale/IDCT table (`scale_table`), the
zigzag-bypass when `qFactor == 0`, coefficient clamping, the `+128` YCbCr→RGB
bias, and dense 24bpp packing (the striped-garbage bug in Silent Hill's FMV).
Output depth comes from the command word. The struct is **~768 KB by value**
(two 131072-entry FIFOs) and is held by value in `Bus`.
**MDEC_STAT bit 31 means data-out FIFO *empty*, not "data ready"**: it was
inverted, and since every decoder poll loop spins waiting for it to go low, the
inversion hangs the caller outright. The whole register now follows Avocado's
`MDEC::Status` (bits 30/29 FIFO-full/busy recomputed per read, 28/27 the DMA0/
DMA1 request bits gated by MDEC_CTRL 30/29, 26-23 the command's output format,
15-0 the remaining parameter words *minus one*). **Only the 24bpp and 15bpp
colour paths exist**: 4bpp and 8bpp are monochrome modes with a one-block
layout, so the decoder mis-parses them and emits nothing (Avocado does not
implement them either).

**Memory / interrupts / timers / SIO** (`memory.zig`, `interrupt.zig`,
`timer.zig`, `sio.zig`)
- I_STAT is **write-0-to-ack** (`stat &= value`) and is a **latch**: `trigger()`
  sets a bit that stays set until software acks. Most devices call it on a
  one-shot event, so the latch is all they need. A device that instead asserts a
  *level* must edge-detect on its own side before calling `trigger()`: see the
  CDROM's `irq_line` above. Calling `trigger()` every step from a level makes
  software that acknowledges I_STAT before acknowledging the device take a
  second, phantom interrupt.
- The JOY port raises **IRQ7 (Controller)**, not IRQ8 (that's SIO1 at `0x1F801050`).
- **The /ACK is deferred, and that is load-bearing** (`sio.zig`). A byte
  written to JOY_TX does *not* raise IRQ7 there and then; it arms `irq_timer`,
  and `Sio.advance(steps)` (called from the scheduler's fan-out with the batched
  step count) raises it later. The BIOS
  pad routine clocks a byte, waits, then clears *both* JOY_CTRL bit 4 and
  I_STAT bit 7 before polling for /ACK, so a synchronous interrupt is swallowed
  by the routine's own acknowledge; it then times out after ~81 polls and
  reports "no controller". Don't "simplify" this back.
- **The delay is PER-PERIPHERAL, and one shared constant is a bug, not a
  simplification**: `pad_ack_delay` is 500 (matching Avocado's `irqTimer = 5`
  ticked once per 100-instruction batch) but `card_ack_delay` is **150**
  (Avocado uses `3` for the card, `controller.cpp:29,37`). The two windows
  barely overlap and point opposite ways. The pad's has a FLOOR: below ~140
  the routine's own acknowledge eats the interrupt. The card's is a CEILING
  with no floor at all: a driver clocks 137 bytes for one 128-byte frame and,
  once a byte's /ACK runs long, deselects the port and abandons the frame
  *mid-data-phase*. Swept with `ps1-trace` against Spyro, Crash 2 and Resident
  Evil, that cliff is sharp and identical across all three (215 completes
  every transfer, 225 aborts every one), while 25 works as well as 215 does.
  Giving the card the pad's 500 made it **unreachable by real software**: a
  128-byte read died after 55 bytes, so no game could read a directory or
  commit a save, every title declared the card unformatted, and the only block
  that ever reached a persisted image was the driver's write-test at frame 63.
  That is precisely what FF7 showed: "format successful", then "not enough
  memory left" (fixed 2026-08-31). The card protocol landing correctly
  (2026-08-31) is what first made this reachable; before it, nothing spoke to
  the card at all. `ackDelay()` is an exhaustive switch with no `else` on
  purpose: a state added later must say which side it is on rather than
  inherit a delay that silently breaks one of the two.
- JOY_STAT bit 7 is the /ACK level (asserted while the pad is mid-packet, cleared
  by the read); bit 9 is the IRQ line, cleared by JOY_CTRL bit 4. Clearing
  JOY_CTRL bit 1 (deselect) resets the peripheral's transfer state: without it
  the state machine leaks across polls and desyncs permanently.
- **The pad is a DualShock (`sio/pad.zig`) that powers up DIGITAL** (ID `0x41`,
  5-byte packet; the digital `0x42` packet is byte-identical to the old
  pad's, `/ACK` pattern included). Port 2 still has no pad. Regression tests
  live in `tests/sio_test.zig`.
  - **The reply is clocked out one byte per `transfer`.** `begin` decides the
    reply at the command byte, with one exception: a `0x42` read refreshes
    buttons and sticks LIVE as each byte goes out (`fillRead` at step >= 2).
    Building the whole reply at the command byte broke the trace goldens.
    `0x43` answered outside config mode is a read decided at `begin`. A
    command the pad does not answer (`0x44..0x4D` outside config mode) gets
    no /ACK at all.
  - **Config mode changes at a packet's LAST byte** (`0x43`, `setConfig`), so
    a deselect mid-`0x43` changes nothing.
  - **The Analog button is queued** (`pressAnalogButton`) and lands in
    `idle()`, the packet end, deselect or SIO reset: a reply is never
    re-shaped mid-way. A locked pad ignores it. After a toggle, `status`
    reads `0x00` instead of `0x5A` on a pad that has seen config mode
    (`dualshock`), which is how a game notices; entering config mode resets it.
  - **Rumble has two encodings.** Before a game first enters config mode
    (`dualshock` clear) the legacy single-motor rule drives the small motor
    from TX bytes 2 and 3 of a read. After it, the `0x4D` map decides which
    TX byte drives which motor. EVERY mode change (a toggle or `0x44`)
    unmaps and stops both motors, and `0x4D` stops a motor the new map no
    longer reaches.
- **The memory card speaks the real protocol as of 2026-08-31, and did not
  before.** A packet ADDRESSES a peripheral with its first byte (`0x01` the
  controller, `0x81` the card), and the card's command byte is `'R'`/`'W'`,
  answered with FLAG (bit 3 "fresh"/directory-unread, bit 4 always set, bit 2
  the error latch cleared by that read). The old code left `.Idle` only for
  `0x01` and then took `0x81`/`0x82` as read/write, so **the card was
  unreachable by real software** and its image had never been written by
  anything but a unit test. One deliberate divergence from Avocado: a write's
  128 bytes are STAGED and copied into the image only once the checksum
  verifies, because the image is now persisted and a sector reported `'N'`
  must not reach the file.
- **JOY_CTRL bit 13 selects the PORT, and it is latched on the byte that opens
  a packet.** Not decoded at all until 2026-08-31, so both slots were answered
  by one card and one pad, which with persistence would make the BIOS card
  manager's copy function copy a card onto itself. Sampling per byte instead
  would let a mid-transfer JOY_CTRL write splice one card's block into the
  other's. **Port 2 has no pad**: `0x42` there falls through to `.Idle`, the
  existing "nothing responded" path, and the BIOS reports no controller, as an
  empty socket does. Cards are per-slot; `getMemoryCardData`/`setMemoryCardData`/
  `isMemoryCardDirty`/`clearMemoryCardDirty` all take a slot index.
- **Both card slots always present an inserted card: a decision, not a bug,
  but undocumented until now and it reads as a defect later.** Avocado models
  an `inserted` flag and returns `0xFF` for an absent card; this port does
  not, so port 2 always answers as a real (if blank) card. `MemoryCardStore`
  presents a blank 128 KB image for a slot that has never been written, the
  same way `Bus.init`'s zeroed `memcard_data` does before any frontend is in
  the picture. Player-visible consequence: the BIOS card manager shows slot 2
  as an *unformatted card* rather than an *empty socket* it could offer to
  skip. DuckStation makes the same call (it ships a card in slot 1 by
  default), just not this exact one.
- **Access width matters at two device ports.** The CDROM is an 8-bit device
  and a wider store hits the *addressed* port once per byte lane: it does not
  walk 0x1800..0x1803, which would drop a byte into the command register; a
  word read mirrors one status byte across all four lanes. And a CPU word read
  spanning 0x1F801DA8 covers two 16-bit *registers* (the SPU RAM transfer FIFO
  and SPUCNT), whereas DMA4 pops the FIFO twice: hence `Bus.dmaRead32`, which
  exists to keep those two paths apart.
- Several reads spoof magic values (`0xC0C00000` at SIO regs, `0x3C045678` shadow
  at Timer1 mode `0x1108`) to satisfy BIOS/test patterns, not real hardware.
- Timer mode read clears the reached-target/overflow latch bits (bits 11/12)
  per PSX-SPX (`timer.zig:17`); bit 10 (IRQ-request) and bit 6 (once/repeat) are
  still unimplemented.

**Frontends + test harness**
- `setDisc()` now has four callers: `ps1-debug` (optional argv disc path),
  `ps1-trace`, `ps1-wasm`, and `cdrom_test.zig`. The disc/CD-boot pipeline **is**
  exercised, but only by hand: no automated test boots a game from disc.
- The ROM suites (`peterlemon_test.zig`, `jaczekanski_test.zig`) still use
  `cpu.loadExe()` (PS-EXE sideload, bypasses BIOS CD boot) and leave `disc = null`.
- wasm exports are a hard ABI contract with `ps1-wasm/www/index.html`: renaming an
  export silently breaks the browser frontend. The page uploads BIOS, EXE, `.bin`
  and `.cue` (`allocCdBuffer` / `allocCueBuffer` / `loadCdFromBuffer`), including
  via a directory picker.
- **`ps1-wasm` now has a reachable, writable memory card and NO persistence at
  all: the frontend-parity gap runs the OPPOSITE direction from usual here.**
  Normally the app is the one missing something wasm already has (see
  `.sbi`, above, before 2026-08-31). The card protocol itself lives in
  `sio.zig`, so the browser build got it for free the moment the core did
  (a game can format a card, write a save, and read it back within one
  session), but nothing in `ps1-wasm` reads or writes a card image to disk
  the way `MemoryCardStore` does for the macOS app, so every save is lost the
  moment the tab closes. Giving the browser build persistence means the page
  driving something IndexedDB-shaped, which has not been attempted.
- **The page fetches `/zig-out/bin/emulator.wasm`, so a core fix does not reach
  the browser until `zig build` runs: a hard reload alone re-fetches the *old*
  binary.** This is not hypothetical: the Tekken 3 "freezes on the STAGE 1
  XIAOYU VS JIN portraits screen" report was chased for a whole session against
  a tree where the fix (`05fcc61`) was already committed, because the served
  wasm predated it. Before treating a browser-only symptom as a live bug,
  rebuild and check the `.wasm` mtime against the commit you expect. A browser
  symptom that no headless run reproduces is a stale-binary suspect first.
- **The browser build can be driven headlessly**: instantiate
  `emulator.wasm` under node, feed `getBiosPtr`/`allocCdBuffer`/
  `allocCueBuffer`/`loadCdFromBuffer` exactly as `index.html` does, then call
  `setControllerButtons` + `stepFrame` in a loop and fingerprint VRAM per
  window. That reproduces browser behaviour at ~80 fps without a browser run,
  and it is how the stale-binary case above was finally settled (the pre-fix
  wasm froze on the VS screen with `pos=` pinned, HEAD passed it on the
  byte-identical input schedule).
- `jaczekanski_test.zig` normalizes output (strip `\r`, strip leading `% ` prefixes,
  plus a hardcoded SIO_CTRL string fixup). Changing TTY formatting causes spurious
  mismatches until the normalizers are updated. `rom_test_helpers.zig` holds the
  shared `readTestFile`.
- **`peterlemon_test.zig` is a ratchet, not a pass/fail comparison.** It counts
  how many of the 71,680 framebuffer pixels match the test's `reference.rgb` and
  fails only if the count drops below the per-test `floor.txt`, so the suite
  passes today at 77-99% match, and its job is to catch GPU *regressions*. After a
  genuine rendering improvement, re-pin the floors with
  `PS1_UPDATE_GOLDENS=1 zig build test-roms-pl`.

**Savestates** (`ps1-core/src/savestate/`): the whole machine as one blob,
written and read by hand per field (never by reflection, `state_hash.zig`'s
reason). Raw size is ~6.9 MB (`BUS ` is 4.2 MB: RAM plus the 2 MB
`expansion_3`); the core never compresses, the macOS app LZFSEs it.

| Part | Layout |
| --- | --- |
| Header, 64 bytes | magic `SBST`, format version u32, CRC32 u32 of the body, body length u32, BIOS SHA-256 (32), serial of the disc in the tray (16) |
| Section | tag (4), section version u32, body length u32, body |
| Sections | `BUS `, `CPU `, `IRQ `, `TMR `, `DMA `, `GPU `, `SPU `, `CDR `, `MDEC`, `SIO `: each mandatory, exactly once. `SIO ` is v2: it carries the whole `Pad`. v1's per-byte pad tags 2..8 load as `.Pad` at step `tag - 1` (the reply rebuilt as `0x42` would have built it), and the card tags keep their numbers because `SioState` is explicitly numbered |

Refusals are typed: bad magic `StateBadMagic`; an unknown tag or a section
version newer than this build `StateVersion` (a newer build's state is never
half-read); BIOS hash or serial mismatch `StateBios`/`StateDisc`; a missing or
duplicate section, short or long body, bad bool/enum, or an index out of range
(SPU, CD-ROM FIFO/queue/XA, MDEC FIFO indices and word counts, SIO card address/step, GPU FIFO count) `StateCorrupt`. A range check belongs in
every loader that restores an index, because the file is CRC-valid and
untrusted.

**Adding a device field.** Worked example, a `u32` on `Timer`:
1. Write it in `saveTimers` and read it in `loadTimers` in `io_state.zig`.
2. Bump `TMR ` from 1 to 2 in `savestate.zig`'s `sections`.
3. Read the old layout with the power-on value:
   `if (version >= 2) t.new = try r.int(u32) else t.new = 0;`
4. A new `v<N>-synthetic.state` fixture beside the old one (see
   `ps1-test-harnesses`); the old fixture keeps loading.

**Deferred-tick bookkeeping is SAVED, not caught up.** `gpu.cycle_debt` /
`pending_cycles` / `event_countdown`, each timer's `pending_ticks` /
`event_countdown` and the CD-ROM's `pending_cycles` / `event_countdown` are
written like any other field. A save then needs no settle, and
`trace-golden -- savestate` can restore at an arbitrary instruction and still
match the golden bit for bit.

**Not in a state:** the BIOS bytes (only the hash), the disc bytes (only the
serial), the memory-card images and their dirty flags, `expansion_1`, every
`pgxp_*` field and PGXP shadow/cache, the GPU sink and VRAM depth plane, the
disc slice and debug switches, `spu.reverb_enable`, and the CPU's `bus` and TTY
hooks. After a load, geometry is integer for a frame or two while PGXP refills.

**`ps1_load_state` loads into a scratch `Bus` and swaps only on success**
(`capi_test` pins that a refused load leaves the running machine untouched).
Because the cards are not in a state, the restore path must carry them across
itself: the ps1-golden `savestate` mode copies the card images and dirty flags
into the restored machine, and the app installs its cards after the load.

**The trusted snapshot (runahead and rewind).** `saveTrusted` writes the same
layout as `save` with the CRC and both identity fields zero; `loadTrusted`
checks the magic, the container version and the body length, keeps every
section's own checks, and writes into the RUNNING `Bus`, so the block cache,
the raster worker and the PGXP shadows survive. It drains the worker before the
load and `Gpu.reseatRasterWorker` puts the worker's own `draw_env` copy back
after it (`loadGpu` no longer asserts that no worker is attached). A refusal
part-way leaves the machine half-written, which is why it is only for bytes
this process produced. `savestate.Mark` adds the two card images and their
dirty flags, because no state carries them and a speculative save must not
reach the card ahead of the real one; `ps1-capi` calls `forget` on
`ps1_reset`, `ps1_load_state`, `ps1_load_disc`, `ps1_swap_disc`,
`ps1_load_bios` and `ps1_load_memcard`.

A load no longer flushes the block cache: the `BUS ` loader calls
`BlockCache.invalidateChanged`, which drops only the code pages whose RAM the
state changes, and `readSections` clears the pending link site and the running
pin. Measured with `ps1-bench-dual --engine=jit threaded --runahead=N` (best of
three, 3000 displayed frames), realtime at N = 0/1/2/3: Crash Warped
12.65/5.42/3.84/2.87x, Spyro 9.38/4.08/2.89/2.22x, Silent Hill
7.07/3.21/2.23/1.68x. Against N extra frames of plain emulation, one mark plus
one return costs 0.4-0.55 ms per displayed frame.

**The mark carries the PGXP shadows (2026-10-09).** No state holds them, so
before this a return left the speculative frames' shadows behind and the
identity check rejected them: `pgxp --snapshot` measured Spyro at 86.3%
resolved against 99.9%, `identity_fail` 150,922 against 0, and 14 of 18
passes under their floors. `savestate/pgxp_mark.zig` now copies every
shadow a state leaves out (the RAM and scratchpad tables, the CPU, COP0,
GTE and JIT load shadows, the GP0 FIFO and command-buffer provenance, the
weld table) while PGXP is on, plus the depth plane and `depth.State` while
the depth buffer is on, and writes them back after `loadTrusted`. The sweep
is now 18/18 with `identity_fail` 0 everywhere. The 83 MB vertex cache is
left out: it validates by the word, ships off, and would cost more to copy
than the rest of runahead. Measured cost: none above noise (Silent Hill,
PGXP on, N=2: 1.26x with the copy, 1.25x without).

**Rewind** (`savestate/rewind.zig`, `ps1_rewind_*`). `head` is the newest
`saveTrusted` capture in full, zero-padded to a multiple of 8 bytes; each
entry is a reverse delta (runs of changed 8-byte words: offset, count, the
OLDER words) that turns its capture back into the one before. A step applies
the newest entry to `head` and `loadTrusted`s it; nothing depends on the
oldest entry, so the budget (entries plus both buffers) frees from that end
with no keyframes. `ps1_run_frame` captures every 2 frames while rewind is
on, never between `ps1_snapshot_mark` and `ps1_snapshot_return`
(`Handle.speculating`, cleared even by a failed return). **`ps1_rewind_step`
loads and runs nothing**: the host publishes that machine as the shadow a
resync adopts, then runs the frame, whose stream replays on top at scale. A
step resets the capture count, so stepping every frame captures nothing.
Reset, state load, disc load, disc swap and BIOS load clear the history;
`ps1_load_memcard` does not (a card is not machine state). Rewind entries do
not carry PGXP shadows. Measured: 256 MB held 66.7 s of Crash Warped's boot
and attract mode (197 MB used); no gameplay measurement yet.
