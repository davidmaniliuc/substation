---
name: ps1-debugging-real-games
description: Use when a real game hangs, freezes, renders wrong, or boots to a black screen, and when choosing a reference to diff against. Covers the ps1-trace workflow and its autostart/walk/explore modes, event-anchored PC diffing against Avocado, dead instrumentation to distrust, and the reference material to consult in order.
---

# Debugging real games

## Reference material (use in this order when stuck)

1. **`avocado_ref/src/`** — the C++ Avocado emulator, checked out locally. This is
   the *authoritative implementation reference*; most of this Zig port is a
   translation of it. GTE math lives in `avocado_ref/src/cpu/gte/`, CDROM in
   `avocado_ref/src/device/cdrom/{cdrom.cpp,commands.cpp,cdrom.h,fifo.h}`.
2. **NoCash PSX-SPX** (<https://psx-spx.consoledev.net>) — hardware bible.
3. **Lionel Flandrin's psx-guide** — system-level interactions/timing.
4. **JaCzekanski/ps1-tests** — the source of `test-roms/`; each test has a golden
   `psx.log` captured on real hardware.

When porting/fixing, **diff against `avocado_ref` first** — many "quirks" in this
codebase are deliberate matches to (or unintended divergences from) Avocado.

### Debugging real games

The workflow that actually found the recent bugs:

1. Run headless with `ps1-trace <bios.bin> <disc.bin> <max_instr> <snapdir> [autostart|walk|explore]`.
   `autostart` cycles Start/Cross/Circle with real button codes so intros, FMVs
   and title menus get walked past and a run reaches gameplay. `walk` adds a
   held Up for scenes gated on the player moving. **`explore` is the one that
   actually covers ground**: past 600M instructions it stops pressing Start
   (in-game that opens the inventory, and a run that pauses every few frames
   goes nowhere) and steers on a fixed LCG, mixing turns into the held Up so it
   does not simply walk into the first wall and stay there. It is deterministic,
   so a scene it reaches can be re-reached and A/B'd. It is still a blind
   walker: it reached Silent Hill's opening street and the Cheryl cutscene but
   never the alley beyond it.
2. Anchor on an event (a syscall, a GP0 command, a CD command), then do an
   **event-anchored PC diff** against Avocado's headless tracer to find the exact
   diverging instruction. Do *not* diff on cycle counts: Avocado bills 1 cycle per
   instruction and is waitstate-blind, so its clock and ours legitimately differ
   by ~3x. Diffing that number produces phantom "timing bugs".
3. For GTE specifically there's a replay harness: capture real GTE calls from a
   run, replay them through Avocado, diff per-opcode.

**`ps1-trace`'s `cd cmds:` histogram is dead instrumentation — it always prints
empty.** It samples `cdrom.pending_command` *after* `cpu.step()` returns, but a
command is latched and consumed inside that same step, so the counter never
sees one. Any past conclusion of the form "the game issues zero CD commands
while hung" that rests on it is unsupported — **including the one recorded for
Crash's level-select freeze.** To get a real command log, set
`cdrom.debug_enable = true` on the frontend and read the `CDROM cmd=` lines.

**A game sitting on a static screen is not necessarily hung.** Rayman's Ubi Soft
logo looked like a freeze and was one, but the piracy-notice and language-select
screens before it are *timed or input-gated* and take hundreds of millions of
instructions to pass. Before debugging, run long (1.5B) with `autostart`, and
diff consecutive `frame_*.ppm` snapshots: if the framebuffer stops changing
permanently, it's a hang; if it keeps animating, you are just early.

**Black screen + working audio** almost always means the CPU is parked in the
BIOS unresolved-exception hang, not a GPU bug — check PC before touching `gpu/`.
