# BIOS in the core: fast boot and identification

Status: design, awaiting review. Spec B (`2026-10-07-multi-file-disc-design.md`)
follows it and is independent.

## Goal

1. **Fast boot**, as DuckStation ships it: skip the BIOS shell (the Sony and
   PlayStation logos, and the memory-card / CD-player menu) and go straight to
   the game. Ships **OFF**. A nice-to-have, not a correctness feature.
2. **BIOS identification moves from Swift to the core**, so the curated table
   lives once, beside the code that patches the image, and wasm can use it.

Non-goals: PS2 BIOS images (DuckStation's Type 2 patch), sideloading an EXE,
any change to how a BIOS boots with fast boot off.

## What DuckStation does, and what we take

`duckstation_ref/src/core/bios.cpp:243` (`PatchBIOSFastBoot`) does not skip the
BIOS. It overwrites the routine that copies the shell out of ROM with five
instructions that turn the display on and return to the bootstrap:

```
lui  at, 0x1F80          0x3C011F80
lui  t2, 0x0300          0x3C0A0300
sw   t2, 0x1814(at)      0xAC2A1814   ; GP1(03h): display on, which the shell did
jr   ra                  0x03E00008
nop                      0x00000000
```

The kernel still initialises, and the bootstrap still reads SYSTEM.CNF and
loads the game's executable, so the game starts on a machine set up exactly as
after a full boot, only without the shell having run.

DuckStation locates the routine by byte pattern ("Type 1B"):

```
e0 ff bd 27  1c 00 bf af  20 00 a4 af  ?? ?? 05 3c
?? ?? 06 3c  ?? ?? c6 34  ?? ?? a5 34  ?? ?? ?? 0f
```

and falls back to offset `0x18000` ("Type 1A") only after its MD5 table has
confirmed the image is a known retail PS1 BIOS.

**We take the pattern and drop the fallback.** Measured against every image in
the repo, the pattern matches exactly once in each:

| Image                        | Offset   |
| ---------------------------- | -------- |
| SCPH-1000_BIOS_1994_JP.bin   | `0x6f6c` |
| SCPH-3000_BIOS_1995_JP.bin   | `0x6f6c` |
| SCPH-1001_BIOS_1995_US.bin   | `0x6ff0` |
| SCPH-101_BIOS_2000_US.bin    | `0x6ff0` |
| SCPH-7502_BIOS_1997_EU.bin   | `0x6ff0` |

A blind write at `0x18000` into an image we cannot vouch for corrupts it. An
image with no match, or more than one, boots in full instead: fast boot
degrades, it never breaks a boot.

## Core: `ps1-core/src/bios.zig` (new)

Re-exported from `root.zig` as `ps1_core.bios`.

```zig
pub const image_bytes = 512 * 1024;

pub const Region = enum { japan, america, europe };
pub const Info = struct { model: []const u8, revision: []const u8, region: Region };

/// nil: not in the table. Unidentified, never invalid.
pub fn identify(image: *const [image_bytes]u8) ?Info;

/// The bytes a fast-boot patch replaced, so the original image can be
/// reconstructed without keeping a second 512 KB copy.
pub const Patch = struct { offset: u32, original: [20]u8 };

/// Writes the shell replacement over the unique Type 1B match. Returns null,
/// with the image untouched, when there is no match or more than one.
pub fn patchFastBoot(image: *[image_bytes]u8) ?Patch;

/// SHA-256 of the image as it was before `patch`.
pub fn originalSha256(image: *const [image_bytes]u8, patch: ?Patch) [32]u8;
```

- The pattern is a `[32]?u8`, with `null` for a wildcard byte. The replacement
  is five little-endian words written as hex literals with their mnemonics
  beside them; no MIPS encoder is introduced for one use.
- `identify` holds the five-entry SHA-256 table moved verbatim from
  `ps1-macos/Sources/PS1/BiosIdentity.swift`, **with its provenance comment**:
  rows come from hashing a real file and finding that hash in DuckStation's
  table, never from memory. The `Region` mirrors `BiosRegion`'s three cases.
- `originalSha256` hashes incrementally: `[0, offset)`, `original`,
  `[offset + 20, end)`. No 512 KB scratch copy.

## Savestate identity

`savestate.identityOf` hashes `bus.bios` today. A patched image would hash
differently, so a state saved with fast boot on would refuse to load with it
off (`PS1_ERR_STATE_BIOS`), and the reverse.

- `Bus` gains `bios_patch: ?bios.Patch`. It is **host configuration, not
  machine state**: not in any savestate section, no section version bump.
  `Bus.init`'s `@memset(0)` leaves it null, which is the correct default.
- `identityOf` calls `bios.originalSha256(&bus.bios, bus.bios_patch)`. The
  identity is the BIOS the player owns, whatever was done to it in memory.

Accepted edge: a state saved *during* the shell and restored with the setting
flipped resumes into the other image's code at that PC. It affects only the
first seconds of a boot, so it is documented and left alone.

## C ABI (`ps1-capi`)

```c
/* Skips the BIOS shell (logos, memory-card / CD menu) on the next boot of a
 * disc, as DuckStation's "Fast Boot" does: the kernel still initialises and
 * the game still loads through SYSTEM.CNF. Takes effect at the next
 * ps1_reset or ps1_load_disc, not on the running machine. A BIOS the patch
 * does not recognise boots in full, silently. Off on a new handle. */
void ps1_set_fast_boot(Ps1*, uint8_t enabled);

typedef struct {
    uint8_t region;      /* Ps1Region */
    char    model[16];   /* "SCPH-1001", NUL-terminated */
    char    revision[32];/* "v2.2 12-04-95 A", NUL-terminated */
} Ps1BiosId;

/* Identifies a BIOS image by content, without a handle. Returns 1 and fills
 * `out` for an image in the core's table; returns 0 and zeroes `out` for any
 * other, including a buffer that is not 524288 bytes. Unidentified is not
 * invalid: the table lists only the images someone has hashed. */
uint8_t ps1_identify_bios(const uint8_t* bytes, size_t len, Ps1BiosId* out);
```

- `Handle` gains `fast_boot: bool`. It lives on the handle, so it survives
  `ps1_reset` the way the BIOS image does.
- `installHost` copies `h.bios` into `bus.bios` as today, then, **only if
  `h.fast_boot` and `h.disc != null`**, sets `bus.bios_patch =
  bios.patchFastBoot(&bus.bios)`. With no disc the shell is the only thing
  there is to show.
- `ps1_load_bios` writes `bus.bios` directly today; it goes through the same
  rule so a BIOS loaded after the flag is set is patched as well.

## Frontends

- **ps1-trace:** a `fastboot` keyword argument, beside `lean` and `pgxp`. It
  is the headless way to measure the feature.
- **macOS app:**
  - `BiosIdentity.swift` becomes a thin wrapper over `ps1_identify_bios`, in
    the shape of `DiscIdentity.swift`. `BiosImage` and `BiosLibrary`'s
    filename fallback are unchanged.
  - `FastBootSetting.swift`, a default-OFF `UserDefaults` bool in the shape
    of `ResumeOnExitSetting` (default off, so `bool(forKey:)` is correct
    here). A toggle in the General settings pane with `SettingInfo` copy.
    The runner calls `ps1_set_fast_boot` before it loads the disc.
- **Untouched:** ps1-golden, the ROM suites, the benches, wasm and ps1-debug
  never set the flag, so no golden moves. `trace-golden -- verify` and
  `-- savestate` confirm it.

## Testing

- `ps1-core/tests/bios_test.zig` (a new unit file, so `zig build test` goes
  to 23 binaries):
  - a synthetic image with the pattern at a known offset gets exactly the five
    words there and nothing else changes;
  - an image with no match, and one with two matches, are returned untouched
    with `null`;
  - `originalSha256` of a patched image equals the SHA-256 of the image before
    patching;
  - `identify` names a synthetic image whose hash is not in the table as null.
    The five real rows are covered by the Swift tests that already exercise
    `BiosIdentity` with the repo's images.
- `capi_test`: `ps1_identify_bios` rejects a wrong-sized buffer and zeroes
  `out`; the fast-boot flag survives `ps1_reset`.
- Manual: `ps1-trace` with `SCPH-1001` and Crash, with and without
  `fastboot`, reports the instruction count at which the game's executable
  entry point is first reached. The saving is stated in the commit that lands
  the feature's frontend half.
- Gates: `zig build test`, `trace-golden -- verify`, `-- savestate`,
  `ps1-macos/test.sh`.

## Docs

CLAUDE.md: `bios.zig` in the layout, `bios_test` in the unit list and the test
count, and one rule under a new "BIOS" heading: **the savestate identity hashes
the ORIGINAL BIOS; a fast-boot patch is host configuration and never part of
a state.**
