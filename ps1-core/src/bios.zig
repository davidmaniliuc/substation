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
