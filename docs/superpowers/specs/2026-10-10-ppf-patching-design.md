# PPF patching

A `.ppf` beside a disc (`Game.ppf` next to `Game.cue`, `Game.bin` or
`Game.chd`) is applied to the sectors the drive reads. PPF is how fan
translations, undubs and bug-fix patches for PlayStation games are shipped;
the player keeps an untouched rip and the patch alongside it.

## Decisions

1. **An overlay, built once at load.** `ppf.build` parses the patch, reads each
   sector it touches from the disc once, applies the records to those copies in
   file order (a later record overwrites an earlier one; a record crossing a
   sector boundary is split), and returns the patched sectors sorted by LBA.
   `Disc.readSector2352` serves a sector from the overlay when it holds one and
   from the `Source` otherwise. It works identically over a flat image and a
   CHD, and nothing above `disc.zig` knows a patch exists. Patching the image
   in place is not an option: a flat image is borrowed and a CHD is never
   decompressed whole.

2. **A PPF offset is a byte offset into the image, so `offset / 2352` is our
   LBA.** Our LBA 0 is byte 0 of the image (MSF 00:02:00); there is no pregap
   adjustment to make. A multi-file cue's track 1 sits at LBA 0, so a patch made
   against the track 1 `.bin` addresses the same sectors.

3. **Three versions.** PPF1 (`PPF10`, u32 offsets), PPF2 (`PPF20`, original
   size + 1024-byte blockcheck, u32 offsets), PPF3 (`PPF30`, image type,
   optional blockcheck, optional undo data, u64 offsets). A `FILE_ID.DIZ`
   trailer is stripped, never parsed for records. Records are
   `offset, u8 length, length bytes` (followed by `length` undo bytes in a PPF3
   with undo).

4. **Validation refuses instead of warning.** A patch made against a different
   rip corrupts the game silently, which is worse than refusing to load it.
   - Blockcheck (PPF2 always, PPF3 when its flag is set): the 1024 bytes must
     equal the image at byte `0x9320`, which is sector 16 + 32 (the PVD).
     Mismatch: `error.PpfMismatch`.
   - Undo data (PPF3): the original bytes under every record must equal the
     undo bytes. Mismatch: `error.PpfMismatch`.
   - Unknown magic, a truncated header or record, PPF3 image type other than
     BIN (0), a DIZ length that does not fit: `error.PpfBadFormat`.
   - A record past the end of the image is ignored, not refused: the sectors
     it would touch do not exist, so nothing can ever read them.
   - PPF2's "original file size" field is NOT checked: a CHD's sector count
     includes its 4-frame track padding and never matches a `.bin`'s size. The
     blockcheck is the format's identity check.

5. **The savestate identity includes the patch.** A translation patch keeps
   the disc's serial, so serial-only identity would resume an unpatched state
   on the patched disc (the app's resume state does this the moment a player
   adds a patch to a game already played) and mix two programs in RAM.
   The container goes to **format version 2**: the header grows from 64 to
   72 bytes with a `u64` patch fingerprint (Wyhash of the overlay's LBAs and
   sector bytes; 0 means unpatched). A version 1 state reads as fingerprint 0,
   so every existing state resumes on its unpatched disc exactly as before.
   A mismatch is `error.StatePatch` → `PS1_ERR_STATE_PATCH`. `Ps1StateInfo`
   is unchanged: nothing in the app needs the fingerprint before a load.
   Trusted snapshots write zero, as they do for the rest of the identity.

6. **The frontend owns the overlay's memory; the core owns its shape.**
   `ppf.Overlay` holds `lbas: []const i32`, `sectors: []const [2352]u8` and
   `fingerprint: u64`, the same borrow `Disc.sbi` has. The C ABI handle and the
   wasm machine own it and free it when the disc changes. The `.ppf` bytes
   themselves are not kept.

## Surfaces

- **Core.** `ps1-core/src/ppf.zig` (parse, validate, build, `Overlay.deinit`),
  `Disc.patch: ppf.Overlay = .{}`, the lookup in `readSector2352` (empty-overlay
  fast path, then binary search), savestate container v2.
- **C ABI.** `ps1_load_disc` and `ps1_swap_disc` gain `const uint8_t* ppf,
  size_t ppf_len` after the sidecar, NULL/0 meaning no patch. New codes:
  `PS1_ERR_BAD_PPF (-18)`, `PS1_ERR_PPF_MISMATCH (-19)`,
  `PS1_ERR_STATE_PATCH (-20)`. The overlay is built against the incoming disc
  in `prepareDisc`, so a refusal leaves the machine on the disc it had.
- **wasm / ps1-web.** The same two arguments on `loadDisc`/`swapDisc`, the
  three codes in `codes.zig` and `errors.ts`, `disc.ppf?: Uint8Array`, and
  `discFromFiles` picks up `<stem>.ppf` from the folder as it does `.sbi`.
- **macOS app.** `<disc stem>.ppf`, matched on the stem exactly as the `.sbi`
  sidecar is, passed on load and swap; messages for the three codes.
- **ps1-trace.** `ppf=<path>` applies a patch for a headless run. Explicit on
  purpose: `ps1-golden` must never pick a patch up from `games/`, or one
  dropped there would move every golden.

## Testing

- `ps1-core/tests/ppf_test.zig` (the 20th unit test file), over synthetic
  flat images: each version applies; a DIZ trailer is ignored; a record
  straddling two sectors; overlapping records apply in order; a record past
  the end is ignored; blockcheck mismatch and undo mismatch refuse; bad magic,
  truncation and GI image type refuse; an unpatched sector reads through.
- Savestate: a state saved patched refuses on the unpatched disc and the
  reverse; a version 1 header still loads.
- `capi_test`: the new arguments and the three codes; a refused patch keeps
  the old disc.
- `ps1-web`: the new arguments through `Ps1Core` and the stem match in
  `discFromFiles`.
- `trace-golden -- verify` stays byte-identical: no golden has a patch, and
  the overlay is empty on every read.
- End to end: a real PPF for a disc in `games/` (the SotN randomizer writes
  one for SLUS-00067) read back sector for sector against an image patched by
  an independent tool, then booted headless with `ps1-trace ppf=`.
