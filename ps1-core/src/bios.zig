//! The BIOS image as a host input: what it is, and what fast boot does to it.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Md5 = std.crypto.hash.Md5;
const Bus = @import("memory.zig").Bus;

pub const image_bytes: usize = 512 * 1024;

pub const Region = enum { japan, america, europe };

/// One known image. The rows are generated data in `resources/bios_table.zon`
/// (`gen_bios_table.py`, from DuckStation's 0BSD table): never hand-edited.
pub const Row = struct {
    /// The MD5 of the whole image, lowercase hex: DuckStation's key.
    md5: []const u8,
    /// "SCPH-7002, 7502, 9002 (v4.1 12-16-97 E)", as DuckStation names it.
    description: []const u8,
    version: []const u8,
    region: Region,
    /// Every model the image shipped in, aliases expanded:
    /// SCPH-7002, SCPH-7502, SCPH-9002.
    models: []const []const u8,
};

/// The 24 PS1 images DuckStation knows: every retail revision and the DTL
/// development units. Its PS2 rows hash a 4 MB image and are left out.
pub const table: []const Row = @import("resources/bios_table.zon");

/// Identifies an image by content. Null means "not in the table":
/// UNIDENTIFIED, never invalid. MD5, because that is what the table is keyed
/// on; the savestate identity is a separate SHA-256.
pub fn identify(image: *const [image_bytes]u8) ?Row {
    var digest: [Md5.digest_length]u8 = undefined;
    Md5.hash(image, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    for (table) |row| {
        if (std.mem.eql(u8, &hex, row.md5)) return row;
    }
    return null;
}

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

/// Puts `image` in the bus's ROM, patched for fast boot when asked and when
/// the image is one the patch recognises.
pub fn install(bus: *Bus, image: *const [image_bytes]u8, fast_boot: bool) void {
    @memcpy(&bus.bios, image);
    bus.bios_patch = if (fast_boot) patchFastBoot(&bus.bios) else null;
    // A block engine compiles ROM like any other code and never sees a store
    // to it, so blocks built from the old bytes must go.
    if (bus.blocks) |c| c.flush();
}
