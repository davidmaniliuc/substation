# CLOSED — Tekken 3 (USA) freezes after the first KO

**Root cause: our DMA model, not Tekken's game state.** A GPU display list that
closes into a ring is something Tekken 3 builds by design after a KO, and
hardware shrugs it off. We turn it into a permanent freeze because
`Cpu.step()` consults `bus.dma.isCpuStalled(bus)` first, so an active channel
that never reaches its terminator starves the CPU forever while the peripherals
keep ticking — a still picture with live audio, the reported symptom exactly.

**Fixed 2026-08-18** in `ps1-core/src/dma.zig`: a linked-list transfer that walks
more nodes than any real chain can hold (`DmaConst.ll_node_limit`, 65,536) is
abandoned. Pinned by *"a linked list that closes into a ring is abandoned, not
walked forever"* in `dma_test.zig`.

> **This is a livelock guard, not hardware behaviour, and the comment in
> `dma.zig` says so.** Hardware keeps the CPU running during DMA (the controller
> steals bus cycles, it does not halt the processor), so the next frame's
> `DrawOTag` writes CHCR and restarts the channel on a fresh list; the ring costs
> a dropped frame there. Avocado needs the same guard for the same reason —
> `dma_channel.cpp` prints *"[DMA2] GPU DMA transfer loop detected, breaking."*
> The faithful fix is CPU/DMA interleaving, which is a much larger change (it
> moves CPU/DMA interleaving in every game and needs a rate nobody has measured)
> and is **not** what landed here.

---

## Why the previous five sessions did not find it

Every earlier run asked *"which upstream game state is wrong such that the game
emits one object twice?"* — because a self-linking display list looks like
corruption. The static decode below is correct and was confirmed
instruction-for-instruction, but the question was wrong: **nothing is wrong
upstream.** The game really does emit fighter A twice on the frame its
round-phase machine leaves state 4, on every emulator, and the list really does
ring. Only the consequences differ.

Two measurements settle it, and either one alone would have:

**1. Break the ring and the game is perfectly healthy.** With a node cap in our
linked-list walk and nothing else changed, the ring still forms at the *identical
instruction* (`i=2269099828`, `f=7717`, `[dup] closes [0c8be8] = 040c9738`), and
the game then carries on: the KO result screen renders correctly 10M
instructions later (`XIAOYU WINS!`, right WINNER/LOSER labels, health bars), and
920M instructions later it is playing **round 2** (`WIN: 1`, both fighters
animating). Corrupt upstream state does not produce a game that announces the
right winner and starts the next round.

**2. Avocado does exactly the same thing.** Driven to a KO with a synthetic pad
schedule, the reference emulator hits the same round-phase transition and closes
the same ring **on every KO it reaches** — 6 KO cameras, 6 rings, 6 loop-guard
hits, no exceptions:

```
T3C3SET                                       8002b98c narrows obj->0xC3 to one fighter
T3PHASE pc=8003d214 v0=00000005               phase 4 -> 5
T3PHASE pc=8003d268 v0=00000006               phase 5 -> 6
T3EMIT [0c8be8] = 040c9738  *** RING ***      byte-identical to our [dup]
[DMA2] GPU DMA transfer loop detected, breaking.
```

Same store, same address, same value as ours. It survives purely on its loop
guard.

A third fact closes the escape hatch the old investigation kept looking for:
**`0x800ADCA4`, the per-object emit gate, has exactly one setter in the whole
executable** — `800508f8`, inside the frame-overrun re-render loop at
`0x800508c4`, which cannot run between the two emits of a single render pass.
Every other store to it writes `$0`. The game therefore has no in-frame
mechanism that could suppress the duplicate, i.e. this list rings by
construction.

---

## The repro (85 seconds, headless, deterministic)

This is the durable win from the session — the old investigation needed browser
runs and a seeded input fuzzer.

```
zig build -Doptimize=ReleaseFast
./zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin \
    "games/Tekken 3 (USA)/Tekken 3 (USA).cue" 2400000000 <snapdir> autostart lean
```

Plain `autostart` reaches the first KO; before the fix it wedged at instruction
2,273,484,224 and `ps1-trace`'s stall detector named the ring outright:

```
[stall] instr=2273484224 pc=8007e260 stalled=true
[stall] ch2 sync=2 madr=000c9540 bcr=00000000 chcr=01000401 words=ffffffff next=0c9540
[stall] CYCLE at 0c9540 loop_len=128 after 127 nodes
```

`frame_2260.ppm` is the fight, `frame_2270.ppm` is the frozen stage with no
fighters and no HUD. **Keep the `[stall]` detector** — it is the canary for this
whole class of bug and it cost nothing.

The `[acc]`/`[dup]` store-ring probe used above was ported into `ps1-trace` from
`ps1-wasm/src/main.zig` for this session and reverted afterwards; the wasm copy
is still in the tree, so nothing is lost. The Avocado side needed two temporary
hooks in the (gitignored) `avocado_ref` checkout: `AVO_T3=1` for the
`T3EMIT`/`T3PHASE`/`T3KOCAM`/`T3C3SET` probe in `src/cpu/cpu.cpp`, and
`AVO_AUTOSTART=1` for a synthetic pad schedule (`g_headlessInput` in
`digital_controller.cpp`, driven from `platform/headless/main.cpp`) — the
headless build has no InputManager, so without it a pad can never be pressed and
Avocado never leaves its menus.

---

## The mechanism (still accurate — keep this)

The display list is a set of **pre-linked chains**; per frame only each chain's
tail tag is rewritten. A tail may therefore only ever link *downward*; the one
store that links upward is the ring.

```
8003a818  per-object render entry
    8003a994  lw [0x800ADCA4];  8003a99c bne -> skip the emit
 └ 8003b4f8  emit
    8003b518  lw  acc, 0xFBC(db)        db = *(*(0x800A8C54) + 4)
    8003b558  lw  sel, [0x800ADEFC]
     └ 80037b28  a1 = objChainTable[sel]
        80037b58  sw (acc | 0x04000000), 0(a1)  *** the store that rings ***
    8003b594  sw head, 0xFBC(db)        the OT slots 0a7544 (sel=0) / 0a8544 (sel=1)
```

`0x8003cb84` is a ten-state round-phase machine on `[0x80096F2C]` (jump table
`0x8001A354`). **State 4 is a one-shot**: gated on `[0x800ADE78] & 1 == 0` (the
*time-out* flag, correctly clear on a health KO), it emits both fighters at
`8003d1c0`/`8003d1c8`, then ends `[0x80096F2C] += 1` and falls through into
state 5's body. Eight instructions later `8003ea5c` runs the KO camera, and
`8002b98c` clears all three `obj->0xC3` render gates and sets exactly one. The
ordinary per-frame dispatcher `8002ba64` then emits *that* fighter — the second
time it has been emitted this frame — and its tail tag links back to its own
chain's head. The resulting list is
`[0a8544] -> A.head -> … -> A.tail -> B.head -> … -> B.tail -> A.head`: the
observed 128-node ring.

One faulting frame, from the headless probe (normal frames carry only the two
`site=8002bac0`/`8002bad8` emits):

```
f=7717 [0c8be8] = 040a7540  site=8003d1c8   state-4 dispatcher emits A
f=7717 [0c91a0] = 040c9180  site=8003d1d0   state-4 dispatcher emits B
f=7717 [09546c] = 3                         KO camera mode
f=7717 C3 = [1 0 0]                         narrowed to fighter A
f=7717 [096f2c] = 5 then 6                  the one-shot phase increment
f=7717 [0c8be8] = 040c9738  site=8002bac0   dispatcher 2 emits A again -> RING
```

---

## Retired — do not re-open

Everything the old handoff listed as "proven" about the render path is still
true and no longer interesting, because the render path was never the bug: the
`[0x800ADE78]` time-out gate, `obj->0xC3`, `[0x800954A4]`'s delay-slot write,
`[0x800ADFD0]`/`wb`, `[0x800ADCA4]`, `sel` alternation, the frame-overrun and
re-render theories, stale lists, skipped flips, Timer 2, and every terminator
theory. **The documented "next step" — an Avocado execution differential
anchored on the faulting frame — was run, and its answer was that Avocado
behaves identically.** There is nothing upstream to find.

Two side-findings worth keeping:

- `PS1_RAM_DUMP=1 ./zig-out/bin/ps1-trace … <snapdir> autostart lean` writes a
  full 2 MB `ram.bin`; diffing it against `SLUS_004.02` proved no overlay covers
  the `8002xxxx`/`8003xxxx` render path, so that disassembly is trustworthy.
  Addresses above ~`0x8007xxxx` may still be overlaid.
- Latent, still unfixed: `timer.zig` treats only `0x0200` as sysclk/8, but
  Timer 2 clock source **3** is sysclk/8 too.

## Cleanup owed

The wasm-side scaffolding this investigation added is still in the tree and is
now dead weight: the `[acc]`/`[dup]`/shadow-map probe in `ps1-wasm/src/main.zig`
(~430 lines, `probes_enabled = true`, so the **shipped browser build pays for a
per-instruction PC ring and a DMA attribution scan**), the `store_watch` hook in
`ps1-core/src/memory.zig` it needs, and `tools-debug/`. Reverting them is the
obvious follow-up.
