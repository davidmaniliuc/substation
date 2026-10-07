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

// The five real rows are pinned by `BiosIdentityTests.swift` against the
// repo's images, through the C ABI; this is the unlisted case.
test "identify names an image outside the table as nothing" {
    const image = try plantedImage(&.{});
    defer std.testing.allocator.destroy(image);

    try expect(bios.identify(image) == null);
}

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

fn rowFor(model: []const u8) ?bios.Row {
    for (bios.table) |row| {
        for (row.models) |m| if (std.mem.eql(u8, m, model)) return row;
    }
    return null;
}

test "the table holds DuckStation's 24 PS1 images and none of its PS2 ones" {
    try expectEqual(@as(usize, 24), bios.table.len);
    for (bios.table) |row| {
        try expectEqual(@as(usize, 32), row.md5.len);
        try expect(!std.mem.startsWith(u8, row.description, "PS2"));
        try expect(row.models.len > 0);
    }
}

test "a model list expands the aliases a description abbreviates" {
    const eu = rowFor("SCPH-7502") orelse return error.Missing;
    try std.testing.expectEqualStrings("SCPH-7002", eu.models[0]);
    try std.testing.expectEqualStrings("SCPH-9002", eu.models[2]);
    try expectEqual(bios.Region.europe, eu.region);

    const us = rowFor("DTL-H3001") orelse return error.Missing;
    try std.testing.expectEqualStrings("SCPH-1001, 5003, DTL-H1201, H3001 (v2.2 12-04-95 A)", us.description);
    try std.testing.expectEqualStrings("SCPH-5003", us.models[1]);
    try std.testing.expectEqualStrings("2.2", us.version);
}
