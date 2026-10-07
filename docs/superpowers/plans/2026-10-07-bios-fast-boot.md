# BIOS Fast Boot and Identification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skip the BIOS shell (logos and menu) on a disc boot, as DuckStation's "Fast Boot" does, shipped OFF; and move BIOS identification from Swift into the core.

**Architecture:** A new `ps1-core/src/bios.zig` owns the BIOS image as a host input: it identifies an image by SHA-256, patches the shell-copy routine with five instructions, and installs the image on a `Bus`. `Bus` remembers what the patch replaced so the savestate identity always hashes the ORIGINAL image. The C ABI gains a flag and an identify call; the macOS app gains a default-off toggle and loses its own SHA-256 table.

**Tech Stack:** Zig 0.17.0 (`std.crypto.hash.sha2.Sha256`), C ABI (`ps1-capi`), Swift / SwiftUI (`ps1-macos`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-07-bios-fast-boot-design.md`

## Global Constraints

- Zig **0.17.0**. No `**` array repeat (use `@splat`), no `std.meta.Int`.
- Fast boot ships **OFF** everywhere. Nothing in `ps1-golden`, the ROM suites, the benches, wasm or `ps1-debug` sets it.
- **No blind fallback offset.** The patch is applied only at a UNIQUE Type 1B pattern match; zero or several matches leave the image untouched and the boot full.
- The savestate identity hashes the **original** BIOS. `bios_patch` is host configuration: it is never written to a savestate section and no section version changes.
- `Bus.init` must NOT assign `bios_patch`: the `@memset(0)` leaves it `null`, which is the default.
- The flag lives on the C ABI `Handle`, so it survives `ps1_reset`. It takes effect when the BIOS is next installed (`ps1_reset`, `ps1_load_disc`, `ps1_load_bios`, `ps1_load_state`), never mid-run on its own.
- A C flag argument is `uint8_t`, as every `ps1_set_pgxp_*` takes (the spec's `bool` is corrected to this).
- Commit messages are a **title line only**: no body, no trailer. Commit directly on `master`. **Never `git push`.**
- `zig fmt` before every Zig commit. `pkill -x Substation` before running the Swift suite.
- No file in `ps1-core/src` over ~600 lines: `memory.zig` is already over, so it gets one field and nothing else.

## Review Focus

1. **BIOS loaded after the disc** (`ps1_load_disc` then `ps1_load_bios`): still patched. Test in Task 3.
2. **Fast boot on with no disc:** not patched; the shell is the only thing to show. Test in Task 3.
3. **A state saved with fast boot ON, loaded with it OFF** (and the reverse): loads with `PS1_OK`, not `PS1_ERR_STATE_BIOS`. Test in Task 3.
4. **An unrecognised BIOS with fast boot on:** boots in full, `bios_patch == null`, ROM byte-identical to the input. Tests in Tasks 1 and 3.
5. **Turning fast boot off and resetting:** the ROM is byte-identical to the loaded image again, not left patched. Test in Task 3.

---

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `ps1-core/src/bios.zig` | create | Identify, patch, original hash, install on a `Bus` |
| `ps1-core/src/root.zig` | modify | `pub const bios = @import("bios.zig");` |
| `ps1-core/src/memory.zig` | modify | one field: `bios_patch` |
| `ps1-core/src/savestate/savestate.zig` | modify | `identityOf` hashes the original image |
| `ps1-core/tests/bios_test.zig` | create | unit tests for all of the above |
| `build.zig` | modify | add `bios_test.zig` to `unit_test_files` (16 → 17) |
| `ps1-capi/src/root.zig` | modify | `fast_boot` on `Handle`, `installBios`, `ps1_set_fast_boot`, `ps1_identify_bios`, `Ps1BiosId` |
| `ps1-capi/include/ps1.h` | modify | the two declarations and the struct |
| `ps1-capi/src/capi_test.zig` | modify | the Review Focus tests |
| `ps1-trace/src/main.zig` | modify | `fastboot` keyword |
| `ps1-macos/Sources/PS1/CString.swift` | create | the C-array-to-String walk, shared by two identities |
| `ps1-macos/Sources/PS1/DiscIdentity.swift` | modify | use `CString` |
| `ps1-macos/Sources/PS1/BiosIdentity.swift` | modify | thin wrapper over `ps1_identify_bios` |
| `ps1-macos/Sources/PS1/FastBootSetting.swift` | create | default-OFF `UserDefaults` bool |
| `ps1-macos/Sources/PS1/Ps1Core.swift` | modify | `setFastBoot` |
| `ps1-macos/Sources/PS1/EmulatorViewModel.swift` | modify | `fastBoot` property; applied before `loadBIOS` |
| `ps1-macos/Sources/PS1/Settings/SettingsCopy.swift` | modify | `fastBoot` copy, added to `all` |
| `ps1-macos/Sources/PS1/Settings/GeneralSettingsPane.swift` | modify | the toggle |
| `ps1-macos/Tests/PS1Tests/FastBootSettingTests.swift` | create | setting tests |
| `CLAUDE.md` | modify | layout, test counts, the BIOS rule |

---

### Task 1: `bios.zig`: patch, original hash, identify

**Files:**
- Create: `ps1-core/src/bios.zig`
- Modify: `ps1-core/src/root.zig` (after `pub const discid`), `build.zig:200-217` and the two "16" comments at `build.zig:195` and `build.zig:261`
- Test: `ps1-core/tests/bios_test.zig`

**Interfaces:**
- Produces (used by Tasks 2-4):
  - `pub const image_bytes: usize = 512 * 1024;`
  - `pub const Region = enum { japan, america, europe };`
  - `pub const Info = struct { model: []const u8, revision: []const u8, region: Region };`
  - `pub const Patch = struct { offset: u32, original: [replacement_bytes]u8 };` with `pub const replacement_bytes = 20;`
  - `pub fn identify(image: *const [image_bytes]u8) ?Info`
  - `pub fn patchFastBoot(image: *[image_bytes]u8) ?Patch`
  - `pub fn originalSha256(image: *const [image_bytes]u8, patch: ?Patch) [32]u8`

- [ ] **Step 1: Write the failing tests**

Create `ps1-core/tests/bios_test.zig`:

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const ps1_core = @import("ps1_core");
const bios = ps1_core.bios;

/// The 32 bytes at 0x6FF0 of SCPH-1001 v2.2: the shell-copy routine the
/// pattern names, wildcard bytes included, as a real image carries them.
const routine = [32]u8{
    0xe0, 0xff, 0xbd, 0x27, 0x1c, 0x00, 0xbf, 0xaf,
    0x20, 0x00, 0xa4, 0xaf, 0xc1, 0xbf, 0x05, 0x3c,
    0x06, 0x00, 0x06, 0x3c, 0xf0, 0x7f, 0xc6, 0x34,
    0x00, 0x80, 0xa5, 0x34, 0xd4, 0x0a, 0xf0, 0x0f,
};

/// lui at,0x1F80 / lui t2,0x0300 / sw t2,0x1814(at) / jr ra / nop
const replacement = [5]u32{ 0x3C011F80, 0x3C0A0300, 0xAC2A1814, 0x03E00008, 0x00000000 };

/// A 512 KB image of a non-zero filler with `routine` planted at each offset,
/// so "nothing else changed" is a claim about real bytes, not about zeros.
fn plantedImage(offsets: []const u32) !*[bios.image_bytes]u8 {
    const image = try std.testing.allocator.create([bios.image_bytes]u8);
    for (image, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    for (offsets) |o| @memcpy(image[o..][0..routine.len], &routine);
    return image;
}

test "patchFastBoot writes the five words at the unique match and nothing else" {
    const image = try plantedImage(&.{0x6ff0});
    defer std.testing.allocator.destroy(image);
    const before = image.*;

    const patch = bios.patchFastBoot(image) orelse return error.NoMatch;
    try expectEqual(@as(u32, 0x6ff0), patch.offset);
    try std.testing.expectEqualSlices(u8, before[0x6ff0..][0..bios.replacement_bytes], &patch.original);

    for (replacement, 0..) |word, i| {
        try expectEqual(word, std.mem.readInt(u32, image[0x6ff0 + 4 * i ..][0..4], .little));
    }
    try std.testing.expectEqualSlices(u8, before[0..0x6ff0], image[0..0x6ff0]);
    try std.testing.expectEqualSlices(u8, before[0x6ff0 + bios.replacement_bytes ..], image[0x6ff0 + bios.replacement_bytes ..]);
}

test "patchFastBoot leaves an image with no match untouched" {
    const image = try plantedImage(&.{});
    defer std.testing.allocator.destroy(image);
    const before = image.*;

    try expect(bios.patchFastBoot(image) == null);
    try std.testing.expectEqualSlices(u8, &before, image);
}

test "patchFastBoot leaves an image with two matches untouched" {
    const image = try plantedImage(&.{ 0x6f6c, 0x18000 });
    defer std.testing.allocator.destroy(image);
    const before = image.*;

    try expect(bios.patchFastBoot(image) == null);
    try std.testing.expectEqualSlices(u8, &before, image);
}

test "patchFastBoot accepts any value in a wildcard byte" {
    const image = try plantedImage(&.{0x6f6c});
    defer std.testing.allocator.destroy(image);
    image[0x6f6c + 12] ^= 0xff; // a wildcard of `lui a1, 0xbfc1`

    try expect(bios.patchFastBoot(image) != null);
}

test "originalSha256 of a patched image is the hash of the image before patching" {
    const image = try plantedImage(&.{0x6ff0});
    defer std.testing.allocator.destroy(image);
    var want: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &want, .{});

    const patch = bios.patchFastBoot(image);
    try expect(patch != null);
    try expectEqual(want, bios.originalSha256(image, patch));
}

test "originalSha256 with no patch is the plain hash" {
    const image = try plantedImage(&.{});
    defer std.testing.allocator.destroy(image);
    var want: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &want, .{});

    try expectEqual(want, bios.originalSha256(image, null));
}

/// The five real rows are pinned by `BiosIdentityTests.swift` against the
/// repo's images, through the C ABI; this is the unlisted case.
test "identify names an image outside the table as nothing" {
    const image = try plantedImage(&.{});
    defer std.testing.allocator.destroy(image);

    try expect(bios.identify(image) == null);
}
```

Add `"ps1-core/tests/bios_test.zig",` to `unit_test_files` in `build.zig` after `discid_test.zig`, and change the two comments that say "16" (`build.zig:195`, `build.zig:261`) to "17".

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test -Dtest-filter=patchFastBoot`
Expected: compile error, `root source file struct 'root' has no member named 'bios'`.

- [ ] **Step 3: Write `bios.zig`**

Create `ps1-core/src/bios.zig`:

```zig
//! The BIOS image as a host input: what it is, and what fast boot does to it.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const image_bytes: usize = 512 * 1024;

pub const Region = enum { japan, america, europe };

pub const Info = struct {
    model: []const u8,
    revision: []const u8,
    region: Region,
};

/// Identifies an image by content. Null means "not in the table":
/// UNIDENTIFIED, never invalid.
///
/// **A CURATED table, and that is a real limit.** It knows the images someone
/// put in it and nothing else. The sha256s were computed from the images in
/// this repo; the model, revision and region beside each were cross-checked
/// against DuckStation's own BIOS table (`src/core/bios.cpp`, keyed on MD5) by
/// matching each file's MD5 to an entry there. All five matched, and one
/// corrected a guess: `SCPH-101_BIOS_2000_US.bin` is **v4.5 05-25-00**, not
/// the v4.4 03-24-00 image a from-memory table would likely name. Do not add a
/// row from memory: hash the file, then find that hash in a real source.
pub fn identify(image: *const [image_bytes]u8) ?Info {
    var digest: [32]u8 = undefined;
    Sha256.hash(image, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    for (table) |row| {
        if (std.mem.eql(u8, &hex, row.sha256)) return row.info;
    }
    return null;
}

const Row = struct { sha256: *const [64]u8, info: Info };

const table = [_]Row{
    // SCPH-1000, DTL-H1000
    .{ .sha256 = "cfc1fc38eb442f6f80781452119e931bcae28100c1c97e7e6c5f2725bbb0f8bb", .info = .{ .model = "SCPH-1000", .revision = "v1.0", .region = .japan } },
    // SCPH-1001, 5003, DTL-H1201, H3001
    .{ .sha256 = "71af94d1e47a68c11e8fdb9f8368040601514a42a5a399cda48c7d3bff1e99d3", .info = .{ .model = "SCPH-1001", .revision = "v2.2 12-04-95 A", .region = .america } },
    // SCPH-101; the PSone. v4.5, not the v4.4 dump of the same model.
    .{ .sha256 = "aca9cbfa974b933646baad6556a867eca9b81ce65d8af343a7843f7775b9ffc8", .info = .{ .model = "SCPH-101", .revision = "v4.5 05-25-00 A", .region = .america } },
    // SCPH-3000, DTL-H1000H
    .{ .sha256 = "5eb3aee495937558312b83b54323d76a4a015190decd4051214f1b6df06ac34b", .info = .{ .model = "SCPH-3000", .revision = "v1.1 01-22-95", .region = .japan } },
    // SCPH-7002, 7502, 9002
    .{ .sha256 = "5e84a94818cf5282f4217591fefd88be36b9b174b3cc7cb0bcd75199beb450f1", .info = .{ .model = "SCPH-7502", .revision = "v4.1 12-16-97 E", .region = .europe } },
};

/// The routine that copies the shell out of ROM ("Type 1B" in DuckStation's
/// `PatchBIOSFastBoot`). Null is a wildcard: the immediates differ by revision.
const shell_copy = [32]?u8{
    0xe0, 0xff, 0xbd, 0x27, // addiu sp, sp, -0x20
    0x1c, 0x00, 0xbf, 0xaf, // sw    ra, 0x1c(sp)
    0x20, 0x00, 0xa4, 0xaf, // sw    a0, 0x20(sp)
    null, null, 0x05, 0x3c, // lui   a1, 0xbfc1
    null, null, 0x06, 0x3c, // lui   a2, 0x6
    null, null, 0xc6, 0x34, // ori   a2, a2, 0x7ff0
    null, null, 0xa5, 0x34, // ori   a1, a1, 0x8000
    null, null, null, 0x0f, // jal   <copy>
};

/// What the shell did that the game still needs (the display on), then
/// straight back to the bootstrap, which goes on to load SYSTEM.CNF's EXE.
const replacement = [_]u32{
    0x3C011F80, // lui  at, 0x1F80
    0x3C0A0300, // lui  t2, 0x0300
    0xAC2A1814, // sw   t2, 0x1814(at)   GP1(03h): display on
    0x03E00008, // jr   ra
    0x00000000, // nop
};

pub const replacement_bytes = replacement.len * 4;

/// The bytes a fast-boot patch replaced, so the original image can be
/// reconstructed without keeping a second 512 KB copy.
pub const Patch = struct {
    offset: u32,
    original: [replacement_bytes]u8,
};

/// Writes the shell replacement over the UNIQUE `shell_copy` match. Null,
/// with the image untouched, when there is none or more than one: unlike
/// DuckStation there is no fixed fallback offset, because a write into an
/// image nobody has vouched for corrupts it, and a full boot is never wrong.
pub fn patchFastBoot(image: *[image_bytes]u8) ?Patch {
    var found: ?u32 = null;
    var offset: u32 = 0;
    while (offset + shell_copy.len <= image_bytes) : (offset += 4) {
        if (!matches(image[offset..][0..shell_copy.len])) continue;
        if (found != null) return null;
        found = offset;
    }
    const at = found orelse return null;

    var patch = Patch{ .offset = at, .original = undefined };
    @memcpy(&patch.original, image[at..][0..replacement_bytes]);
    for (replacement, 0..) |word, i| {
        std.mem.writeInt(u32, image[at + 4 * i ..][0..4], word, .little);
    }
    return patch;
}

fn matches(bytes: *const [shell_copy.len]u8) bool {
    for (shell_copy, bytes) |want, got| {
        if (want) |w| if (w != got) return false;
    }
    return true;
}

/// SHA-256 of the image as it was before `patch`: the BIOS the player owns,
/// whatever was done to it in memory.
pub fn originalSha256(image: *const [image_bytes]u8, patch: ?Patch) [32]u8 {
    var h = Sha256.init(.{});
    if (patch) |p| {
        h.update(image[0..p.offset]);
        h.update(&p.original);
        h.update(image[p.offset + replacement_bytes ..]);
    } else {
        h.update(image);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}
```

In `ps1-core/src/root.zig`, after `pub const discid = @import("discid.zig");`, add:

```zig
pub const bios = @import("bios.zig");
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test -Dtest-filter=patchFastBoot && zig build test -Dtest-filter=originalSha256 && zig build test -Dtest-filter=identify`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-core/src/bios.zig ps1-core/tests/bios_test.zig build.zig
git add ps1-core/src/bios.zig ps1-core/src/root.zig ps1-core/tests/bios_test.zig build.zig
git commit -m "feat(core): bios.zig identifies an image and patches it for fast boot"
```

---

### Task 2: Install on a `Bus`; the savestate identity hashes the original

**Files:**
- Modify: `ps1-core/src/bios.zig` (append `install`)
- Modify: `ps1-core/src/memory.zig:190` (one field after `bios`)
- Modify: `ps1-core/src/savestate/savestate.zig:41-46`
- Test: `ps1-core/tests/bios_test.zig`

**Interfaces:**
- Consumes: `bios.patchFastBoot`, `bios.originalSha256`, `bios.Patch` (Task 1).
- Produces (used by Tasks 3-4):
  - `Bus.bios_patch: ?bios.Patch` (null after `Bus.init`)
  - `pub fn install(bus: *Bus, image: *const [image_bytes]u8, fast_boot: bool) void` in `bios.zig`

- [ ] **Step 1: Write the failing tests**

Append to `ps1-core/tests/bios_test.zig`:

```zig
const Bus = ps1_core.memory.Bus;

test "install with fast boot patches the bus and records what it replaced" {
    const image = try plantedImage(&.{0x6ff0});
    defer std.testing.allocator.destroy(image);
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    try expect(bus.bios_patch == null);
    bios.install(bus, image, true);
    const patch = bus.bios_patch orelse return error.NotPatched;
    try expectEqual(@as(u32, 0x6ff0), patch.offset);
    try expectEqual(replacement[0], std.mem.readInt(u32, bus.bios[0x6ff0..][0..4], .little));
}

test "install without fast boot copies the image unchanged and clears a previous patch" {
    const image = try plantedImage(&.{0x6ff0});
    defer std.testing.allocator.destroy(image);
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    bios.install(bus, image, true);
    bios.install(bus, image, false);
    try expect(bus.bios_patch == null);
    try std.testing.expectEqualSlices(u8, image, &bus.bios);
}

test "a savestate identity is the same with and without the fast-boot patch" {
    const image = try plantedImage(&.{0x6ff0});
    defer std.testing.allocator.destroy(image);
    const plain = try Bus.init(std.testing.allocator);
    defer plain.deinit(std.testing.allocator);
    const patched = try Bus.init(std.testing.allocator);
    defer patched.deinit(std.testing.allocator);

    bios.install(plain, image, false);
    bios.install(patched, image, true);
    try expect(patched.bios_patch != null);
    try expectEqual(
        ps1_core.savestate.identityOf(plain).bios_sha256,
        ps1_core.savestate.identityOf(patched).bios_sha256,
    );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test -Dtest-filter=install`
Expected: compile error, `no field named 'bios_patch'` / `no member named 'install'`.

- [ ] **Step 3: Add the field, `install` and the identity change**

In `ps1-core/src/memory.zig`, at the top-level imports add `const bios_rom = @import("bios.zig");` (not `bios`, which is the field below), and after `bios: [512 * KB]u8,` add:

```zig
    /// What a fast-boot patch replaced in `bios`, or null for an image as
    /// loaded. Host configuration, not machine state: no savestate carries
    /// it, and `Bus.init`'s memset leaves it null, which is the default.
    bios_patch: ?bios_rom.Patch = null,
```

In `ps1-core/src/bios.zig`, beside the `std` import at the top, add (the two files share a directory; Zig accepts the mutual import):

```zig
const Bus = @import("memory.zig").Bus;
```

and append:

```zig
/// Puts `image` in the bus's ROM, patched for fast boot when asked and when
/// the image is one the patch recognises.
pub fn install(bus: *Bus, image: *const [image_bytes]u8, fast_boot: bool) void {
    @memcpy(&bus.bios, image);
    bus.bios_patch = if (fast_boot) patchFastBoot(&bus.bios) else null;
    // A block engine compiles ROM like any other code and never sees a store
    // to it, so blocks built from the old bytes must go.
    if (bus.blocks) |c| c.flush();
}
```

In `ps1-core/src/savestate/savestate.zig`, add `const bios = @import("../bios.zig");` beside the other imports and change `identityOf`:

```zig
pub fn identityOf(bus: *const Bus) Identity {
    var id = Identity{ .bios_sha256 = bios.originalSha256(&bus.bios, bus.bios_patch), .serial = @splat(0) };
    if (bus.cdrom.disc) |d| id.serial = discid.identify(d).serial.buf;
    return id;
}
```

Extend the doc comment above `Identity` by one sentence: `The hash is of the ORIGINAL image: a fast-boot patch is host configuration, so a state resumes with the setting either way.`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all 23 binaries pass (the ROM suites self-skip).

- [ ] **Step 5: Verify no golden moved**

Run: `zig build trace-golden -Doptimize=ReleaseFast -- verify && zig build trace-golden -Doptimize=ReleaseFast -- savestate`
Expected: both green. A change here is a bug in the gating, never a recapture.

- [ ] **Step 6: Commit**

```bash
zig fmt ps1-core/src
git add ps1-core/src/bios.zig ps1-core/src/memory.zig ps1-core/src/savestate/savestate.zig ps1-core/tests/bios_test.zig
git commit -m "feat(core): a fast-boot patch installs on Bus and never changes a state's BIOS identity"
```

---

### Task 3: C ABI: `ps1_set_fast_boot` and `ps1_identify_bios`

**Files:**
- Modify: `ps1-capi/src/root.zig` (`Handle` at :52, `installHost` at :115, `ps1_load_bios` at :319, `ps1_load_disc` at :400, new exports beside `ps1_identify_disc` at :453)
- Modify: `ps1-capi/include/ps1.h` (after `ps1_load_bios` at :59, and after `ps1_lookup_disc_set` at :164)
- Test: `ps1-capi/src/capi_test.zig`

**Interfaces:**
- Consumes: `ps1.bios.install`, `ps1.bios.identify`, `ps1.bios.image_bytes`, `Bus.bios_patch` (Tasks 1-2).
- Produces (used by Task 5):
  - `void ps1_set_fast_boot(Ps1*, uint8_t enabled);`
  - `typedef struct { uint8_t region; char model[16]; char revision[32]; } Ps1BiosId;`
  - `uint8_t ps1_identify_bios(const uint8_t* bytes, size_t len, Ps1BiosId* out);`

- [ ] **Step 1: Write the failing tests**

Append to `ps1-capi/src/capi_test.zig` (it already imports `std` and `capi`):

```zig
/// SCPH-1001 if the repo has it (gitignored), else null and the test skips.
fn repoBios() ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, "SCPH-1001_BIOS_1995_US.bin", std.testing.allocator, .limited(1 << 20)) catch null;
}

/// Two zeroed sectors: enough of a disc for `ps1_load_disc` to accept.
var blank_disc: [2 * 2352]u8 = @splat(0);

test "fast boot patches only once a disc is in, whichever was loaded first" {
    const image = repoBios() orelse return error.SkipZigTest;
    defer std.testing.allocator.free(image);
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_fast_boot(h, 1);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, image.ptr, image.len));
    try std.testing.expect(h.bus.bios_patch == null); // no disc: the shell is all there is

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &blank_disc, blank_disc.len, null, 0, null, 0));
    try std.testing.expectEqual(@as(u32, 0x6ff0), (h.bus.bios_patch orelse return error.NotPatched).offset);

    // The reverse order: disc first, then the BIOS.
    const h2 = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h2);
    capi.ps1_set_fast_boot(h2, 1);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h2, &blank_disc, blank_disc.len, null, 0, null, 0));
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h2, image.ptr, image.len));
    try std.testing.expect(h2.bus.bios_patch != null);
}

test "fast boot survives a reset, and turning it off restores the image on the next one" {
    const image = repoBios() orelse return error.SkipZigTest;
    defer std.testing.allocator.free(image);
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_fast_boot(h, 1);
    _ = capi.ps1_load_bios(h, image.ptr, image.len);
    _ = capi.ps1_load_disc(h, &blank_disc, blank_disc.len, null, 0, null, 0);
    capi.ps1_reset(h);
    try std.testing.expect(h.bus.bios_patch != null);

    capi.ps1_set_fast_boot(h, 0);
    try std.testing.expect(h.bus.bios_patch != null); // not until the next boot
    capi.ps1_reset(h);
    try std.testing.expect(h.bus.bios_patch == null);
    try std.testing.expectEqualSlices(u8, image, &h.bus.bios);
}

test "an unrecognised BIOS with fast boot on boots in full" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    var image: [512 * 1024]u8 = @splat(0x5a);

    capi.ps1_set_fast_boot(h, 1);
    _ = capi.ps1_load_bios(h, &image, image.len);
    _ = capi.ps1_load_disc(h, &blank_disc, blank_disc.len, null, 0, null, 0);
    try std.testing.expect(h.bus.bios_patch == null);
    try std.testing.expectEqualSlices(u8, &image, &h.bus.bios);
}

test "a state saved with fast boot on loads with it off" {
    const image = repoBios() orelse return error.SkipZigTest;
    defer std.testing.allocator.free(image);
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_fast_boot(h, 1);
    _ = capi.ps1_load_bios(h, image.ptr, image.len);
    _ = capi.ps1_load_disc(h, &blank_disc, blank_disc.len, null, 0, null, 0);
    capi.ps1_run_frame(h);

    const size = capi.ps1_save_state_size(h);
    const state = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(state);
    var written: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_save_state(h, state.ptr, state.len, &written));

    capi.ps1_set_fast_boot(h, 0);
    capi.ps1_reset(h);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_state(h, state.ptr, written));
}

test "ps1_identify_bios zeroes out and returns 0 for a buffer of the wrong size" {
    var out: capi.Ps1BiosId = .{ .region = 9, .model = @splat('x'), .revision = @splat('x') };
    var short: [1024]u8 = @splat(0);
    try std.testing.expectEqual(@as(u8, 0), capi.ps1_identify_bios(&short, short.len, &out));
    try std.testing.expectEqual(@as(u8, 0), out.region);
    try std.testing.expectEqual(@as(u8, 0), out.model[0]);
}

test "ps1_identify_bios names SCPH-1001" {
    const image = repoBios() orelse return error.SkipZigTest;
    defer std.testing.allocator.free(image);
    var out: capi.Ps1BiosId = undefined;
    try std.testing.expectEqual(@as(u8, 1), capi.ps1_identify_bios(image.ptr, image.len, &out));
    try std.testing.expectEqual(@as(u8, 1), out.region); // PS1_REGION_AMERICA
    try std.testing.expectEqualStrings("SCPH-1001", std.mem.sliceTo(&out.model, 0));
}
```

These match the signatures in `ps1-capi/src/root.zig` (`ps1_save_state(h, dst, cap, *out_len)`, `ps1_load_state(h, src, len)`) and the `std.testing.io` idiom `capi_test.zig` already uses.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: `capi_test` fails to compile: no member `ps1_set_fast_boot` / `Ps1BiosId` / `ps1_identify_bios`.

- [ ] **Step 3: Implement**

In `Handle`, after `bios_loaded`:

```zig
    /// Skip the BIOS shell on a disc boot (`ps1_set_fast_boot`). A host
    /// setting like `engine`: it outlives every `Bus` this file builds.
    fast_boot: bool = false,
```

Add beside `installHost`:

```zig
/// Puts the host's BIOS in a bus's ROM, patched for fast boot when the host
/// asked for it AND a disc is in: with no disc the shell is all there is.
fn installBios(h: *const Handle, bus: *Bus) void {
    if (!h.bios_loaded) return;
    ps1.bios.install(bus, &h.bios, h.fast_boot and h.disc != null);
}
```

In `installHost`, replace `if (h.bios_loaded) @memcpy(bus.bios[0..], h.bios[0..]);` with `installBios(h, bus);`, and move it to AFTER the `if (h.disc) |d| bus.cdrom.setDisc(d);` line (it reads `h.disc`, not the bus, so the order is for the reader).

In `ps1_load_bios`, replace `@memcpy(h.bus.bios[0..], h.bios[0..]);` with `installBios(h, h.bus);`.

In `ps1_load_disc`, after `h.cpu.bus.cdrom.setDisc(d);` add `installBios(h, h.bus);`.

Add the exports beside `ps1_identify_disc`:

```zig
/// Takes effect the next time the BIOS is installed (`ps1_reset`,
/// `ps1_load_disc`, `ps1_load_bios`, `ps1_load_state`), never on its own:
/// the shell has long since run on a machine already going.
pub export fn ps1_set_fast_boot(h: *Handle, enabled: u8) void {
    h.fast_boot = enabled != 0;
}

pub const Ps1BiosId = extern struct {
    region: u8,
    model: [16]u8,
    revision: [32]u8,
};

/// Identifies a BIOS image by content, without a handle. 1 and `out` filled
/// for an image in the core's table; 0 and `out` zeroed for any other.
pub export fn ps1_identify_bios(bytes: [*]const u8, len: usize, out: *Ps1BiosId) u8 {
    out.* = .{ .region = region_unknown, .model = @splat(0), .revision = @splat(0) };
    if (len != ps1.bios.image_bytes) return 0;
    const info = ps1.bios.identify(bytes[0..ps1.bios.image_bytes]) orelse return 0;
    out.region = switch (info.region) {
        .america => 1,
        .europe => 2,
        .japan => 3,
    };
    copyString(&out.model, info.model);
    copyString(&out.revision, info.revision);
    return 1;
}
```

In `ps1-capi/include/ps1.h`, after `ps1_load_bios`:

```c
/* Skips the BIOS shell (the logos and the memory-card / CD menu) on a disc
 * boot, as DuckStation's "Fast Boot" does: the kernel still initialises and
 * the game still loads through SYSTEM.CNF. Takes effect the next time the
 * BIOS is installed (ps1_reset, ps1_load_disc, ps1_load_bios,
 * ps1_load_state), not on a running machine. A BIOS the patch does not
 * recognise boots in full, silently. Off on a new handle; survives a reset.
 * A savestate records the ORIGINAL BIOS, so it resumes with this either way. */
void    ps1_set_fast_boot(Ps1*, uint8_t enabled);
```

and after `ps1_lookup_disc_set`:

```c
/* What a BIOS image is, from its bytes. */
typedef struct {
    uint8_t region;        /* Ps1Region */
    char    model[16];     /* "SCPH-1001", NUL-terminated */
    char    revision[32];  /* "v2.2 12-04-95 A", NUL-terminated */
} Ps1BiosId;

/* Identifies a BIOS image by content, without a handle. Returns 1 and fills
 * `out` for an image in the core's table; returns 0 and zeroes `out` for any
 * other, including a buffer that is not 524288 bytes. Unidentified is not
 * invalid: the table lists only the images someone has hashed. */
uint8_t ps1_identify_bios(const uint8_t* bytes, size_t len, Ps1BiosId* out);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all pass, including the six new `capi_test` tests (four skip on a machine without the BIOS file).

- [ ] **Step 5: Commit**

```bash
zig fmt ps1-capi/src
git add ps1-capi/src/root.zig ps1-capi/src/capi_test.zig ps1-capi/include/ps1.h
git commit -m "feat(capi): ps1_set_fast_boot and ps1_identify_bios"
```

---

### Task 4: `ps1-trace fastboot`, and measure the saving

**Files:**
- Modify: `ps1-trace/src/main.zig:209` (usage), the keyword scan beside `pgxp` (~:251), and the BIOS copy at ~:313

**Interfaces:**
- Consumes: `ps1.bios.install`, `ps1.bios.image_bytes`, `Bus.bios_patch`.

- [ ] **Step 1: Add the keyword**

Add `[fastboot]` to the usage string after `[depth]`. Beside the `pgxp` scan:

```zig
    // "fastboot" skips the BIOS shell, as ps1_set_fast_boot does in the app.
    const fastboot = for (argv.items) |arg| {
        if (std.mem.eql(u8, arg, "fastboot")) break true;
    } else false;
```

Replace `@memcpy(bus.bios[0..], bios);` with:

```zig
    ps1.bios.install(bus, bios[0..ps1.bios.image_bytes], fastboot);
    if (fastboot) {
        if (bus.bios_patch) |p| {
            std.debug.print("[fastboot] shell skipped: patched at 0x{x}\n", .{p.offset});
        } else {
            std.debug.print("[fastboot] BIOS not recognised: full boot\n", .{});
        }
    }
```

(ps1-trace always has a disc, so it needs no "disc is in" condition.)

- [ ] **Step 2: Build and run both ways**

```bash
zig build -Doptimize=ReleaseFast
mkdir -p /tmp/claude-fb/full /tmp/claude-fb/fast
zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin "games/<crash dir>/<crash>.cue" 300000000 /tmp/claude-fb/full lean
zig-out/bin/ps1-trace SCPH-1001_BIOS_1995_US.bin "games/<crash dir>/<crash>.cue" 300000000 /tmp/claude-fb/fast lean fastboot
```

Find the Crash Bandicoot directory with `ls games | grep -i crash` first (use the NTSC-U disc, since this BIOS is US). Expected: the second run prints `[fastboot] shell skipped: patched at 0x6ff0`.

- [ ] **Step 3: Compare**

Open the `frame_*.ppm` snapshots of both runs with the Read tool, and find the first frame in each that shows the game rather than the BIOS (the first Sony Computer Entertainment America / Universal Interactive screen). Record both instruction counts (the filenames are in millions of instructions) and their difference in seconds at 33.8688 MHz. Expected: the fast run never shows the Sony or PlayStation logo, and reaches the game several seconds of emulated time earlier.

If the fast run shows a black screen that never changes, STOP: that is the BIOS unresolved-exception hang (`ps1-debugging-real-games`), not a display issue. Report it rather than working around it.

- [ ] **Step 4: Commit**

```bash
zig fmt ps1-trace/src/main.zig
git add ps1-trace/src/main.zig
git commit -m "feat(trace): fastboot skips the BIOS shell"
```

Report the two instruction counts and the saving to the user in the task summary.

---

### Task 5: macOS app: identity through the core, and the toggle

**Files:**
- Create: `ps1-macos/Sources/PS1/CString.swift`
- Modify: `ps1-macos/Sources/PS1/DiscIdentity.swift` (the private `string(from:)` and its two call sites)
- Modify: `ps1-macos/Sources/PS1/BiosIdentity.swift`
- Create: `ps1-macos/Sources/PS1/FastBootSetting.swift`
- Modify: `ps1-macos/Sources/PS1/Ps1Core.swift:153` (beside `reset()`)
- Modify: `ps1-macos/Sources/PS1/EmulatorViewModel.swift:77` (setting), `:98-101` (property), `:979` (applied)
- Modify: `ps1-macos/Sources/PS1/Settings/SettingsCopy.swift:57-60` and the `all` list at `:276`
- Modify: `ps1-macos/Sources/PS1/Settings/GeneralSettingsPane.swift` ("Games" section)
- Test: `ps1-macos/Tests/PS1Tests/FastBootSettingTests.swift`; existing `BiosIdentityTests.swift` must pass unchanged

**Interfaces:**
- Consumes: `ps1_set_fast_boot`, `ps1_identify_bios`, `Ps1BiosId` (Task 3).
- Produces: `FastBootSetting(key:defaults:)`, `.enabled`, `.set(_:)`; `EmulatorViewModel.fastBoot: Bool`; `Ps1Core.setFastBoot(_:)`; `cString(_:)`.

- [ ] **Step 1: Write the failing setting test**

Create `ps1-macos/Tests/PS1Tests/FastBootSettingTests.swift`:

```swift
import Testing
import Foundation
@testable import PS1

/// Default OFF, so unlike `MultiDiscSetting` the absent key and `false` agree.
struct FastBootSettingTests {
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func aMissingKeyMeansOff() {
        let d = scratchDefaults("fastboot.default")
        #expect(FastBootSetting(key: "fastboot", defaults: d).enabled == false)
    }

    @Test func persistsBothWays() {
        let d = scratchDefaults("fastboot.persist")
        var s = FastBootSetting(key: "fastboot", defaults: d)

        s.set(true)
        #expect(FastBootSetting(key: "fastboot", defaults: d).enabled == true)
        s.set(false)
        #expect(FastBootSetting(key: "fastboot", defaults: d).enabled == false)
    }
}
```

- [ ] **Step 2: Build the core and run the test to verify it fails**

```bash
zig build capi-lib && zig build metallib
pkill -x Substation; ps1-macos/test.sh -only-testing:PS1Tests/FastBootSettingTests
```

Expected: build failure, `cannot find 'FastBootSetting' in scope`. (If `test.sh` does not forward `-only-testing`, read it and use the `xcodebuild test` line it runs; per memory, a filter that matches nothing reports "passed" with 0 tests, so confirm the count.)

- [ ] **Step 3: Implement the setting**

Create `ps1-macos/Sources/PS1/FastBootSetting.swift`:

```swift
import Foundation

/// Whether a game boots past the BIOS logos (`ps1_set_fast_boot`).
///
/// Defaults to FALSE, as DuckStation ships it, so `bool(forKey:)`'s
/// false-for-absent is exactly the default and needs no probing.
struct FastBootSetting {
    static let defaultsKey = "fastBoot"

    private let defaults: UserDefaults
    private let key: String
    private(set) var enabled: Bool

    init(key: String = FastBootSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = defaults.bool(forKey: key)
    }

    mutating func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: key)
    }
}
```

In `Ps1Core.swift`, after `func reset() { ps1_reset(handle) }`:

```swift
    /// Takes effect at the next BIOS install: call it before `loadBIOS`.
    func setFastBoot(_ enabled: Bool) { ps1_set_fast_boot(handle, enabled ? 1 : 0) }
```

In `EmulatorViewModel.swift`, after `private var resumeOnExit = ResumeOnExitSetting()`:

```swift
    private var fastBootSetting = FastBootSetting()
```

after the `saveStateOnExit` property:

```swift
    /// Read when a game starts, so a change applies from the next one.
    var fastBoot: Bool {
        get { fastBootSetting.enabled }
        set { fastBootSetting.set(newValue) }
    }
```

and in the boot sequence, between `try? core.setCpuEngine(cpuEngine)` and `try core.loadBIOS(biosData)`:

```swift
            core.setFastBoot(fastBoot)
```

In `SettingsCopy.swift`, after `saveOnExit`:

```swift
    static let fastBoot = SettingInfo(
        title: "Skip Startup Logos",
        details: "Goes straight to the game instead of showing the PlayStation startup logos. The console still starts up fully behind the scenes; only the logo screens are skipped. Applies the next time a game starts."
    )
```

and add `fastBoot` to `all` after `saveOnExit`.

In `GeneralSettingsPane.swift`, inside `Section("Games")` after the game-window `SettingRow`:

```swift
                SettingToggle(SettingsCopy.fastBoot, isOn: $model.fastBoot)
```

- [ ] **Step 4: Move BIOS identification to the core**

Create `ps1-macos/Sources/PS1/CString.swift`:

```swift
/// A NUL-terminated C array inside a struct, which Swift imports as a tuple:
/// hence the pointer walk rather than a `String(cString:)` over the tuple
/// itself. Empty becomes nil: the core had nothing to say.
func cString<T>(_ field: inout T) -> String? {
    let text = withUnsafePointer(to: &field) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
    return text.isEmpty ? nil : text
}
```

In `DiscIdentity.swift`, delete `private static func string<T>(from field: inout T) -> String?` and its doc comment, and replace every `string(from: &x)` with `cString(&x)` (four, at :57, :64 and twice at :65).

Replace the body of `BiosIdentity.swift` from `enum BiosIdentity {` to the end of the file with:

```swift
enum BiosIdentity {
    /// Every PS1 BIOS image is exactly this long. A file of any other length is
    /// not a candidate and is never hashed.
    static let byteCount = 524288

    /// nil means "not in the core's table": unidentified, not invalid.
    static func identify(_ data: Data) -> BiosImage? {
        var raw = Ps1BiosId()
        let found = data.withUnsafeBytes { bytes in
            ps1_identify_bios(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &raw)
        }
        guard found != 0,
              let model = cString(&raw.model),
              let revision = cString(&raw.revision),
              let region = DiscIdentity.Region(raw.region)
        else { return nil }
        return BiosImage(model: model, revision: revision, region: BiosRegion(region))
    }
}
```

Replace `import CryptoKit` with `import CPs1`, and replace the long doc comment above `enum BiosIdentity` with:

```swift
/// Identifies a BIOS image by content hash, through the core's curated table
/// (`ps1-core/src/bios.zig`, which documents where every row came from).
///
/// It replaces two weak checks at once: the `hasPrefix("scph-1001")` filename
/// match, which a rename defeats and a MISNAMED file defeats worse, and the
/// bare 512 KB size test, which any corrupt file of the right length passes.
/// An image the table cannot name is UNIDENTIFIED, never rejected:
/// `BiosLibrary` falls back to the filename rule for it.
```

- [ ] **Step 5: Run the Swift suite**

```bash
zig build capi-lib
pkill -x Substation; ps1-macos/test.sh
```

Expected: all pass, including `FastBootSettingTests` (2), `BiosIdentityTests` unchanged (4), and `SettingsCopyTests` with the new copy.

- [ ] **Step 6: Try it in the app**

```bash
zig build macos && open zig-out/Substation.app
```

Turn on Settings → General → Games → "Skip Startup Logos", start Crash Bandicoot, and confirm it opens on the game's first screen with no Sony or PlayStation logo. Turn it off and confirm the logos are back. Resume a state saved with the setting on, with it off: it must resume, not report a BIOS mismatch.

- [ ] **Step 7: Commit**

```bash
git add ps1-macos/Sources/PS1/CString.swift ps1-macos/Sources/PS1/DiscIdentity.swift ps1-macos/Sources/PS1/BiosIdentity.swift ps1-macos/Sources/PS1/FastBootSetting.swift ps1-macos/Sources/PS1/Ps1Core.swift ps1-macos/Sources/PS1/EmulatorViewModel.swift ps1-macos/Sources/PS1/Settings/SettingsCopy.swift ps1-macos/Sources/PS1/Settings/GeneralSettingsPane.swift ps1-macos/Tests/PS1Tests/FastBootSettingTests.swift
git commit -m "feat(macos): skip the startup logos, and identify a BIOS through the core"
```

---

### Task 6: Docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md**

- Quick commands, `zig build test` row: "22 test binaries: the 16 `unit_test_files`" → "23 test binaries: the 17 `unit_test_files`".
- Repository layout, under `ps1-core/src/`, after the `discid.zig` lines:
  ```
      bios.zig         the BIOS image as a host input: SHA-256 identification
                       and the fast-boot patch (DuckStation's Type 1B, no fallback)
  ```
- The `tests/` line: add `bios` to the unit list and change "all 16" to "all 17".
- Rules that must not be broken, a new heading before **Savestates**:
  ```
  **BIOS** (`bios.zig`)

  - **The savestate identity hashes the ORIGINAL BIOS.** A fast-boot patch is
    host configuration, recorded in `Bus.bios_patch` and never in a state, so
    a state resumes with the setting on or off.
  - **Fast boot patches only a UNIQUE pattern match**, never DuckStation's
    fixed `0x18000` fallback: that offset is safe only behind a hash table
    vouching for the image, and a full boot is never wrong.
  ```

- [ ] **Step 2: Final gates**

```bash
zig build test
zig build trace-golden -Doptimize=ReleaseFast -- verify
zig build trace-golden -Doptimize=ReleaseFast -- savestate
```

Expected: all green. (The Swift suite already ran in Task 5.)

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: fast boot and BIOS identification in CLAUDE.md"
```
