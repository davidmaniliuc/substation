# Silent Hill green/magenta surfaces — torn display-list packet (findings, 2026-08-12)

**Status: FIXED 2026-08-12.** Root cause: **an interrupt taken on a GTE command
instruction dropped the operation entirely.** One line in `Cpu.step` defers the
interrupt by one instruction; the tear count over the 845M-instruction
reproduction goes 8 → 0 and every frame is clean. See
[§ Root cause](#root-cause-the-bios-skips-a-gte-instruction-hardware-already-ran)
below; the sections after it are the original investigation record, kept because
the chain they establish is what made the last step findable.

Symptom (reported from the browser frontend, reproduced headlessly): in-game
Silent Hill draws characters and subtitle glyphs as flat solid silhouettes —
green in one scene, magenta in another — with striped/"popping" garbage on
floors and walls. Backgrounds otherwise render correctly.

## Root cause: the BIOS skips a GTE instruction hardware already ran

The torn packet is one wrong **byte**, not a wrong packet.

Silent Hill's display-list builder at `0x80059060` emits two primitives per
call: a 12-word `POLY_GT4` at `s1` and an 8-word `POLY_G4` at `s4`. Both packet
lengths are immediate constants in the routine —

```
80059264: addiu v0, zero, 12   ->  80059268: sb v0, 3(s1)     ; GT4, len 12
8005926c: addiu v0, zero, 8    ->  80059274: sb v0, -45(s5)   ; G4,  len 8
```

— so the 8-word packet is *always* a `POLY_G4` and its command byte must always
be `0x38`. That byte does not come from a constant: each vertex colour is a GTE
result, written straight out of the colour FIFO.

```
800590c4: mtc2 v1, $8          ; IR0 = 0
800590c8: lwc2 $c6, 0(t3)      ; RGBC <- game data (code byte in bits 31-24)
800590cc: nop
800590d0: nop
800590d4: cop2 0x0780010       ; DPCS: depth-cue, push RGB2 = CODE<<24 | colour
800590d8: addiu v0, s4, 4
800590dc: swc2 $c22, 0(v0)     ; store RGB2 as the primitive's first word
```

`pushRgb` copies the CODE byte from RGBC, so the stored word carries `0x38` for
the G4 and `0x3c` for the GT4. Instrumenting every RGBC load and every colour
push against the store that lands in the packet shows the failure exactly:

```
seq=47940901 pc=0x80059220 lwc2 RGBC <- [0x000388] = 0x3c978c85
seq=47940902 pc=0x8005922c push RGBC=0x3c978c85 -> RGB2=0x3c100f0e
seq=47940924 pc=0x800590c8 lwc2 RGBC <- [0x00038c] = 0x3874646c
seq=47940925 pc=0x800590d4 EXCEPTION code=0 epc=0x800590d4
seq=47941035 pc=0x00001014 RFE
seq=47941036 pc=0x800590dc store @0x1c88a0 <- 0x3c100f0e
```

RGBC is loaded with `0x38…`, an interrupt is taken **on the DPCS**, and after
the handler returns the `swc2` stores `0x3c100f0e` — the colour pushed by the
*previous* primitive. There is no push between the load and the store: the DPCS
never ran.

It never ran because the BIOS deliberately skips it. The kernel handler at
`0x00000cc0`:

```
00000cc0: andi  v0, v0, 0x003c      ; Cause ExcCode
00000cc4: bne   v0, zero, 0xcec     ; only for Interrupt (code 0)
00000ccc: lw    v0, 0(v1)           ; v1 = EPC; read the interrupted instruction
00000cd4: srl   v0, v0, 24
00000cd8: andi  v0, v0, 0x00fe
00000cdc: addiu at, zero, 74        ; 0x4A -> a COP2 (GTE) command instruction
00000ce0: bne   v0, at, 0xcec
00000ce8: addi  v1, v1, 4           ; ...so return past it
00000cec: sw    v1, 128(k0)         ; saved return address, used by `jr k0`
```

On hardware the GTE operation has already been issued when the exception is
recognised, so re-executing it on return would run it twice — the BIOS skips it
on purpose. **We discarded the instruction without executing it, and then the
BIOS skipped it, so the operation was lost.** The GTE kept the previous
primitive's RGB2, whose CODE byte `0x3c` turned an 8-word `POLY_G4` into a
12-word `POLY_GT4`, and the linked-list walker ran off the end of the packet.

### The fix

`ps1-core/src/cpu/cpu.zig` — do not take an interrupt when the fetched
instruction is a COP2 command, using the BIOS's own test:

```zig
const is_gte_command = (instruction >> 24) & 0xFE == 0x4A;
```

Deferring by one instruction leaves EPC past the command, so the handler's skip
no longer applies and the operation runs exactly once. Pinned by
`"CPU defers an interrupt pending on a GTE command instruction"` in
`ps1-core/tests/cpu_test.zig`.

### Why the planned next step would not have found it

The brief's recommendation was an event-anchored PC diff against Avocado.
**Avocado has the same defect** — `CPU::checkForInterrupts` (`cpu.cpp:188`) has
no GTE case, and `checkForInterrupts()` runs before `fetchInstruction`. The diff
would have matched on both sides and shown nothing. This is a case where
`avocado_ref` is not a valid oracle; the BIOS's own handler was.

## One bug, not three

All three reported symptoms come from a **single clobbered 16-entry palette**.

The game stashes a 4bpp CLUT at VRAM **(0,0)**. That is legitimate, not a stray
write target: the display area is `(0,32)` / `(0,256)` at 320x224, so VRAM rows
0-31 are above the visible region and are ordinary off-screen scratch.

At ~840M instructions that palette is overwritten with `0x0EE0`, and **nothing
ever restores it**. Every 4bpp primitive that references CLUT `(0,0)` then reads
one flat colour for every texel index — including index 0, because the PS1
transparency test is on the *looked-up* 16-bit colour, not on the index. A glyph
cell or a character therefore fills solid rather than showing its shape. The
tint later changes from green to magenta because the palette is re-clobbered
with different garbage.

Two things worth keeping separate, established by a run with `Color.modulate`
bypassed to return the raw texel:

- Character **textures are intact**. Their wrong colour came from modulating a
  correct texel by a bad vertex colour, and with modulation bypassed Harry
  renders with his correct brown jacket and blue jeans.
- The ground's **texel itself** is the green — it reads the clobbered palette
  directly.

## The verified chain

Each step was measured, not inferred.

1. VRAM dumps (`PS1_VRAM_DUMP=1`) at 10M-instruction intervals show every
   texture page **byte-identical** between a clean frame (830M) and a glitched
   one (840M). Only the framebuffers and row 0 differ. Tracking row 0 across the
   run: a real gradient palette (`2128 1906 18e7 1ce6 ... 0442`) at 470M, then
   all sixteen entries `0ee0` at 840M.
2. Instrumenting `Color.fetchTexel` for that value: `4bpp op=3e clut=(0,0)`,
   i.e. primitives correctly reading the palette that is now green. The fetch
   path is doing exactly what it was asked to.
3. Instrumenting all three VRAM write paths (draw / transfer / fill) for writes
   landing on row 0, x<16: the clobber is a **`GP0(02)` Fill Rectangle**, words
   `021cbf00 / 00000000 / ff7a0014` — colour `0x0EE0`, **height 65402**. Every
   other fill in the run is a legitimate framebuffer clear
   (`x=0 y=32 w=320 h=224` and `x=0 y=256 w=320 h=224`).
4. A 65402-row fill is not a command the game issued. Dumping the GP0 word ring
   shows word `#7218027` — a **texcoord word** — being executed as an opcode.
   The GP0 parser is out of sync with the stream.
5. **Not a parser bug.** Recording every command boundary the engine chose over
   2048 consecutive commands: each consumed exactly its declared length, and
   `Primitive.getCommandLength` is correct for every opcode present
   (`0x26 0x34 0x38 0x3a 0x3c 0x3e 0x80 0xe1..0xe6 0x00 0x02`).
6. **Not the DMA walker.** Per-transfer stats show linked-list transfers
   terminating normally at ~1015-1136 packets / ~9350 words. No runaway walk, no
   missed terminator.
7. **Root: a torn linked-list packet.** Recording each packet's declared word
   count against the first word of its payload (read at the push site, with no
   extra bus access) finds packets whose header says **8 words** but whose body
   starts with a **12-word `0x3C` POLY_GT4**. A 12-word primitive cannot fit an
   8-word packet, so the engine runs off the end of it and every following word
   is parsed at the wrong offset. Eight such tears occur in 845M instructions,
   from ~580M onward, at packet ordinals 106-446 of ~1020 — the middle of the
   walk order, not the tail.
8. **Not a CPU/DMA race.** `Cpu.step` (`ps1-core/src/cpu/cpu.zig:79`) asks
   `dma.isCpuStalled` first and freezes the CPU for the entire transfer, so no
   game code runs between DMA words. The list is already inconsistent in RAM
   before the transfer starts.
9. **The game wrote both halves itself.** A RAM watchpoint on the torn packet
   (header `0x1c8104`, body `0x1c8108`) shows, before the DMA fires:
   `w32 @1c8104 <- 081c80d0` (len 8, next `0x1c80d0`) and
   `w32 @1c8108 <- 3c040404` (a POLY_GT4 code word). Both are ordinary 32-bit
   stores from this frame — this is not a stale body left over from a previous
   frame, and not a lost `setcode` byte store.
10. Packet addresses are self-consistent and contiguous: the 12-word packet at
    `0x1c80d0` occupies through `0x1c8103` and the next starts exactly at
    `0x1c8104`, whose 8-word body ends where the following packet at `0x1c8128`
    begins. The allocation layout is sane; only the header/body *pairing* is
    wrong.

## Warning: this bug is timing-sensitive

Adding a single extra `bus.read32` inside a probe (to look up a packet's first
payload word at header time) made the tear **vanish completely** — the run went
green-free and every fill was legitimate. The extra read perturbs
`bus.wait_cycles`, which changes DMA cost, which changes CPU/DMA interleaving.

Any instrumentation on this bug must avoid bus accesses entirely, or it will
hide the thing it is measuring. The working approach was to capture the first
payload word as it went past in the data branch of `doLinkedListWord`, which
costs nothing.

## Reproduction

```
zig build -Doptimize=ReleaseFast
./zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin \
  "games/Silent Hill (USA)/Silent Hill (USA).cue" 845000000 <snapdir> walk
```

Frames are clean through `frame_830.ppm` and glitched from `frame_840.ppm`
onward, permanently. `PS1_VRAM_DUMP=1` adds `vram_<n>.ppm` alongside each frame.

`walk` mode (added by this investigation, `205f523`) is required: the plain
`autostart` sequence only presses Start/Cross/Circle, which cannot move the
player, so a run idles forever on the opening street and never reaches the
scene. `walk` holds Up between the confirm presses.

Detecting the glitch programmatically: count pixels where `g > r+60 and
g > b+60` in the frame PPM. Clean frames score 0; glitched ones score ~29,000
of 71,680.

## What the next session should do — SUPERSEDED, kept for the record

The PC-diff plan below was not what closed this. What actually worked: a store
ring recording every write into RAM with the retiring PC (plus GTE colour loads
and pushes, exceptions and RFEs interleaved into the same ring), dumped when the
DMA walker saw a packet whose declared length could not hold its first
primitive. That points at the producing instruction directly, in one run.



The documented workflow in `CLAUDE.md` § "Debugging real games": an
**event-anchored PC diff against Avocado's headless tracer**, anchored on the
DMA2 kick. All linked-list transfers — torn and clean alike — are started from
PC `0x8001a3f8`, so anchor there on a frame known to tear (the transfer ending
at instruction 839,463,677 in the run above tears at packet 106) and diff
instruction streams to find where our execution first diverges.

Do **not** diff on cycle counts: Avocado bills 1 cycle per instruction and is
waitstate-blind, so its clock and ours legitimately differ by ~3x.

The expected shape of the answer: something in CPU or GTE execution makes the
game compute a wrong primitive pointer or a wrong primitive type. `gte/test-all`
passing 1150 cases does not rule out GTE — that suite does not cover every flag
edge case, and Silent Hill leans on the GTE colour/depth-cue path heavily.

## Incidental defects found on the way

Neither causes this bug. Both were left alone because fixing them changes
behaviour and would need a trace-golden recapture, and neither is on the path to
the reported symptom.

- **`gp0.zig` `fillRectangle` has out-of-range casts and no hardware masking.**
  `const w: i16 = @intCast(cmd_buffer[2] & 0xFFFF)` is illegal behaviour for any
  value above 32767 — the observed `h=0xFF7A` would **panic in a Debug build**.
  It also uses the signed 11-bit `Primitive.getX/getY`, where GP0(02) takes
  unsigned fields, and skips hardware's parameter masking entirely
  (`x & 0x3F0`, `y & 0x1FF`, w rounded up to a multiple of 16, `h & 0x1FF`).
  Worth fixing on its own merits, but note it would **not** have saved the
  palette: the correctly masked height is still 378 rows, which covers row 0.
- **Shaded-textured polygons discard their Gouraud colours.** The `0x34` and
  `0x3C` families (`drawShadedTexturedTriangle` / `drawShadedTexturedQuad` in
  `gp0.zig`) read only `cmd_buffer[0]` for colour and modulate the whole polygon
  by vertex 0's value, so per-vertex shading across a textured primitive is
  lost. The vertex/texcoord/CLUT/texpage word offsets in those two functions are
  correct — only the colour is dropped.

## Verification state after the fix

- `zig build test` — passes, including the new regression test.
- `zig build test-roms-ja -Doptimize=ReleaseFast` — 12/17, the documented
  baseline, unchanged.
- `zig build test-roms-pl -Doptimize=ReleaseFast` — fails, but **fails
  identically with the fix stashed**: pre-existing, not a regression.
- The 845M-instruction Silent Hill reproduction: 8 torn packets → 0, and the
  green-dominant pixel count is 0 on every frame (was 30,534 at `frame_840`).
  Frames still animate, so the run reaches the same gameplay.
- `zig build trace-golden -- verify` diverges by design — this is an intentional
  behaviour change — and the goldens were recaptured in a separate commit.

## Verification state at handoff (before the fix)

`ps1-core` is untouched by this investigation. All probe scaffolding was
reverted. At `205f523`:

- `zig build test` — passes.
- `zig build trace-golden -Doptimize=ReleaseFast -- verify` — all 7 workloads
  with goldens OK. The non-zero exit is the pre-existing `resident-evil-usa`
  missing-golden case documented in `CLAUDE.md`, not a regression.
