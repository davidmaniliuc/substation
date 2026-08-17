# Handoff — Tekken 3 (USA) freezes after the first KO

> ## 2026-08-17 (later): the headless blocker is FIXED
>
> `ps1-trace` now reaches the fight — Xiaoyu vs Jin, health bars, round timer
> counting down (`snap2/frame_990.ppm`). The VS-screen wedge is closed, so the
> Avocado differential this investigation has been waiting on can finally run.
>
> **Root cause:** when a ReadN seek completed, the drive flipped to `Reading`
> *and delivered the first sector in the same emulated instant*
> (`sector_timer = 0`, "deliver the first sector promptly"). Hardware still has
> to pull that sector off the disc — a full sector period. The zero gap matters
> because software polls GetStat for the Reading bit, and **every command clears
> `irq_queue`**, so the poll that observes the transition destroys the INT1
> posted in that same instant. The caller then receives sector *n+1* first.
>
> Tekken 3's CD library checks it: its data-ready ISR reads the 12-byte
> header/subheader with `CdGetSector(buf, 3)`, converts it back to an LBA and
> compares it against the LBA it asked for (`0x800920d0`); a mismatch jumps to
> the retry at `0x80092230`, which re-issues Pause/Setmode/Setloc/ReadN from the
> same place — forever. Measured, per cycle:
>
> ```
> i=401995102  sector 57:18:63 arrives, INT1 queued   (fifo empty, q=1)
> i=401999945  CDROM cmd=0x01 Getstat  -> irq_queue.clear() eats the INT1
> i=402142582  sector 57:18:64 arrives, one sector period later
> i=402143961  ISR runs 1,379 instr later, latches 64
> i=402144100  hdr_lba_check  s0=0003eee4 (got)  v1=0003eee3 (want)  -> RETRY
> ```
>
> The second sector was serviced in 1,379 instructions, which is what proves the
> ISR is healthy and the first sector's interrupt was simply destroyed.
>
> **Fix** (`ps1-core/src/cdrom/cdrom.zig`): the seek-completion branch now sets
> `sector_timer = cyclesPerSector()` instead of `0`. Pinned by
> *"the first sector of a read arrives a sector period after the drive reports
> Reading"* in `cdrom_test.zig`. Note this is **not** the invented 1,000,000-cycle
> ReadN seek that CLAUDE.md warns against touching — that line is unchanged.
>
> Everything below this box is the KO-freeze investigation and still stands.


**Status: five `[dup]` runs done, plus a full static decode of the round-phase
state machine (2026-08-17). The ring is formed by *two different render
dispatchers emitting the same objects in one frame*. It is not a re-run of
anything, and the frame-overrun theory is dead — measured, not argued.
The decode (see [§ The round-phase machine](#the-round-phase-machine-static-decode-2026-08-17))
changes the shape of the problem: `8003cb84`'s emits are a legitimate
**one-shot** KO transition, the gate that would suppress them means "time out"
and is correctly open on a health KO, and the `obj->0xC3` gate on the *other*
dispatcher is narrowed by a call that runs **after** those emits, on the same
frame. Run 5 then confirmed the whole model instruction-for-instruction and
retired every remaining gate (see
[§ Run 5](#run-5-2026-08-17--the-static-model-is-confirmed-exactly-and-it-is-exhausted)).
The game's code, as disassembled, emits fighter A twice here, and the emulator
is faithfully doing what it says — so **static analysis is finished and the
divergence is upstream game state**. The documented next step is an Avocado
differential anchored on this frame, which needs the headless harness to reach
the KO: the VS-screen wedge is now the critical-path blocker, not a side issue.**

---

## Start here

**Do not ask for another browser run yet — run 5 answered everything the probe
can answer.** Seven have been spent, and the next question is not one the
current instrumentation can reach.

1. Read [§ Run 5](#run-5-2026-08-17--the-static-model-is-confirmed-exactly-and-it-is-exhausted)
   and [§ Where to go next](#where-to-go-next). Between them, every gate on the
   render path is closed out with both a disassembly and a measurement.
2. The work that unblocks progress is the **headless VS-screen wedge**
   ([§ The headless blocker](#the-headless-blocker)) — an Avocado differential
   anchored on the faulting frame is the documented next step and it cannot run
   until `ps1-trace` reaches the KO.
3. If you do spend a run anyway, spend it on the question at the end of
   [§ Where to go next](#where-to-go-next): *when* the round phase enters
   state 4, relative to the KO animation. That needs watching whatever
   `800325bc` reads, which is not instrumented yet.

`zig-out/bin/emulator.wasm` (2026-08-17 16:58) carries the `[dup]` probe, the
accumulator dump wired into the fault itself, the corrected frame-pacing watch
list, the per-emit `site=` field, byte/halfword store visibility and the
round-phase watch list. A browser reproduction needs a hard reload
(Cmd+Shift+R — a soft reload serves the cached wasm).

### Verified state as of this handoff

- `zig build` green for all four targets; `zig build test` green.
- **`ps1-trace` now reproduces the headless VS-screen wedge in under a minute**
  (`lean`, 1.5B instructions in 56s). It still does not reach the KO.
- `zig-out/bin/emulator.wasm` built 2026-08-17 16:58. `[dup]` calls
  `dumpAccumulator()` at the fault (the ring used to be dumped only at the
  stall, ~50 frames later, by which point it had rolled over), the ring is 256
  entries, `pace_addrs` holds the five frame-pacing globals (counter address
  fixed to `09BC5C`), and every `[acc]` emit line carries `site=`. New this
  session: `store_watch` fires for `u8`/`u16` as well as `u32` and passes a
  `width`, `[acc]` lines print `[addr].width`, `game_addrs` watches the
  round-phase globals and the three `obj->0xC3` bytes, and `[dup]` prints a
  `[dup] round:` line with the phase, camera mode, clock, outcome word and all
  three `0xC3` bytes.
- `git log`: `bd111f8` on top of `3c7ffb8`. Still no fix written; the only new
  code is probe scaffolding.
- Working tree, all uncommitted scaffolding:

| path | what |
|---|---|
| `ps1-core/src/memory.zig` | the `store_watch` hook, now `u8`/`u16`/`u32` with a `width` argument |
| `ps1-core/src/cdrom/cdrom.zig` | `trace_commands` flag |
| `ps1-core/src/cdrom/commands.zig` | per-command line w/ params via `std.debug.print` |
| `ps1-wasm/src/main.zig` | shadow map, `[acc]`, `[dup]`, `walkChain`, `site=` (+430) |
| `ps1-trace/src/main.zig` | DMA-wedge detector, timer dump, **`lean` mode**, `[tick]`, `cd_log_from` |
| `tools-debug/` | throwaway: `SLUS_004.02`, `mipsdis.py`, `ppm2png.py` |
| `HANDOFF-tekken3.md` | this file |

Useful commands:

```
zig build                       # rebuilds emulator.wasm (always ReleaseFast)
zig build -Doptimize=ReleaseFast   # for ps1-trace; a Debug core is 0.45x real time

# `lean` is new and close to mandatory: it drops the audio-pipeline probe (a
# 24-voice scan plus SPU/CD ring scans on EVERY instruction, and a hashmap
# insert for the PC histogram). Without it the harness runs at ~330k instr/s;
# with it, ~27M instr/s. 1.5B instructions goes from ~75 minutes to 56 seconds.
# Verified behaviour-identical: same counters and same display state at 90M.
./zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin \
    "games/Tekken 3 (USA)/Tekken 3 (USA).cue" 1500000000 <snapdir> autostart lean

python3 tools-debug/ppm2png.py <snapdir>/frame_2990.ppm
lldb -p $(pgrep -f ps1-trace) --batch -o bt -o detach   # what is it actually doing
```

---

## The bug as reported

Tekken 3 (USA), browser frontend at `127.0.0.1:8000`. Character select and the
start of the fight are fine. Immediately after the replay of the final hit of
the first KO, the picture **freezes on a still image** while **audio keeps
running but is complete garbage**. Deterministic — reproduced on every attempt.

`Cpu.step()` consults `bus.dma.isCpuStalled(bus)` first, so while a channel is
active the CPU retires *nothing* while the peripherals keep ticking. A circular
GPU linked list therefore freezes the picture and leaves audio running — the
reported symptom exactly.

---

## What is now proven

**The game builds a display-list chain whose tail links back to its own head,
because one object gets emitted a second time in the same frame with no
ordering-table reset in between.**

The primitive chains are **pre-linked once** and reused; per frame only the
*tail tag* of each chain is rewritten. So a tag whose last-writer frame is
thousands of frames old is normal, not staleness. Chain packets link
*downward*; the single tag that links upward is the ring.

Normal frame (from the `[acc]` trace; `f=` is the wasm rAF counter, not the
game's frame counter):

```
f=3522 8007d8e8 [0a8544] = 000a8540    OT slot reset to its back-link
f=3522 80037b58 [0dc068] = 040a8540    chain A tail -> the OT slot below
f=3522 8003b594 [0a8544] = 000dc600    accumulator = head of A
f=3522 80037b58 [0dc620] = 040dc600    chain B tail -> head of A
f=3522 8003b594 [0a8544] = 000dcbb8    accumulator = head of B
```

That pattern repeats cleanly for every frame from 3521 to 3531. The faulting
frame adds a third emit of the **same** object:

```
f=3532 8007d8e8 [0a8544] = 000a8540
f=3532 80037b58 [0dc068] = 040a8540
f=3532 8003b594 [0a8544] = 000dc600
f=3532 80037b58 [0dc620] = 040dc600
f=3532 8003b594 [0a8544] = 000dcbb8
f=3532 80037b58 [0dc620] = 040dcbb8    <-- B's tail rewritten to B's OWN head
f=3533 8003b594 [0a8544] = 000dcbb8
```

`0dcbb8`'s pre-linked chain runs back down through `0dc620`, so the list closes
into the observed 128-node ring. DMA2 then walks it forever.

Corroborating detail: the write-back of that third emit landed in the *next*
rAF frame, so the extra pass straddled a frame boundary.

### The mechanism, mapped out of `SLUS_004.02`

```
8003a818  per-object render entry
 └ 8003a87c
    8003a994  lw [0x800ADCA4];  8003a99c bne -> skip the emit
    8003a9a4  jal 8003b4f8
 └ 8003b4f8  emit
    8003b518  lw  acc, 0xFBC(db)        db = *(*(0x800A8C54) + 4)
    8003b520  and acc, 0x00FFFFFF
    8003b558  lw  sel, [0x800ADEFC]
    8003b55c  jal 80037b28
     └ 80037b28  a1 = objChainTable[sel]        objChainTable = obj->0x1274
        80037b58  sw (acc | 0x04000000), 0(a1)  *** the store that rings ***
        80037c18  return head & 0x00FFFFFF
    8003b574  lw [0x800ADFD0];  8003b57c beq -> skip the write-back
    8003b594  sw head, 0xFBC(db)
```

`db+0xFBC` resolves at runtime to the OT slots **`0a8544` (sel=1)** and
**`0a7544` (sel=0)** — the probe tracked exactly those two, confirming the
double buffer. It is read at `8003b518` and written at `8003b594`, and those
are the **only two accesses to that field in the entire executable**.

The two render dispatchers, each of which calls `8003a818` exactly twice:

| site | objects | gate |
|---|---|---|
| `8002bab8` / `8002bad0` | the two fighters (`s0`, `s1`) | each on `obj->0xC3 != 0` |
| `8003d1c0` / `8003d1c8` | `s2`, `s4` | `[0x800ADE78] & 1 == 0` |

A third emit in one frame means one of these re-entered. **That was the open
question, and the `[dup]` run below answers it.**

---

## The `[dup]` result (2026-08-17)

```
[dup] f=3612 closes [0c8be8] = 040c9738 sp=801ffdf0 ra=8003b564 gp=8009b9a8
[dup] s0=000c9738 s1=800a9228 s2=800a9228 s3=00000008 s4=800ac340 s5=80090000 s6=800afa88 s7=bfc0702c
[dup] gates: ADCA4=00000000 ADFD0=00000001 AFA88=00000000 9542C=00000001 ADEFC=00000000 A8C54=800a8590
[dup] sp+00: 800a9228 00000008 800ac340 80090000
[dup] sp+16: 00000000 800b0000 8003a9ac 8003a990
[dup] sp+32: 0000073d fffffdb5 8004381c 800aaab4
[dup] sp+48: 800a9228 800aaab4 800ac340 8003a868
[dup] sp+64: 00000000 00000000 800a9228 800aaab4
[dup] sp+80: 800a9228 8002bac0 800aaab4 00000008
```

**Correction to the frame arithmetic recorded above:** `8003b4f8`'s prologue is
`addiu sp,-32 / sw s1,20 / sw ra,24 / sw s0,16`, so its saved `ra` is at
`sp+24` and its saved `s0`/`s1` at `sp+16`/`sp+20` — the earlier note had the
right offsets but attributed them to the wrong frame. `80037b28` really does
leave `sp` alone (verified in the disassembly), so `sp` is `8003b4f8`'s frame.

Unwound against `SLUS_004.02`, every link checked against a real `jal`:

| frame | size | saved `ra` | at |
|---|---|---|---|
| `80037b28` | leaf, no frame | — | store at `80037b58` |
| `8003b4f8` | 32 | `8003a9ac` | `sp+24` ✓ returns from `jal 8003b4f8` @ `8003a9a4` |
| `8003a87c` | 32 | `8003a868` | `sp+60` ✓ returns from `jal 8003a87c` @ `8003a860` |
| `8003a818` | 24 | `8002bac0` | `sp+84` ✓ returns from `jal 8003a818` @ `8002bab8` |

So the path is:

```
8002bab8  jal 8003a818, a0 = s0     <-- the FIRST fighter call, not a re-entry
 └ 8003a860  jal 8003a87c
    └ 8003a9a4  jal 8003b4f8
       └ 8003b55c  jal 80037b28
          └ 80037b58  sw  *** rings the list ***
```

**Nothing on the stack is abnormal.** One dispatcher, its first call, no
recursion, and every gate on the path reads its normal proceed value
(`ADCA4=0` → emit not skipped; `ADFD0=1` → write-back not skipped;
`AFA88=0 ≠ 8` → the ordinary `80037b28` branch, not the `800793b8` one).

What this kills:

- **Hypothesis 2 (both dispatchers ran) is dead** — only `8002bac0` is on the
  stack.
- **Hypothesis 3 (same object listed twice) is dead** — the dispatcher's two
  fighters are distinct: `s0 = 800a9228`, `s1 = 800aaab4` (both visible at
  `sp+48`/`sp+52` and `sp+80`/`sp+88`). The object being emitted is fighter #1,
  `800a9228`.
- **The "`sel` and `db` drifted apart" theory is dead too, analytically — no
  repro needed.** Scanning the whole executable, `0x800ADEFC` (`sel`) has
  exactly one writer, `80028c04`, and `0x800A8C54` (the display-buffer
  descriptor) has exactly one, `80028c40`. The flip function computes
  `db = 0x800a8590 + sel*20` **unconditionally, on both sides of the branch
  that skips the `sel` update** (`80028c08` reloads `sel` after the branch
  target). They cannot desync. The dump agrees: `sel = 0` and
  `A8C54 = 800a8590 = 0x800a8590 + 0`.

### What is therefore proven

`db+0xFBC` — the ordering-table accumulator — has **exactly two accessors in
the entire executable**: the read at `8003b518` and the write-back at
`8003b594` (confirmed by an image-wide scan for the `+0xFBC` displacement),
plus the per-frame reset through the OT-clear routine.

The emit is correct. The ring forms because the accumulator *already held a
node of fighter #1's own chain* when fighter #1's emit read it. That can only
mean **an emit landed against this buffer after the last OT reset**.

And that explains why the bug is specific to the KO and deterministic there:
each fighter is gated on `obj->0xC3 != 0` (`8002baa8`, `8002bac0`). Once one
fighter is KO'd its gate drops, so only **one** object is emitted per pass —
which makes "the first object emitted in the extra pass is the same as the last
object emitted in the previous one" unavoidable, and that is exactly the
condition that links a chain's tail to its own head.

---

## Retracted — do not redo these

Each of these was believed at some point in this investigation and is wrong.

- **"The `[ch2]` MADR only advances 0xF0/second, so DMA crawls."** The walk
  wraps, so a lap nets zero displacement. The DMA spins the ring at full speed.
- **"The headless run seeks past the end of the disc."** `ps1-trace` printed BCD
  MSF bytes with `{d}`, inflating positions ~1.5x. Fixed in `bd111f8`.
- **Terminator theories** (zero-next, Avocado's `addr == 0`, bit 23). Ruled out:
  `zero_next=false`, and every node of the ring masks into the pool, so nothing
  escapes via bit 23 either. Do **not** "fix" `doLinkedListWord`'s terminator
  handling on the strength of this bug.
- **"The ring body is a stale list from ~1750 frames earlier."** The `[who]`
  probe showed the ring's tags last written at f=1638/1639 with the freeze at
  f=3600, which looked damning. It is not: chains are pre-linked once and only
  the tail tag is rewritten per frame, so old writer frames are expected.
- **"The buffer flip was skipped."** `80028c04` does skip the selector update
  when `80029628` reports `[0x8009542C] == 0`, and `80029a28`'s per-frame relink
  is likewise gated on it — a tidy theory. The `[acc]` trace kills it: `flip=1`
  throughout and `sel` alternates 0/1 cleanly every frame, including the
  faulting one.
- **"Our Timer 2 over-reports, so the game's frame-budget check always trips."**
  `80029674` really does measure with `GetRCnt(RCntCNT2)` against
  `[0x80095430] - 264`, and `80029a28`'s relink loop really does bail out early
  on it. But Tekken programs Timer 2 with clock source **2**
  (`mode=0x0248`/`0x0258`, `target=0x13A7`, measured headless), which
  `timer.zig`'s `mode_clock_source_sysclk_div8` handles correctly. The budget is
  also only ~5% of the counter's period, i.e. a time-slice guard, so bailing out
  early is routine rather than a fault. Timer 2 is not implicated.
  *(There is a real latent gap here regardless: `timer.zig` treats only `0x0200`
  as sysclk/8, but for Timer 2 clock source **3** is also sysclk/8. Tekken does
  not use it, so it is not this bug — worth fixing on its own merits.)*
- **The original pool-filter probe.** It only logged stores whose value looked
  like an upward-linking tag inside two hardcoded pools. Replaced by a
  last-writer shadow map, which guesses nothing.

---

## The probe that is loaded and waiting for a run

`zig build` is done; `zig-out/bin/emulator.wasm` is current (14:53).

`ps1-core/src/memory.zig` exposes
`pub var store_watch: ?*const fn (offset, value) void`, called from the RAM
branch of the generic `write` for `T == u32` only, with the physical offset.
Null-checked, inert when unset. Marked TEMPORARY.

`ps1-wasm/src/main.zig` carries:

- **`last_writer` / `last_writer_frame`** — a 2 MB + 1 MB shadow map recording,
  for every RAM word, the PC of the last 32-bit store and the frame it happened
  in (bit 0 of the PC flags a DMA-sourced store). This is what attributed every
  ring node and killed the stale-list reading.
- **`[acc]`** — a 64-entry ring of every emitter tag store (`pc == 0x80037b58`)
  and every store to a tracked `db+0xFBC`, each with `sel`, the flip gate
  `[0x8009542C]` and the write-back gate `[0x800ADFD0]`. This produced the
  trace above.
- **`[dup]`** — *not yet run*. Fires once, the instant a tag store links upward,
  and dumps `sp`, `ra`, `s0`-`s7`, six gate globals and 24 stack words.
  `80037b28` never touches `sp`, so at that instant `sp` is `8003b4f8`'s frame:
  its saved `ra` is at `sp+24` and its saved `s0`/`s1` at `sp+16`/`sp+20`.
  Return addresses on the stack are recognisable by eye (`0x800xxxxx`, landing
  just after a `jal`) and map straight back through `mipsdis.py`.
- The older stall/PC probe, the `[ch2]` per-second line, `dumpRegion` (now
  unreferenced), and `walkChain` (Floyd + loop-length measurement).

**Ask the user to reproduce to the KO freeze once and paste the `[dup]` block**
— about 10 lines, emitted at the fault rather than at the stall, so the
`[acc]`/`[walk]`/`[mem]` output can be ignored this time.

<a id="the-open-fork"></a>
### The fork, resolved (second `[dup]`+`[acc]` run, 2026-08-17)

> **RETRACTED by run 4 (see [§ Run 4](#run-4-2026-08-17--two-dispatchers-not-two-passes)).**
> The pass does *not* run twice. Everything below about emit counts and the
> single OT reset is accurate; only the "second pass" interpretation is wrong —
> the extra emit comes from a *different dispatcher* in the same pass. The
> observation that the extra emit's object depends on which `obj->0xC3` gates
> are open at that instant still holds, and is why runs 1/2/3 saw A, B and B.

**It is (a): the render pass runs a second time against a single OT reset.**
The OT reset is present on the faulting frame, so nothing is skipped.

Frames 3664–3675 are metronomic — one reset, two emits, `sel` alternating:

```
f=3666 8007d8e8 [0a8544] = 000a8540    reset
f=3666 80037b58 [0dc068] = 040a8540    emit A:  A.tail -> OT slot
f=3666 8003b594 [0a8544] = 000dc600    acc = A.head
f=3666 80037b58 [0dc620] = 040dc600    emit B:  B.tail -> A.head
f=3666 8003b594 [0a8544] = 000dcbb8    acc = B.head
```

The faulting frame is that, plus one more emit and no second reset:

```
f=3676 8007d8e8 [0a8544] = 000a8540    reset            <-- present
f=3676 80037b58 [0dc068] = 040a8540    emit A
f=3676 8003b594 [0a8544] = 000dc600    acc = A.head
f=3676 80037b58 [0dc620] = 040dc600    emit B
f=3676 8003b594 [0a8544] = 000dcbb8    acc = B.head
f=3676 80037b58 [0dc620] = 040dcbb8    emit B AGAIN -> its own head  *** RING ***
```

`[dup]` for this run returns to **`8002bad8`** — the *second* dispatcher call
(`jal 8003a818` @ `8002bad0`, `a0 = s1 = 800aaab4` = fighter B). The first run
returned to `8002bac0`, the *first* call, and its third emit was A.

**Why three emits and not four:** the second pass rings on its very first emit,
which hangs DMA2 immediately, so no fourth emit ever happens. Which fighter
emits first in that second pass depends on the `obj->0xC3 != 0` gates at that
instant, which is why run 1 gave A,B,A and run 2 gave A,B,B. Right after a KO
one fighter's gate is dropping, so the pass emits a single object — guaranteeing
"first emit of pass 2 == last emit of pass 1", which is exactly the tail-to-own-
head condition.

Also confirmed here: the reset store records `ra = 8007d8ec`, which is precisely
the return address for the `jal` at `8007d8e4` in the boot EXE — so the address
mapping is right even though the stored *value* disagrees. See the overlay
caveat below.

<a id="the-re-render-loop-the-real-mechanism"></a>
### The re-render loop (third `[dup]`+`[acc]` run, 2026-08-17)

The third run reproduced the fault at f=3159, sel=0, ring-closing store
`[0c91a0] = 040c9738`, `[dup]` returning to **`8002bad8`** — the second
fighter call, same as run 2. Emits that frame: A (`[0c8be8]`), B (`[0c91a0]`),
then B again into its own head.

Disassembly of the surrounding code settled three things and opened one.

**1. The game has an explicit frame-overrun re-render loop, and its decider is
a counter no probe had ever seen.**

```
800508b8  sw zero, [0x800ADCA4]     emits ENABLED
800508c4  jal 0x8002ae58            <-- LOOP TOP: run the frame
800508d0  bne s0, 1  -> exit
800508e0  bne [0x800ADCA4], 0 -> exit
800508e8  jal 0x800295f4            "did we miss a frame?"
800508f0  beq v0, 0  -> exit
800508f8  sw 1, [0x800ADCA4]        SUPPRESS emits on the re-run
800508fc  jal 0x80029dc0 (a0=1)
80050904  j 0x800508c4              <-- run the frame again
8005090c/80050914  sw zero, [0x800ADCA4]
```

```
800295f4  lw v0, [0x8009BC5C]       the frame-done counter
80029600  slti v0, v0, 2
80029608  xori v0, v0, 1            return (counter >= 2)
```

So the game *does* re-run a frame it overran — but it sets the emit gate first,
precisely so the re-run does **not** emit again. That is the correct design, and
it means a plain overrun cannot by itself produce a duplicate emit.

**2. The frame-pacing watch was pointed at an address that does not exist.**
`pace_addrs` carried `0x0ABC5C`, derived from `sw zero, -17316(v0)` after
`lui v0, 0x800a` by reading the displacement as positive. MIPS sign-extends it
(-17316 = -0x43A4), so the counter is **`0x8009BC5C`**. Every other pacing
address in the list was right; this one was off by 0x10000, so the counter the
busy-wait spins on, the submit path increments, and `800295f4` tests **never
appeared in either `[acc]` dump**. Corrected 2026-08-17; that is the only
functional change to the probe.

**3. The re-render loop did not iterate on the faulting frame.** Its loop-back
store `800508f8 [0adca4] = 1` is in the watch list and is absent from the trace,
and `800508b8`/`80050914` each appear exactly once, bracketing *all three*
emits. So the three emits came out of **one** `jal 8002ae58`.

That is a much tighter box than "the render pass ran twice", and it is the open
question now. `8002ae58` is the render state machine; its four
`jal 0x8002ba64` sites (`8002b030`, `8002b1ec`, `8002b620`, `8002b688`) sit in
mutually exclusive switch branches, and `8002ba64` itself is straight-line:

```
8002baa8  lbu v0, 195(s0);  beq -> skip
8002bab8  jal 8003a818 (a0=s0)          ra 8002bac0
8002bac0  lbu v0, 195(s1);  beq -> skip
8002bad0  jal 8003a818 (a0=s1)          ra 8002bad8
8002bad8  lw [0x800AFA88]; if == 8 and s2->0xC3: jal 8003a818 (a0=s2)
```

No loop anywhere on that path, and `[dup]` shows a single
`8003a818 -> 8003a87c -> 8003b4f8` nesting. `AFA88 = 0` at the fault, so the
third gated call is skipped. **Three emits therefore cannot come from one
`8002ba64` call**, which leaves exactly two candidates:

- the dispatcher ran twice inside one `8002ae58` (some loop not yet found), or
- one object is emitted by **two different dispatchers** in the same pass — the
  handoff already noted a second pair at `8003d1c0`/`8003d1c8`, gated on
  `[0x800ADE78] & 1 == 0`. If a KO opens that gate while the fighter gate is
  still open, the same object is emitted twice with no re-run involved.

The new per-emit `site=` field separates these on sight: same site twice means a
re-run, two different sites means two dispatchers.

Also worth noting from this run: on the faulting frame `80029a14` (which sets
`[095424] = 1` at the end of `800299e0`, and `800299e0` has **zero `jal` sites**
in the image, so it is a callback) fires *between* the ring-closing tag store
and its write-back. An interrupt landed in the middle of the emit. It happens
after the ring is already closed, so it is not the cause, but it does mean the
GPU DMA was kicked while the list was still being built.

### Run 4 (2026-08-17) — two dispatchers, not two passes

Fault at f=2793, `[0c91a0] = 040c9738`, `[dup]` returning to `8002bad8`. The new
`site=` field settled it on sight.

Every clean frame — both emits from the fighter dispatcher:

```
80037b58 [0c8be8] = 040a7540  site=8002bac0
80037b58 [0c91a0] = 040c9180  site=8002bad8
```

The faulting frame:

```
80037b58 [0c8be8] = 040a7540  site=8003d1c8   <- the OTHER dispatcher
80037b58 [0c91a0] = 040c9180  site=8003d1d0   <- the OTHER dispatcher
80037b58 [0c91a0] = 040c9738  site=8002bad8   <- fighter dispatcher, B again *** RING ***
```

**Both dispatchers ran, over the same two objects.** The chain tails are
identical (`0c8be8`, `0c91a0`), so the two paths render the same pair.

`8002ae58` calls both on one straight-line path — `8002af80 jal 8003cb84`, then
fall-through to `8002b014` and `8002b030 jal 8002ba64` — so *being called* is
normal every frame. What separates them is their emit gates:

| dispatcher | emit sites | gate |
|---|---|---|
| `8003cb84` | `8003d1c0` / `8003d1c8` | round phase `[0x80096F2C] == 4`, then `[0x800ADE78] & 1 == 0` |
| `8002ba64` | `8002bab8` / `8002bad0` / `8002bafc` | per object, `obj->0xC3 != 0` |

On the faulting frame `8003cb84` ran its emit branch while fighter B's `0xC3`
was still set, so `8002ba64` emitted B a second time. Fighter A's `0xC3` had
already dropped, which is why the extra emit is B and why it lands on a tail
whose chain now runs back to its own head.

> **Amended by the static decode below.** This section originally said clean
> frames exit early via `j 8003d450` at `8003d198`. They do not — `8003d450`
> sets the round phase to 9, it is not a per-frame early exit. Clean frames
> simply have the phase at 0/1, whose handlers contain no emit at all. The
> `[0x800ADE78] & 1` gate is also not what it looked like; see
> [§ The round-phase machine](#the-round-phase-machine-static-decode-2026-08-17).

**`[0x800ADE78]` has exactly two writers** (image-wide scan for the `0xde78`
displacement): `8002aa0c` (`sh zero`) and `8003e4f8`. The computing writer's
bit 0 is set in a delay slot at `8003e48c`:

```
8003e478  lw   v0, [0x800ADBCC]
8003e488  bne  a2, a3, ...          ; a2/a3 = each fighter's +0x400 halfword
8003e48c  slti v1, v0, 1            ; delay slot -- always runs
   ...
8003e4f8  sh   v1, [0x800ADE78]
```

so **`ADE78 bit0 = ([0x800ADBCC] < 1)`**. `obj->0xC3` is written by
`8003ebd0`/`8003ebd4` (both fighters, same value 1), `8002acc4`/`8002acc8`
(both, zero), `8002b9c4`/`8002b9d0` and `8002bf68`.

### What run 4 retires

- **The frame-overrun / DMA-stall theory is dead, measured.** `[09bc5c]` is `1`
  on every frame including the faulting one; it never reaches 2, so
  `800295f4` never returned true and the game never believed it overran. The
  earlier note that our CPU-freezing DMA "is exactly the thing that would make
  it believe that" is unsupported — it never believed it.
- **"The render pass runs a second time" is dead.** One `8002ae58`, one OT
  reset, one `800508b8`/`80050914` bracket, no `800508f8` loop-back.

<a id="the-round-phase-machine-static-decode-2026-08-17"></a>
### The round-phase machine (static decode, 2026-08-17)

Run 4 left "why did `8003cb84` take its emitting path" open. Disassembling it
answers most of that with no repro needed, and **corrects run 4's reading of the
gate**.

`8003cb84` is not gated by `[0x800ADE78]` at the top at all — it is a **ten-state
machine** on `[0x80096F2C]`, dispatched through a jump table at `0x8001A354`:

```
8003cbc4  lw a0, [0x80096F2C]
8003cbd0  if a0 >= 2:  [0x80096F30] += 1
8003cbf4  if a0 >= 10: exit
8003cc00  jr  [0x8001A354 + a0*4]

  state 0 -> 8003cc18   state 5 -> 8003d218
  state 1 -> 8003cc80   state 6 -> 8003d27c
  state 2 -> 8003cde8   state 7 -> 8003d45c
  state 3 -> 8003d054   state 8 -> 8003d468
  state 4 -> 8003d124   state 9 -> 8003d500
```

**The emits at `8003d1c0`/`8003d1c8` live in state 4 only**, and state 4 is a
one-shot: the emitting branch ends

```
8003d208  lw   v0, [0x80096F2C]
8003d210  addiu v0, v0, 1
8003d214  sw   v0, [0x80096F2C]      ; -> 5
8003d218                              ; ...and falls straight through into
                                      ;    state 5's body, same frame
```

so it fires on exactly one frame — the faulting frame — and never again. That
is why clean frames show only `8002ba64`'s emits: the machine is simply in
state 0/1 (the fight), whose handlers do not emit. States 5 and 6 (the replay
tick, a 300-frame countdown on `[0x80096F38]`) do not emit either.

**Correction to run 4:** `j 8003d450` at `8003d198` is *not* a per-frame early
exit. `8003d450` is `[0x80096F2C] = 9`, the skip-the-replay transition. Nothing
in `8003cb84` exits early every frame.

Three more things the disassembly settles:

**1. `[0x800ADE78] & 1` means TIME OUT, so it is correctly clear on a KO.**
`[0x800ADBCC]` is the round clock: `8002a9c8` sets it to `600 * (setting + 2)`
at round start and `8003cce8` decrements it once per frame while the fight
runs. `8003e478` computes the outcome word with `slti v1, [0x800ADBCC], 1` in
the delay slot of the health compare, then OR-s in the health bits
(`|6` = double KO, `|32` = draw on health). So bit 0 is the timeout flag alone.
On a health KO it is 0, `8003d1b8` does not branch, and state 4 emits both
fighters **by design**. `[0x800ADE78]` and `[0x800ADBCC]` are therefore no
longer suspects.

**2. `8002ba64` runs on both arms of the `[0x800954A4]` test, so it always
runs.** `8002af84` latches `8003cb84`'s return into `[0x800954A4]`; `8002af90`
branches on it. The non-zero arm reaches `8002b030 jal 8002ba64`, and the zero
arm falls through `8002b0a0 … 8002b1e4` to `8002b1ec jal 8002ba64`. There is no
"the other dispatcher was supposed to be skipped" — both dispatchers being
called on the state-4 frame is normal.

**3. And `obj->0xC3` is dead too — the KO call that narrows it runs *after*
state 4's emits, on the same frame.** `8002b98c(idx)` clears `0xC3` on all
three objects (`+195`, `+6479`, `+12763` off the same base) and sets it on
object `idx` — "render only fighter `idx`". Its only two call sites are inside
`8003ea5c`, the KO handler:

```
if      s1->0x48 > 0:  [0x8009546C] = 7;  8002b98c(s0->30)
else if s0->0x48 > 0:  [0x8009546C] = 6;  8002b98c(s1->30)
else                :  [0x8009546C] = 2;  s0->0xC3 = s1->0xC3 = 1
```

and `8003ea5c` has exactly two callers: `8003d0d8` (state 3) and **`8003d1d4`
— eight instructions after state 4's second emit**. State 3 only reaches its
call in tag-team mode (`[0x800AFA88] == 7`, where it sets the phase straight to
5 and skips state 4 entirely); in ordinary versus mode state 3 is four
instructions long, sets the phase to 4 and returns. So in a normal round
`8002b98c` runs for the first time *between* the two dispatchers, and the frame
reads:

```
8003d1a0  jal 8003e8c8          set the +0x48 KO markers
8003d1c0  jal 8003a818 (s2)     emit fighter A     <-- 8003cb84
8003d1c8  jal 8003a818 (s4)     emit fighter B     <-- 8003cb84
8003d1d4  jal 8003ea5c          KO decision -> 8002b98c: only B stays visible
   ...
8002b1ec  jal 8002ba64          emit every obj with 0xC3 -> emit B AGAIN
```

Both fighters carry `0xC3 = 1` all through the fight (set by the round init at
`8002bf68`, which is why clean frames show `8002ba64` emitting two objects), so
there is no state of that byte at the emits that avoids the collision. **The
code as disassembled emits three times on this frame, and our run does exactly
that.** State 4 emits `s2 = 0x800A9228` and `s4 = 0x800AAAB4`, the same two
objects `8002ba64` renders, and emitting one object twice with the same `sel`
writes the same `objChainTable[sel]` tail twice — the second write always
pointing it at that chain's own head.

### Run 5 (2026-08-17) — the static model is confirmed exactly, and it is exhausted

Fault at f=3684, sel=1, ring-closing store `[0dc068] = 040dcbb8`, `[dup]`
returning to `8002bac0`. The faulting frame, in full:

```
8007d8e8 [0a8544] = 000a8540                   OT reset
800508b8 [0adca4] = 00000000                   re-render loop top, emits enabled
8002af84 [0954a4] = 00000000
80037b58 [0dc068] = 040a8540  site=8003d1c8    emit A   <- 8003cb84 state 4
8003b594 [0a8544] = 000dc600                   acc = A.head
80037b58 [0dc620] = 040dc600  site=8003d1d0    emit B   <- 8003cb84 state 4
8003b594 [0a8544] = 000dcbb8                   acc = B.head
8003eba8 [09546c] = 00000003                   KO camera mode      <- 8003ea5c
8002b9bc [0ac403].1 = 0                        8002b98c: clear all three 0xC3
8002b9c0 [0aab77].1 = 0
8002b9c4 [0a92eb].1 = 0
8002b9d0 [0a92eb].1 = 1                        ...and set fighter A's
8003d214 [096f2c] = 00000005                   phase 4 -> 5
8003d268 [096f2c] = 00000006                   phase 5 -> 6 (same frame)
80063b8c [09546c] = 00000005
80037b58 [0dc068] = 040dcbb8  site=8002bac0    emit A AGAIN  *** RING ***
```

`[dup] round: state=6 camera=5 ret954A4=00000000 clock=1460 outcome=0002
C3=[1 0 0]`.

Every prediction in the section above lands: the emit sites, the one-shot phase
increment falling through into state 5's body, `8002b98c` running *between* the
two dispatchers, and the ring closing on the object it had just made visible.
The resulting list is `[0a8544] -> A.head -> … -> A.tail(0dc068) -> B.head ->
… -> B.tail(0dc620) -> A.head`, which is the observed 128-node ring.

Details worth keeping:

- **`[0x800954A4]` is written in the *delay slot* of `jal 8003cb84`
  (`8002af84`), so it holds the return of `80032178` — not `8003cb84`'s.**
  It reads 4 on the frame before the fault and 0 on the faulting frame. It does
  not matter for the ring (both arms reach `8002ba64`) but every earlier note
  calling it "`8003cb84`'s return latch" is wrong.
- **The phase reached 4 at least 17 frames before the emit.** There is no
  `096f2c` write anywhere in the ring's 18-frame window except the two on the
  faulting frame, so the machine idles in state 4 on its `8003d124 jal 800325bc`
  gate and fires the emit branch when that finally returns non-zero. Through
  the whole wait both fighters keep `0xC3 = 1` and `8002ba64` emits both,
  cleanly.
- **`sel` and the tail addresses agree** — `sel=0` uses `0c8be8`/`0c91a0` and
  OT slot `0a7544`; `sel=1` uses `0dc068`/`0dc620` and `0a8544`; they alternate
  every frame. The run-3 "sel alternates but the tails do not" contradiction was
  an artefact of comparing excerpts from alternate frames. Not a bug.
- **`wb=1` on every emit**, so the write-back-gate theory is dead — and it could
  not have helped anyway: `80037b28`'s tag store happens *before* the object is
  rendered and before `[0x800ADFD0]` is read, so the ring closes whatever the
  gate later says.
- **The KO handler's path is `8003eb18 j 8003eba8` with `addiu v0, zero, 3` in
  the delay slot** — camera mode 3, reached because fighter A's `+0x48` is
  positive. `8002b98c(a) = base + 6284*a` (verified from `8002b98c`'s full index
  math), so its argument `obj->30` is a plain 0..2 object index and A's is 0.
- **No overlay covers the render path.** `PS1_RAM_DUMP=1` on a headless run and
  a word-by-word compare shows RAM at `0x8003eb2c..0x8003ebe0` identical to
  `SLUS_004.02`. `SLUS_004.02` is trustworthy for the `8002xxxx`/`8003xxxx`
  render code. (Useful recipe, keep it:
  `PS1_RAM_DUMP=1 ./zig-out/bin/ps1-trace … <snapdir> autostart lean` writes
  `<snapdir>/ram.bin`, a full 2 MB image to diff or disassemble.)

<a id="where-to-go-next"></a>
### Where to go next

**Static analysis is finished.** Every gate on the path has now been read out of
the disassembly *and* measured in a run, and they all agree: the game as written
emits fighter A twice on the frame the round-phase machine leaves state 4, and
the emulator reproduces that faithfully. Specifically, none of these can break
the collision, and none should be re-opened without new evidence:

| candidate | why it is dead |
|---|---|
| `[0x800ADE78] & 1` (`8003d1b4`) | bit 0 is the *time-out* flag; `clock=1460`, so it is correctly 0 on a health KO |
| `obj->0xC3` (`8002baa8`/`8002bac0`) | `8002b98c` narrows it to one object *eight instructions after* state 4's emits, and every branch of `8003ea5c` leaves at least one of the two objects visible |
| `[0x800954A4]` (`8002af90`) | written in a delay slot, and both of its arms reach `jal 8002ba64` anyway |
| `[0x800ADFD0]` / `wb=` (`8003b574`) | measured 1, and the ring-closing store precedes it in `8003b4f8` regardless |
| `[0x800ADCA4]` (`8003a99c`) | measured 0 on every store of the faulting frame |
| `[0x800ADEFC]` / `sel=` | alternates per frame and the tails alternate with it; both emits of A necessarily hit the same `objChainTable[sel]` |
| frame overrun / re-render | `[09bc5c]` never reaches 2; `800508f8` never fires |

So the divergence is **upstream game state** — something that puts Tekken into a
frame combination hardware never sees. Nothing in the render path points at a
specific emulated subsystem, and reasoning forward from the disassembly cannot
narrow it further, because the render code behaves correctly given its inputs.

That makes the next step the differential the repo already documents
(`CLAUDE.md` § Debugging real games, and
[reference-avocado-execution-diff]): anchor on this frame in Avocado, walk back,
and find the first state that differs. Doing that needs the headless harness to
reach the KO — **so the VS-screen wedge below is no longer a side issue, it is
the blocker on the critical path.** Recommend fixing it first.

A cheaper thing to try before that, since it costs one browser run: the phase
sits in state 4 for 17+ frames waiting on `8003d124 jal 800325bc`. Watch
`[0x80096F2C]` and whatever `800325bc` reads, and check whether the phase
*enters* state 4 at a plausible moment. If our run enters state 4 far earlier or
later than the KO animation warrants, that localises the upstream divergence to
the fight logic rather than to rendering.

### The frame-pacing machinery (mapped, and now known not to be involved)

```
80029894  begin frame: [09BC5C]=0, [0ADCA4]=0 (emits enabled),
                       [095428]=0, [09542C]=1
   ...     render pass emits
80029820  submit: reads [09BC5C], `sltu a0,zero,a0; sll a0,a0,1` -> jal 80029dc0
                  with 0 or 2  *** an explicit "a frame is already pending"
                  branch, i.e. a frame-overrun path ***
80029874          [09BC5C] += 1        (an increment, not a set)
800296c4  [095428]=0; if [09542C]!=0 -> jal 80029a28 (relink); [09BC5C]=0;
          then SPIN: `jal 8004ce54` (a pure PRNG advance, v0 = v1*5+1, seed at
          0x800AF2A8) until [09BC5C] != 0; then [0ADCA4]=0 and return
80028bc0  flip: [0AFA4C]++, gate 80029628, maybe update sel, recompute
          db = 0x800a8590 + sel*20, jal 80081c38
```

The busy-wait exits on a counter that an interrupt-driven path increments, and
the submit path *already branches on that counter being non-zero on entry*. That
is the shape of code that renders again when it believes it overran — and our
DMA freezing the CPU for a whole transfer, where hardware runs it concurrently,
looked like exactly the thing that would make it believe that.

> **Run 4 measured this and it does not happen.** `[09bc5c]` reads 1 on every
> frame, faulting frame included, and `800295f4` needs >= 2. The game is hitting
> its frame deadline. Do not re-open this line without new evidence.

**Next run:** the probe records every store to `09BC5C`, `0ADCA4`, `09542C`,
`095428` and `095424`, and the ring is 256 entries (~12 frames), so one `[acc]`
dump shows the full pacing sequence for the faulting frame *and* a dozen clean
ones to diff it against. `09BC5C` is new as of the 14:25 build — the previous
two runs watched a nonexistent `0ABC5C`, so no pacing counter was ever actually
observed and nothing here about overrun has been measured yet.

Do **not** fix this in `dma.zig`'s chain walking, and justify the change against
real hardware rather than against making Tekken boot.

### Caveat on PCs above ~0x8007xxxx

The old `[acc]` trace attributed the per-frame OT reset to `pc = 8007d8e8`, but
that address in `SLUS_004.02` is `sw v1, 0(v0)` with `v1 = 0x11000002` — it
cannot be the store that wrote `000a8540`. `current_pc` is the executing
instruction's own address (delay slots included), so the probe is not lying.
The likely explanation is that **Tekken loads overlays over parts of the boot
EXE's range**, so high addresses may not disassemble to the code that actually
ran. Every address in the `8002xxxx`/`8003xxxx` render path checked out exactly,
so the mapping is trustworthy there and suspect above it.

---

<a id="the-headless-blocker"></a>
## The headless blocker — now on the critical path

`ps1-trace` cannot reach the KO: it wedges much earlier, on the
"STAGE 1 XIAOYU VS JIN" versus screen, at about 300M instructions. Verified this
session by running to 3B instructions — `uploads` sticks at 1198 for the last
270 samples and `frame_2990.ppm` still shows the VS screen.

What it is doing there, measured with `cdrom.debug_enable` (note the
`cd cmds:` histogram in `ps1-trace` is dead instrumentation and always prints
empty — it samples `cdrom.pending_command` after `cpu.step()` returns, by which
time the command has been latched and consumed):

```
... ~10x  INT1 sector, acked normally ...
cmd=0x09 Pause    -> INT3, INT2
cmd=0x09 Pause    -> INT3, INT2
cmd=0x0e Setmode  -> INT3
cmd=0x02 Setloc   -> INT3
cmd=0x06 ReadN    -> INT3, drive Seeking
cmd=0x01 Getstat  -> INT3   (x2)
... ~10x  INT1 sector ...   then round again
```

One full cycle takes ~20M instructions (~35 frames), of which only ~2.3M is
spent delivering the ten sectors — so the game reads a short burst, waits about
30 frames for something that never comes, times out and retries from the same
place. The drive position never leaves LBA 257763–257765 across 2.7B
instructions. Interrupts are delivered and acknowledged correctly throughout,
so this is not an IRQ-plumbing fault.

The obvious next measurement is to log Setloc's MSF parameters: if they advance
while the drive re-reads the same LBA it is our bug, and if they repeat the game
is genuinely retrying. That was not done.

### Taken 2026-08-17 — and it says the game is genuinely retrying

`ps1-trace` now runs **1.5B instructions in 56 seconds** (see `lean` below), so
the wedge reproduces in under a minute instead of not at all. Armed with
`cd_log_from`, the loop is exactly six commands and repeats forever:

```
CDROM cmd=0x09 q=0 drive=Reading pos=57:18:65 params=          Pause
CDROM cmd=0x0e q=0 drive=Idle    pos=57:18:65 params=a0        Setmode
CDROM cmd=0x02 q=0 drive=Idle    pos=57:18:65 params=57 18 63  Setloc
CDROM cmd=0x06 q=0 drive=Idle    pos=57:18:65 params=          ReadN
CDROM cmd=0x01 q=0 drive=Seeking pos=57:18:65 params=          Getstat
CDROM cmd=0x01 q=0 drive=Reading pos=57:18:63 params=          Getstat
```

**Setloc's parameters are byte-identical on every cycle: `57 18 63`.** They
never advance, so this is not our drive re-reading a stale LBA — *the game is
deliberately re-requesting the same position*. That closes the question above.

Corrections to the description above, from the same run:
- It is **~2 sectors per cycle, not ~10** (`57:18:63` -> `57:18:65`).
- Only **one** Pause per cycle, not two.
- The cycle is ~2.5M instructions, not ~20M.

Everything on our side of the read checks out:
- The disc image is sound. The ISO parses (`PVD` at LBA 16), and LBA 257763 is
  inside **`/TEKKEN3/TEKKEN3.BNS;1`** (LBA 250156..268783, 38 MB) — a valid
  region of a real file, not past any end.
- The sectors themselves are well-formed Mode 2 Form 1: `hdr=57186302 mode=2`,
  `subheader=00 00 08 00 00 00 08 00` (submode `0x08` = Data), real payload.
- The drive delivers them: `cd pos: lba=257763 sec_nz=821/2352`, `q=1`,
  `irq stat=00c0`, drive cycling Seeking -> Reading normally.
- `Setmode a0` = double speed + **bit5 (2340-byte whole sector)**, no XA bit, so
  the XA-vs-data submode logic is not involved.
- `ps1-trace`'s `loadCue` and `ps1-wasm/www/index.html` assemble the image with
  identical logic (concat in cue order, synthesize `REM FILESIZE`), so the two
  frontends genuinely see the same disc.

So the remaining question is **why the game rejects data it is being handed
correctly**. The browser reaches the fight, so whatever differs is upstream of
the CD — the most obvious candidate being `autostart`'s synthetic input landing
the game in a different state than a human's menu navigation.

### Corrected: the "emulator hangs at 260M" is not real

Several hours went into an apparent hard hang at instruction 260,000,000 where
`sample` showed 100% of time in `CdRom.step` -> `memcpy`. **That was the CD
command log itself.** An `lldb` backtrace on the wedged process showed
`commands.zig:7 -> std.log.warn -> Io.Writer.print -> writeAll -> memcpy`: the
`std.log` path both hung and dropped its output. The per-command line now uses
`std.debug.print` instead, guarded at comptime because `std.debug.print` pulls
in the POSIX I/O stack and will not compile for `wasm32-freestanding`. There was
never an emulator hang there. `lldb -p <pid> --batch -o bt` settles this class
of question in seconds and should be reached for earlier.

---

## Committed this session

- `bd111f8 feat(trace): load multi-FILE cues and print MSF positions as BCD` —
  `loadCue` reads every `FILE` a cue references, concatenates them in cue order
  and synthesizes `REM FILESIZE` ahead of each, mirroring what
  `ps1-wasm/www/index.html` does with an uploaded folder, so both frontends see
  a byte-identical disc. Tekken 3 (3 FILEs) could not be loaded at all before.
  Plus the BCD MSF formatter fix.

## Cleanup owed when the bug closes

Revert the `store_watch` hook in `ps1-core/src/memory.zig` and all probe code in
`ps1-wasm/src/main.zig`. `ps1-trace/src/main.zig` still carries an uncommitted
`stall_threshold` DMA-wedge detector and a temporary timer-register dump in
`snapshot()` — decide whether the wedge detector is worth keeping as a permanent
tool; the timer dump is not.

`ps1-trace/src/main.zig` also now carries the `fn_watch` probe added while
closing the headless blocker: a PC table armed by `PS1_FNWATCH=<instr>` that
prints `a0/a1/v1/s0/s1/ra` on entry to each watched address, plus `[sec]`,
`[latch]` and `[q]` lines for sector arrival, data-FIFO latch and `irq_queue`
changes. It cost three runs to go from "stuck in a CD retry loop" to the exact
faulting compare, so it is the one piece of this session's scaffolding worth
considering as a permanent tool.

`tools-debug/` is throwaway and should go with the probes. It now also holds
`ramdis.py` (disassembles out of a `PS1_RAM_DUMP=1` `ram.bin` rather than a
PS-EXE, which is how to read code in the address range where the overlay
caveat makes `SLUS_004.02` untrustworthy). It holds
`SLUS_004.02` (the extracted Tekken 3 boot EXE, `t_addr=0x80010000`,
`t_size=0x121000`, `pc0=0x80079c70`), `mipsdis.py` (a full R3000A/MIPS I
disassembler for PS-EXE images — `python3 tools-debug/mipsdis.py
tools-debug/SLUS_004.02 <pc> <count>`) and `ppm2png.py` (converts `ps1-trace`
frame dumps).

Per `CLAUDE.md`, commit one logical task at a time directly on `master`.
