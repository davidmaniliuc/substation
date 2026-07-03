# Croc black screen — FMV software-VLC decoder runaway (findings, 2026-07-03)

**Status: RESOLVED 2026-07-03 — root cause was DICR byte-access + IRQ-gating bugs
in the emulator's DMA controller. See [§ Resolution](#resolution-2026-07-03) at
the end; the analysis below is the historical trail.**
Symptom: Croc (US, `~/Downloads/Croc - Legend of the Gobbos/Croc - Legend of the
Gobbos.bin`) boots, prints `Playing Fox.`, then full black screen and permanent
wedge. Silent Hill "advances a little then goes black" — plausibly the same
class of bug (FMV/streaming), unverified.

## The complete failure chain (all verified by trace)

1. Game boots fine (BIOS SCPH-1001), loads `SLUS_005.30`, starts the Fox
   Interactive intro FMV. The FMV is decoded by a **software VLC/Huffman
   decoder in game code** (not raw MDEC DMA):
   - 64KB+ **Huffman lookup table** at `0x80110dc4..0x80120dc4+` — loaded from
     disc by DMA (CPU stalled at BIOS pc `0xbfc05f94`, drive at LBA ~221576,
     i≈167,862,934). Entries are `(output_code<<16)|bit_length`; a zero entry
     escapes to a second-level table.
   - **Frame bitstream** staged progressively into `0x801798d0+` by caller code
     at `0x801015xx` (one word every few instructions; even uses the `jal`
     delay slot at `0x80101530` to store). Staging data verified byte-identical
     to the disc.
   - **Resumable decoder** at `0x8010e144` (main loop `0x8010e1b4..0x8010e41c`),
     persistent context at `0x8010e484`:
     `{+0:src=a0, +4:dst=a1, +8:v0, +0xc:v1, +0x10:t4, +0x14:t5, +0x18:t7,
     +0x1c:t8, +0x20:t9}`. Bit-reservoir word at `0x8010e110` (init
     `0x00ffffff`). LUT base/end `0x80110dc4/0x80120dc4` are **hardcoded**
     (lui/addiu at `0x8010e14c-0x8010e158`).
     Entry regs (first call): `a0=0x801798d0` (src), `a1=0x8014c0d0` (dst =
     MDEC-code output buffer), `v0=0x8012447c`, `v1=4`, `t4=0x23`, `t5=0x2b`,
     `t7=0`, `t8=0x1000`, `t9=0x2000`, `s1=0xba8` (candidate input budget),
     caller `ra=0x80101534`.
2. **The decoder never finishes a frame.** First called at i=174,859,905;
   output pointer `$a1` marches monotonically from `0x8014c0d0` with no reset.
   For a black frame the correct VLC output is ~7-8KB (DC + EOD per block);
   ours passed 16KB within 260k instructions and kept going.
3. At ~i=176.5M the output crosses its own input (`0x801798d0`) —
   **self-cannibalization**: the decoder overwrites the staged bitstream it is
   still reading, so everything after is garbage-feeding-garbage.
4. At i=187,636,308 `$a1` reaches `0x80200000` = end of 2MB KSEG0 RAM. The RAM
   mirror (`& 0x1FFFFF`, same on real HW) wraps the writes to **phys 0x0**.
5. i=187,640,694..187,641,034: zero-pixel `sh` stores (pc≈`0x8010e3b0`) wipe
   the kernel **Table of Tables at 0x100-0x117**.
6. i=187,687,219: a CDROM IRQ (I_STAT=0x0004, I_MASK=0x000d, IEc=1) is taken
   (EXC#1, code 0, epc=0x8010e33c). The BIOS dispatcher loads
   `s3=MEM[0x100]=0`, walks garbage, takes **AdEL at epc=0xdf8** (EXC#2,
   code 4, sr=0x410), and dead-loops at `0xe30` with IEc=0 forever. CDROM INT1s
   pile up → the 4550 `irq_queue` overflow warnings. Black screen, hard wedge.

## Exonerated (do not re-investigate)

- **The load-delay fix in cpu.zig.** Temporarily reverted to old semantics →
  wedge was byte-identical at identical instruction indexes. Fix is restored
  in the tree and is correct.
- **CDROM sector delivery.** The sector at LBA 221576 (and the LUT region) is
  byte-for-byte identical to the disc image. The 128-byte "zero hole" at
  buffer bytes 1476-1603 is authentic disc content (the region past the 64KB
  LUT / STR zero padding), not corruption.
- **CD data FIFO / DMA ch3.** During the LUT fill the FIFO never ran dry;
  `readData` never substituted zeros.
- **Variable shifts** (`sllv/srlv/srav`): properly 5-bit masked
  (`cpu.zig` `shiftV`). **LWL/LWR** load-delay bypass looks correct.
- GPU/vblank timing: untouched, previously verified NTSC-exact.

## The open question (next session starts here)

Why does the decoder emit too much output from frame 1? Input (LUT + staged
bitstream) is disc-correct, so the candidates are:

1. **Race between staging and decode** (favored): the decoder is resumable and
   is called with an input budget (`s1=0xba8`?) while the caller stages data
   as CD sectors arrive. If our CD INT1 pacing / command timing makes the
   caller call the decoder before enough data is staged — or with a budget
   larger than the staged bytes — the decoder consumes zeros past the staging
   watermark once and its Huffman state desyncs irrecoverably. Note the first
   call happened when only ~0x1ac bytes were staged.
   (CLAUDE.md already documents our CDROM per-command delays are wrong vs
   Avocado — flat `ack_delay=1000`, wrong second-response delays, `busy_for=0`.)
2. **A CPU core bug in an instruction the decode loop uses.** Unaudited:
   trapping `add`/`sub` (0x20/0x22 — the codec uses them, e.g. `002a0822
   sub $at,$at,$t2`), overflow-exception behavior. Audited-OK: variable
   shifts, LWL/LWR.

### Next planned probe (instrumentation already written, not yet run)

`ps1-trace/src/main.zig` already contains an `[EARLY]` snapshot at
i=175,000,000 dumping regs, the first 32 output words at `0x8014c0d0`, and the
caller code `0x801014a0..0x80101560`. Run:

```
zig build -Doptimize=ReleaseFast
./zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin \
  "/Users/david/Downloads/Croc - Legend of the Gobbos/Croc - Legend of the Gobbos.bin" \
  175100000 /tmp/croc_sys.txt 2>&1 >/dev/null | grep -E "EARLY|OUT|CALLER"
```

Then: disassemble the caller loop (`0x801014a0..0x80101560`) to identify the
input-budget bookkeeping and where "input exhausted → pause/resume" is
decided; check the first output words for MDEC-code plausibility
(`(run<<10)|level` pairs, `0xFE00` EOD cadence). If the caller polls a
CD-driven counter, compare its value against staged bytes to catch the
over-budget call in the act.

## Key timeline (instruction index i, deterministic across runs)

| i | event |
|---|---|
| 167,862,934 | LUT tail DMA'd (BIOS pc 0xbfc05f94, drive LBA 221576) |
| 174,859,905 | first decoder call (`pc=0x8010e144`), ~424 bytes staged |
| ~176,500,000 | output crosses input start 0x801798d0 |
| 186,500,000 | (probe point used mid-runaway) |
| 187,636,308 | `$a1` = 0x80200000, mirror wrap to phys 0 |
| 187,640,694 | kernel ToT zeroing begins |
| 187,687,219 | CDROM IRQ → dispatcher walks zeroed table |
| 187,687,342 | AdEL at 0xdf8, terminal dead loop |

## Disc/format notes

- FMV frames found repeating every 10 sectors from LBA 44318 (135 identical
  black frames, pattern at sector data byte 40); staged copy starts at sector
  data byte 32 (32-byte demux header skipped). Frame header halfwords at
  `0x801798d0`: `0x1960, 0x3800, 0x0001, 0x0003`.
- The drive was around LBA 221576 during LUT load, so the actual fox.str
  playback region is likely ~2215xx; the 44318 hits may be another copy —
  black frames are identical either way.

## Working-tree state left behind

- `ps1-core/src/cpu.zig` — load-delay fix in final (correct) form.
- `ps1-core/src/memory.zig` — JOY port IRQ7 fix (correct, keep).
- `ps1-core/tests/sio_test.zig`, cpu_test addition, build.zig test list — keep.
- `ps1-trace/src/main.zig` — **heavily TEMP-instrumented** (kernel-chain watch
  ≥100M, hole watch on 0x80179a70/74/78, ENTRY dump at i=174,859,905 which
  also writes `frame1_ram.bin`/`lut_ram.bin` to the session scratchpad path —
  **that absolute path is stale in a new session; retarget before running**,
  EARLY dump at i=175,000,000, REGS/ENT dump at i=186,500,000, LBA/BUF dump at
  i=167,862,880, A1 tracking, EXC trap). Prune to what the next probe needs.
- `ps1-core/src/cdrom.zig` — enhanced queue-overflow warning (harmless, keep
  or revert).
- Scratchpad trace artifacts (croc_*.txt, frame1_ram.bin, lut_ram.bin) live in
  the old session scratchpad and will be gone; everything is regenerable with
  the commands above (traces are deterministic).

## Resolution (2026-07-03)

### Why the decoder over-ran (answer to "the open question")

The frame decoder (`0x8010e144`) has exactly two exits: the `0x3ff` DC code =
end-of-frame marker (return 0), and an output-budget bound `a1 >= t6` (suspend,
return 1). The budget word at `0x8010e110` ships as the `0x00ffffff` "unlimited"
sentinel and Croc never calls the setter (`0x8010e114`), so the only working
exit is the in-stream `0x3ff` marker. Decoding zeros yields an endless
DC+EOD pattern that never contains `0x3ff` — hence: decode an incomplete frame
⇒ run off the staging watermark into zeros ⇒ never terminate.

The frame was incomplete because the **Sony St CD-streaming library** was told
the frame was ready after chunk 0 of 9. Ground truth (disc): the Fox FMV at
LBA 44318+ is 320x240, 9 video chunks + 1 XA audio sector per frame,
`usedBytes≈10328` (~10 KB VLC data spanning 6 chunks — not a "black frame").
The St library's design: the per-sector CD callback (`0x8010ce50`) starts a
DMA-ch3 transfer of each chunk into the ring via a helper (`0x8010d7f4`) that
**clears DICR ch3 IRQ-enable (byte write to `0x1F8010F6`) for mid-frame chunks
and sets it only for the frame's last chunk** (`chunkNumber == chunksInFrame-1`).
The DMA-completion interrupt handler (via dispatcher `0x80106394`) calls
mark-ready (`0x8010cb00`, slot state 2) which `StGetNext` (`0x8010cd6c`)
consumes. So on real HW only the last chunk's DMA completion marks the frame.

### The emulator bugs (all in DMA MMIO / DICR)

1. **`memory.zig` read+write dispatch ranged `0x1F801080..=0x1F8010F4`** —
   excluding DICR bytes 1-3 (`0x10F5-0x10F7`). The St library's `sb` to
   `0x1F8010F6` (clear ch3 IRQ-enable) silently landed in the `io_ports` array
   and never reached `dma.dicr`; the enable bit stayed set from an earlier
   transfer, so *every* chunk's DMA completion raised the IRQ → mark-ready at
   chunk 0 → runaway → RAM wrap → kernel ToT wipe → wedge.
2. **`dma.zig` completion set the DICR flag bit unconditionally.** Per PSX-SPX
   and Avocado (`DMA::step`), flag `24+n` latches only when enable `16+n` is
   set.
3. **`dma.zig` DICR word-write zeroed all flags when bit 23 was written 0.**
   Avocado applies write-1-to-clear to the flag byte unconditionally; there is
   no flags-wipe on master-disable.

### Fixes applied

- `memory.zig`: DMA dispatch ranges extended to `0x1F801080..<0x1F801100` for
  read and write; sub-word reads now return the correct byte/halfword lane
  (Avocado is byte-granular); removed the `writeCpuStore` special case that
  forced sub-word DMA stores to raw u32 writes (the RMW path in `write()` now
  handles all widths).
- `dma.zig`: completion flag gated on the channel's DICR IRQ-enable bit;
  DICR write does unconditional W1C on the flag byte, no flags-wipe.

### Verification

- 4 new unit tests in `ps1-core/tests/dma_test.zig` (byte access reaches DICR,
  byte-3 W1C, enable-gated completion flag, no flags-wipe) — red before, green
  after; full `zig build test` 74/74 pass; PeterLemon suite 6/6 pass.
- Croc trace: mark-ready now fires once per frame (last chunk), decoder returns
  `v0=0` every frame (~26 KB output = nCodes*4), frames at ~2.3M instr ≈ 15fps.
  800M-instruction run: "Playing Fox." → "Playing Argonaut." → game engine
  loads (new PAD driver/ResetGraph). No wedge.
- The "16x too slow sector cadence" observation from mid-investigation was an
  artifact of the spurious-IRQ chaos, not a real bug — post-fix streaming
  cadence is ~237K instr/sector ≈ 2x speed. Do not chase it.
