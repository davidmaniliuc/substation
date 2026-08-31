# Memory card persistence — and the port-select bit — design

**Date:** 2026-08-31
**Status:** approved; one implementation plan
**Closes:** the "Multi-disc saves still do not persist" gap recorded in
CLAUDE.md § CDROM — state of play, and the "nothing persists it — no frontend
saves or restores the card" note in § Memory / interrupts / timers / SIO.

## Goal

Quit the app and still have your save.

`ps1-core/src/sio.zig` has emulated a 128 KB Sony memory card since June: the
read (`0x81`/`R`) and write (`0x81`/`W`) command sequences, the block address,
the running checksum, and a `memcard_dirty` flag raised when a written block's
checksum verifies. `getMemoryCardData`, `isMemoryCardDirty` and
`clearMemoryCardDirty` are all exported. **No frontend has ever called any of
them.** The image lives in `Bus`, and it dies with the process.

This spec adds the file storage and the ABI to reach it, and fixes the
fidelity bug that persistence would otherwise make destructive: the SIO port
select line is not decoded, so both slots are answered by the same card.

Save states are a separate feature and are not designed here.

## Scope

In:

- JOY_CTRL bit 13 (port select) decoded in `ps1-core/src/sio.zig`; the card
  state made per-slot; the pad answered on port 0 only.
- `ps1_load_memcard` / `ps1_take_memcard` in `ps1-capi`, and card retention
  across `ps1_reset`.
- `MemoryCardStore` and `MemoryCardFlushPolicy` in `ps1-macos`, wired into
  `EmulatorRunner`'s loop and `EmulatorViewModel`'s machine lifecycle.
- A `ps1-golden` recapture, as its own commit, for the behaviour change.

Out — permanently, or elsewhere:

- **Save states.** Explicitly deferred by the user in the same breath as
  asking for this. A save state is the whole machine, needs a versioned
  format, and has none of this feature's decisions in common with it.
- **Per-game cards.** One shared card, like a console with one card in it.
  See § 3.
- **An insert/remove UI.** Both slots always hold a card. There is no
  "no card in slot 2" state to reach, so there is no setting and no menu.
- **A formatted blank card.** A card file that does not exist is a card of
  zeros, which the BIOS reports as unformatted and offers to format. That is
  what a new card does on hardware, and it means no synthesized directory
  frame to keep correct.
- **Persistence in `ps1-wasm`, `ps1-debug`, `ps1-trace`.** The core change
  reaches all three — port 2 stops aliasing port 1 for them too — but none of
  them gains a file. The browser has no home for one that survives a cache
  clear, and the two native harnesses are headless test rigs.
- **Controller port 2.** The port-select decode is the prerequisite for a
  second pad, and this spec deliberately stops at making port 1 report
  *nothing*. Two-player input is its own feature.
- **Slot-2 capacity UI.** Nothing tells the player how full a card is; the
  BIOS card manager already does.

## Decisions taken

### 1. The port select is latched at the start of a packet, not read per byte

`Sio` gains `port: u1 = 0`, assigned from `(self.ctrl >> 13) & 1` on the
`.Idle -> .AwaitingCmd` transition — the byte that opens a packet.

It must not be re-read per byte. The select line is stable for a whole packet
on hardware (software sets JOY_CTRL, clocks the bytes, then deselects), so
sampling it once is faithful; sampling it per byte would let a JOY_CTRL write
in the middle of a transfer reroute the remaining bytes of that transfer to
the other slot, splicing one card's block into the other's.

`ctrl_state` stays a single state machine rather than becoming per-port,
because the deselect that ends a packet already resets it and hardware has one
shift register — only the *device* on the far end differs.

### 2. Card state becomes per-slot; the pad answers on port 0 only

`memcard_data` becomes `[2][131072]u8`, and `memcard_address`,
`memcard_checksum`, `memcard_step`, `memcard_is_write` and `memcard_dirty`
become 2-element arrays indexed by `port`. `getMemoryCardData(slot)`,
`isMemoryCardDirty(slot)`, `clearMemoryCardDirty(slot)` and a new
`setMemoryCardData(slot, bytes)` take the slot; nothing outside `sio.zig`
calls them today, so there is no caller to migrate.

Command `0x42` (Read Controller) is answered **only when `port == 0`**. On
port 1 it falls through to `.Idle`, which is the existing "nothing responded"
path: `ack` stays false, no IRQ7 is armed, and the BIOS pad routine times out
after its ~81 polls and reports no controller — exactly what a console with an
empty port 2 does. Command `0x81` is answered on both ports.

This is the half that is a bug fix rather than a feature. Without it, adding
persistence makes the aliasing destructive rather than merely unused: the BIOS
Memory Card manager shows the same card in both panes, and its **copy**
function — the flow players use to move a save off a full card — copies a card
onto itself. `Bus` grows 128 KB, against the 768 KB `Mdec` already holds by
value.

### 3. One shared card, not one per game

`card1.mcd` and `card2.mcd`, used by every game, like a real console.

Multi-disc games then work with no special case at all: Final Fantasy IX's
disc 2 finds disc 1's save because it is the same card, which is also true on
hardware. Cross-title reads — a sequel finding its predecessor's save file and
unlocking something — keep working for the same reason. The cost is that 15
blocks is a hard cap and the player manages it through the BIOS card manager,
which is the hardware experience and the reason slot 2 exists.

DuckStation defaults to per-game cards instead. That choice buys unlimited
capacity and loses both behaviours above; it also needs a rule for what a disc
swap does to the file, and a decision about what "the game" means for a rip
whose title differs across discs.

### 4. The ABI is a drain, and the bytes are copied in

```c
#define PS1_MEMCARD_BYTES 131072
#define PS1_MEMCARD_SLOTS 2

int32_t ps1_load_memcard(Ps1*, int32_t slot, const uint8_t* bytes, size_t len);
int32_t ps1_take_memcard(Ps1*, int32_t slot, uint8_t* dst);
```

`ps1_load_memcard` COPIES, like the `.sbi` sidecar and unlike the disc `.bin`.
128 KB is small enough that a second lifetime obligation on the caller buys
nothing, and a copy is what lets `Handle` reinstall the image after a reset.
It returns `PS1_ERR_BAD_MEMCARD_SIZE` for any `len` but exactly
`PS1_MEMCARD_BYTES`, and `PS1_ERR_BAD_SLOT` for a slot outside
`0..PS1_MEMCARD_SLOTS-1`. Two new negative codes, appended.

`ps1_take_memcard` returns `1` when the card was dirty — copying
`PS1_MEMCARD_BYTES` into `dst` and clearing the flag — and `0` when it was
clean, touching `dst` not at all. It is a DRAIN, in the same sense as
`ps1_take_frame_stream`, and it is one call rather than a `dirty` query
followed by a `copy` so that there is no window in which a block committed
between the two is reported and then dropped. The 128 KB copy is paid only on
a frame where a game actually committed a block, which is rare — a full save
is a burst of ten or so, once, when the player asks for it.

`Handle` gains `memcard: [2][PS1_MEMCARD_BYTES]u8` and
`memcard_loaded: [2]bool`, and `buildMachine` reinstalls each loaded image
exactly as it already re-copies `bios`. Without that, **`ps1_reset` erases the
card**: `Bus.init` memsets the struct. That is a live bug today with no
symptom, because there is nothing to erase.

`ps1_load_memcard` writes through to `bus.sio` immediately as well as into the
handle, again mirroring `ps1_load_bios`.

### 5. The app writes on a debounce, and the rule is a value type

`MemoryCardStore`, shaped after `CoverStore`:
`~/Library/Application Support/PS1/MemoryCards/card{1,2}.mcd`, raw 131072-byte
images — the `.mcd` layout DuckStation and the PCSX line read, so a save can
be carried in or out. `load(slot:)` returns `nil` for a missing file and for a
file of the wrong size; a short file is refused rather than zero-padded,
because a truncated card is more likely a botched copy than a card to be
salvaged, and the refusal is visible as "unformatted" instead of as corrupt
save data. `write` is atomic (`.atomic`), and **every disk access goes through
one private serial queue**, so a debounced write cannot overlap the read the
next game performs.

`MemoryCardFlushPolicy` is a value type holding the debounce: it is told
`(dirty: Bool, now: TimeInterval)` and answers whether to write now. One
second after the last dirty frame, plus an unconditional flush on eject and
quit. Being a value makes the rule reachable from a test with synthetic
timestamps, for the same reason `FpsCounter` and `InternalResolution` are
values.

`EmulatorRunner` takes the store, and calls `ps1_take_memcard` for both slots
once per frame. The policy is evaluated **at the top of `runLoop`, before the
paused and ring-full `continue`s** — a player who saves and immediately hits
⌘P would otherwise leave a pending write parked until they resume. `stop()`
performs the final flush **after joining the emulator thread**, so nothing
touches the core concurrently with the write.

### 6. Cards are installed after the outgoing machine is torn down

`EmulatorViewModel.load(disc:)` builds the whole new machine before calling
`teardownRunningMachine()`, so that a disc that fails to load leaves the
current game untouched. The card must not follow that order: reading
`card1.mcd` before the outgoing runner has flushed reads stale bytes, and the
new machine would then flush them back over the save the old one was about to
write.

So the card load happens **after** `teardownRunningMachine()` and before
`runner.start()`, and a failure there is non-fatal — a missing or unreadable
card file is a blank card, which is a state the machine already handles.

Quit is covered by an observer on `NSApplication.willTerminateNotification`
registered by `EmulatorViewModel`, rather than an
`NSApplicationDelegateAdaptor`: the flush is model state, and nothing else in
the app needs a delegate.

## Testing

- `ps1-core/tests/sio_test.zig`: a card write through port 1 leaves slot 0's
  image untouched (the aliasing regression); `0x42` on port 1 leaves
  `ctrl_state` `.Idle` and arms no IRQ; the port latched at packet start
  survives a mid-packet JOY_CTRL write; `memcard_dirty` is raised per slot and
  cleared per slot; `setMemoryCardData` round-trips.
- `ps1-capi/src/capi_test.zig`: `ps1_load_memcard` rejects a wrong length and
  an out-of-range slot; `ps1_take_memcard` returns 0 on a clean card and 1
  once dirtied, and returns 0 again immediately after; a card survives
  `ps1_reset`.
- Swift (`ps1-macos/Tests`): `MemoryCardStoreTests` — round trip, missing file
  is `nil`, wrong-size file is `nil`, write is atomic — and
  `MemoryCardFlushPolicyTests` driving the debounce with synthetic timestamps,
  including that a flush is not repeated while the card stays clean.

Each core and ABI test is to be verified to FAIL against the current
behaviour before the fix lands, per the house rule for regression tests.

## The golden recapture

Dropping the phantom pad on port 1 changes what the BIOS sees during KERNEL
SETUP, so `ps1-golden`'s `sio` hash will move on every workload, and `cpu` and
`ram` will move with it wherever the pad routine's timeout shifts instruction
counts. `state_hash.zig`'s `hashSio` is hand-written and must be updated in
the same commit to hash both card images and both sets of per-slot fields.

Sequence: land the core change with the hash update, confirm `verify` fails
only in the expected regions, then `capture` as **its own commit** with the
reason in the message. This is an intentional behaviour change, which is the
only circumstance under which the goldens are rewritten.

## Documentation

CLAUDE.md § Memory / interrupts / timers / SIO gains the port-select rule and
the card layout; § CDROM — state of play loses the multi-disc-saves gap. Both
in the implementing commits, not a trailing docs pass.
