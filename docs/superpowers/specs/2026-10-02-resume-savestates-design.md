# Resume savestates — design

## Goal

Leaving a running game offers to save its state, and opening that game again
offers to resume it. One resume slot per GAME (numbered slots may come later
and are out of scope). States must **survive app updates**: the format is
versioned and written field by field, never a raw memory image.

## Success criteria

1. A state saved and loaded into a fresh core runs on to the SAME `state_hash`
   in every region as the core that never saved (BIOS boot, `zig build test`).
2. A new `trace-golden -- savestate` passes on every workload: save at frame K,
   restore into a fresh core, and the trace from K on equals the committed
   golden. No new golden is captured.
3. A committed v1 state fixture loads in every later build.
4. A corrupt, truncated, future-version, wrong-BIOS or wrong-disc state is
   refused with a specific error, and the running machine is untouched.
5. `verify`, `stream-verify`, `zig build test`, `test-roms-ja` (12/17) and the
   Swift suite are unchanged.
6. By hand: quit Crash mid-level, relaunch, Resume — it continues from that
   spot with audio. Quit FF7 on disc 2; the FF7 tile offers to resume on disc 2.

## Non-goals

- Numbered save slots, hotkey save/load, rewind.
- Saving the memory cards. They are ONE pair shared by the whole library;
  restoring them from a state would roll back saves made in other games.
- Saving user settings (PGXP flags, speed, dither, internal resolution). They
  belong to the app; it re-applies its current ones after a load, as it already
  does every frame.
- Loading a state into the browser build or `ps1-debug`. The core API is
  frontend-neutral, but only `ps1-capi` and `ps1-golden` call it.

## Core: the format (`ps1-core/src/savestate/`)

### Container

```
header:  magic "SBST" | format_version u32 | crc32 u32 | body_len u32
         | bios_sha256 [32]u8 | disc serial (16 bytes, zero-padded)
body:    section*
section: tag u32 | section_version u32 | len u32 | payload[len]
```

`savestate/savestate.zig` owns the header, the CRC32 over the body, and the
section framing: one table of `{ tag, version, save, load }` entries, in the
order `BUS `, `CPU `, `IRQ `, `TMR `, `DMA `, `GPU `, `SPU `, `CDR `, `MDEC`,
`SIO `. `savestate/stream.zig` holds the `Writer`/`Reader` pair.

The device serializers live in that directory, NOT beside each device's
fields: `cdrom.zig`, `dma.zig`, `gp0.zig` and `memory.zig` are already over the
~600-line rule. `io_state.zig` carries the `Bus` byte regions (RAM,
scratchpad, `io_ports`, `expansion_2`, `expansion_3` and its last-write width,
`cache_control`, `wait_cycles`, `sys_clock`) and the interrupt controller,
timers, DMA, MDEC and SIO; `cpu_state.zig`, `gpu_state.zig`, `spu_state.zig`
and `cdrom_state.zig` carry the rest. Every section is one hand-written pair
over the whole machine, written per field exactly like
`ps1-golden/src/state_hash.zig`:

```zig
pub fn saveX(cpu: *const Cpu, w: *Writer) Error!void
pub fn loadX(cpu: *Cpu, r: *Reader, version: u32) Error!void
```

for `Cpu` (with its I-cache and load-delay slot), `Cop0`, `Cop2`,
`InterruptController`, each `Timer`, `Dma`, `Gpu` (VRAM, registers, drawing
environment, the GP0 FIFO and any half-assembled command), `Spu` (all voices,
ADSR, reverb, noise, SPU RAM, capture buffers), `CdRom` (drive state, every
FIFO, every timer the deferred-tick deadline reads, the XA decoder's history),
`Mdec` (FIFOs, tables, in-progress block) and `Sio` (pad and card PROTOCOL
state, not the card images).

**Hand-written, never reflected**, for the reason `state_hash.zig` gives: a
field renamed or absorbed in a refactor must become a compile error or a test
failure, not a silent change of format.

### Versioning

- `format_version` covers the container only.
- Each section carries its own `section_version`. When a device's state
  changes, its version is bumped and its section's `load` keeps reading the old
  layout, supplying the new field's power-on value. That is what makes states
  survive updates.
- A section version newer than the build knows is `error.StateVersion`. An
  unknown section tag is the same: a state from a newer build is refused,
  never half-read.

### What is NOT in a state

| Not saved | Why | After a load |
| --- | --- | --- |
| BIOS image | the user's file | header `bios_sha256` must match the loaded BIOS |
| Disc bytes | reloaded from the library | header serial must match the loaded disc; drive/head state is in `CdRom`'s section |
| Memory cards | shared across games | the app's cards stay as they are |
| PGXP shadow tables, vertex cache | ~10 MB of pure cache | empty; the identity check treats a missing value as "no PGXP", so geometry is integer for a frame or two |
| GP0 recorder, true-colour sidecar | per-frame, display-only | the app calls `requestResync`, which re-uploads core VRAM to Metal |
| `pgxp_*` and other setting fields on `Bus` | the app's settings | the app re-applies them |

After a resume in the app, the memory cards read as freshly inserted. The app
installs the cards after `ps1_load_state` (as it does for every boot), and
`setMemoryCardData` sets the "fresh" flag. That is the safe answer: the cards
are shared across games and may have changed since the save, so the game must
re-read the directory. The core's own round trip restores the flag exactly.

### Deferred ticks

Deferred-tick bookkeeping is SAVED, not caught up.
`gpu.cycle_debt`/`pending_cycles`/`event_countdown`, each timer's
`pending_ticks`/`event_countdown`, and the CD-ROM's
`pending_cycles`/`event_countdown` are written like any other field. A save
then needs no settle, which is what lets `trace-golden -- savestate` restore
at an arbitrary instruction and still match the golden bit for bit.

### Loading is all-or-nothing

`load` decodes into a SCRATCH `Bus` and `Cpu`, re-attaches the running
machine's disc slice, `.sbi`, BIOS bytes, settings and vertex-cache pointer,
and swaps it in only once every section has parsed. A failure at any point
leaves the running machine exactly as it was (criterion 4).

### Size

About 2 MB RAM + 1 MB VRAM + 512 KB SPU RAM + registers, several MB raw. The
core's format is uncompressed and CRC32-checked; the app compresses it with
LZFSE (`NSData.compressed(using: .lzfse)`). A save is a few milliseconds at a frame
boundary.

## The C ABI (`ps1-capi`, hand-written in `ps1.h`)

```c
size_t  ps1_save_state_bound(const Ps1*);   /* upper bound for dst */
int32_t ps1_save_state(Ps1*, uint8_t* dst, size_t cap, size_t* out_len);
int32_t ps1_load_state(Ps1*, const uint8_t* src, size_t len);

/* Reads the header only, without a running core, for the launch prompt. */
int32_t ps1_peek_state(const uint8_t* src, size_t len, Ps1StateInfo* out);
/* Ps1StateInfo { char serial[16]; uint8_t bios_sha256[32]; } */

/* New codes */
PS1_ERR_STATE_BAD_MAGIC, PS1_ERR_STATE_VERSION, PS1_ERR_STATE_BIOS,
PS1_ERR_STATE_DISC, PS1_ERR_STATE_CORRUPT
```

The caller loads the BIOS and the disc first (the normal `ps1_load_disc`
path), then calls `ps1_load_state`.

## The app

### Runner (`EmulatorRunner`)

`requestSaveState(completion:)` and `requestLoadState(_:completion:)` put a
pending request in a slot under `pacing`, exactly as `requestDiscSwap` does.
`runLoop` services it at the TOP of the loop, above the paused and ring-full
early-outs, like the memory cards. That placement is load-bearing: the game is
paused while the exit sheet is up, and a save parked behind the pause would
never run. The completion is delivered on the main actor.

### Thumbnail (`ResumeThumbnail`)

Taken on the emulator thread in the same service call as the state, so it
shows exactly the saved frame. `ResumeThumbnail.make(vram:display:)` is a pure
function over `ps1_copy_vram` and `ps1_get_display`: crop the display area,
decode 15 bpp or 24 bpp (packed across 16-bit words), expand with
`c << 3 | c >> 2`, scale to 320 px wide through `CGContext`, encode PNG. It
never reads the Metal drawable, which may be upscaled, a different frame, or
under the HUD.

### Storage (`ResumeStateStore`)

`Application Support/Substation/ResumeStates/<key>.state` and `<key>.png`,
resolved through `AppSupport` like the other stores. `<key>` is the GAME:
the serial of the first disc in its `DiscGrouping` group, falling back to the
path hash exactly as `CoverStore` does. The header's serial says which
disc was in the tray. Writes go to a temporary file and are renamed into place,
so a crash mid-write never leaves a torn state to be offered.

### Exit sheet (`ConfirmExitSheet`)

"Confirm Exit" / "Are you sure you want to exit?" / ☑ Save State For Resume /
**No** · **Yes**. The emulator is paused while it shows. The checkbox persists
as `ResumeOnExitSetting` (default ON; absence probed with `object(forKey:)`).

It gates every way of leaving a RUNNING game:

- ⌘Q: `applicationShouldTerminate` returns `.terminateLater` and replies once
  the save has completed; the existing `willTerminate` card flush still runs
  after it.
- Closing the window: `windowShouldClose`.
- Eject, and File ▸ Open Disc… while playing: the same view-model gate.

With no game running, none of these show the sheet. Yes with the box ticked
saves, then leaves; Yes unticked leaves without touching an existing state;
No resumes play.

### Launch sheet (`ResumePromptSheet`)

Opening a game whose key has a state shows: the thumbnail, "Saved <date>",
and **Resume** (default, ⏎) · **Fresh Boot** · **Delete & Boot** ·
**Cancel** (⎋).

- Resume: `load(disc:)` the disc named by the header's serial, then
  `requestLoadState`. A refusal shows an alert naming the reason (corrupt,
  different BIOS, made by a newer version) and offers Fresh Boot; it never
  boots silently.
- Fresh Boot: boots normally; the state is kept.
- Delete & Boot: removes `<key>.state` and `<key>.png`, then boots.
- Cancel: back to the library.

Resume does NOT delete the state: a crash mid-session would otherwise lose it.
Only the next save-on-exit replaces it.

The sheet's choice logic lives in a value type (`ResumePromptState`), as
`VolumeControlState` does, so it is testable without a window.

## Testing

**Core** (`ps1-core/tests/savestate_test.zig`, the 12th unit file in
`zig build test`):

1. Round trip: BIOS boot N frames → save → load into a fresh core → run both M
   frames → `state_hash` equal in every region.
2. Hostile input: bad magic, future format version, future section version,
   unknown tag, truncation at every section boundary, wrong BIOS, wrong
   serial — each returns its code and leaves the running core's hash
   unchanged.
3. Backward compatibility: `ps1-core/tests/goldens/savestate/v1-bios.state`,
   committed, must load and run to its recorded hash in every later build.

**Harness**: `trace-golden -- savestate` (run `-Doptimize=ReleaseFast`): for
every workload, save at a mid-run frame K, restore into a fresh core, verify
against the existing golden from K on. This is the gate that reaches in-flight
state a BIOS boot never exercises: a CD seek, a DMA chain, a half-built GP0
command, an SPU voice mid-release, an MDEC block.

**Swift**: `ResumeThumbnail` (15 and 24 bpp synthetic VRAM),
`ResumeStateStore` (group keying, atomic write, missing PNG), the
`ResumeOnExitSetting` default, and `ResumePromptState`.

## Risks

- **A field forgotten in a section's `save` that is still at its power-on value at
  the save point** passes test 1. The `savestate` harness mode, saving
  mid-game on every workload, is the mitigation; it is why that mode exists.
- **Every future core change now carries a format obligation.** A new device
  field means a section version bump and a defaulting branch in that section's `load`.
  This goes into `CLAUDE.md`'s rules and the `ps1-core-subsystems` skill once
  it ships.
