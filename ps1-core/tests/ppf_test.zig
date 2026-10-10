const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const ps1_core = @import("ps1_core");
const ppf = ps1_core.ppf;
const Disc = ps1_core.disc.Disc;

const gpa = std.testing.allocator;
const sector_bytes = 2352;
const sector_count = 24;
const blockcheck_offset = 16 * sector_bytes + 32;
const blockcheck_bytes = 1024;

/// A flat image whose every byte is a function of its position, so a test can
/// say what an unpatched byte holds without keeping a copy.
fn makeImage() ![]u8 {
    const image = try gpa.alloc(u8, sector_count * sector_bytes);
    for (image, 0..) |*b, i| b.* = @truncate(i *% 7 +% i / 251);
    return image;
}

const Record = struct { offset: u64, data: []const u8, undo: ?[]const u8 = null };

const V3 = struct {
    blockcheck: ?[]const u8 = null,
    undo: bool = false,
    image_type: u8 = 0,
};

/// Writes a patch file: the 56-byte header every version shares, the
/// version's own fields, the records and, when `diz` is given, a FILE_ID.DIZ
/// trailer.
const Builder = struct {
    out: std.ArrayList(u8) = .empty,

    fn deinit(self: *Builder) void {
        self.out.deinit(gpa);
    }

    fn header(self: *Builder, version: u8) !void {
        try self.out.appendSlice(gpa, &.{ 'P', 'P', 'F', '0' + version, '0', version - 1 });
        var desc: [50]u8 = @splat(' ');
        @memcpy(desc[0..9], "test hack");
        try self.out.appendSlice(gpa, &desc);
    }

    fn int(self: *Builder, comptime T: type, v: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        try self.out.appendSlice(gpa, &buf);
    }

    fn records(self: *Builder, comptime Offset: type, list: []const Record) !void {
        for (list) |r| {
            try self.int(Offset, @intCast(r.offset));
            try self.out.append(gpa, @intCast(r.data.len));
            try self.out.appendSlice(gpa, r.data);
            if (r.undo) |u| try self.out.appendSlice(gpa, u);
        }
    }

    fn diz(self: *Builder, comptime Len: type, text: []const u8) !void {
        try self.out.appendSlice(gpa, "@BEGIN_FILE_ID.DIZ");
        try self.out.appendSlice(gpa, text);
        try self.out.appendSlice(gpa, "@END_FILE_ID.DIZ");
        try self.int(Len, @intCast(text.len));
    }

    fn v1(list: []const Record) !Builder {
        var b = Builder{};
        try b.header(1);
        try b.records(u32, list);
        return b;
    }

    fn v2(image: []const u8, list: []const Record, diz_text: ?[]const u8) !Builder {
        var b = Builder{};
        try b.header(2);
        try b.int(u32, @intCast(image.len));
        try b.out.appendSlice(gpa, image[blockcheck_offset..][0..blockcheck_bytes]);
        try b.records(u32, list);
        if (diz_text) |t| try b.diz(u32, t);
        return b;
    }

    fn v3(opts: V3, list: []const Record, diz_text: ?[]const u8) !Builder {
        var b = Builder{};
        try b.header(3);
        try b.out.appendSlice(gpa, &.{ opts.image_type, @intFromBool(opts.blockcheck != null), @intFromBool(opts.undo), 0 });
        if (opts.blockcheck) |block| try b.out.appendSlice(gpa, block);
        try b.records(u64, list);
        if (diz_text) |t| try b.diz(u16, t);
        return b;
    }
};

fn readLba(d: Disc, lba: i32) ![sector_bytes]u8 {
    var raw: [sector_bytes]u8 = undefined;
    try expect(d.readSector2352(lba, &raw));
    return raw;
}

/// The image as `list` should leave it, written by the obvious method.
fn patchedCopy(image: []const u8, list: []const Record) ![]u8 {
    const copy = try gpa.dupe(u8, image);
    for (list) |r| {
        if (r.offset >= copy.len) continue;
        const n = @min(r.data.len, copy.len - r.offset);
        @memcpy(copy[r.offset..][0..n], r.data[0..n]);
    }
    return copy;
}

/// Attaches `patch` to a disc over `image` and checks every sector against the
/// image patched byte for byte.
fn expectAppliesAs(image: []const u8, patch: []const u8, list: []const Record) !void {
    var d = Disc.init(image);
    const overlay = try ppf.build(gpa, d, patch);
    defer overlay.deinit(gpa);
    d.patch = overlay;

    const want = try patchedCopy(image, list);
    defer gpa.free(want);
    for (0..sector_count) |lba| {
        const got = try readLba(d, @intCast(lba));
        try expectEqualSlices(u8, want[lba * sector_bytes ..][0..sector_bytes], &got);
    }
}

test "a PPF1 record replaces the bytes it covers and nothing else" {
    const image = try makeImage();
    defer gpa.free(image);
    const list = [_]Record{.{ .offset = 3 * sector_bytes + 100, .data = "HELLO" }};
    var b = try Builder.v1(&list);
    defer b.deinit();
    try expectAppliesAs(image, b.out.items, &list);
}

test "the overlay holds only the sectors a patch touches" {
    const image = try makeImage();
    defer gpa.free(image);
    const list = [_]Record{
        .{ .offset = 9 * sector_bytes, .data = "B" },
        .{ .offset = 2 * sector_bytes, .data = "A" },
    };
    var b = try Builder.v1(&list);
    defer b.deinit();
    const overlay = try ppf.build(gpa, Disc.init(image), b.out.items);
    defer overlay.deinit(gpa);
    try expectEqualSlices(i32, &.{ 2, 9 }, overlay.lbas);
    try expectEqual(@as(usize, 2), overlay.sectors.len);
}

test "a record crossing a sector boundary is split across both sectors" {
    const image = try makeImage();
    defer gpa.free(image);
    const list = [_]Record{.{ .offset = 5 * sector_bytes - 3, .data = "abcdefgh" }};
    var b = try Builder.v1(&list);
    defer b.deinit();
    try expectAppliesAs(image, b.out.items, &list);
}

test "overlapping records apply in file order" {
    const image = try makeImage();
    defer gpa.free(image);
    const list = [_]Record{
        .{ .offset = 7 * sector_bytes + 10, .data = "XXXXXXXX" },
        .{ .offset = 7 * sector_bytes + 12, .data = "yy" },
    };
    var b = try Builder.v1(&list);
    defer b.deinit();
    try expectAppliesAs(image, b.out.items, &list);
    const overlay = try ppf.build(gpa, Disc.init(image), b.out.items);
    defer overlay.deinit(gpa);
    try expectEqualSlices(u8, "XXyyXXXX", overlay.sectors[0][10..18]);
}

test "a record past the end of the image is ignored" {
    const image = try makeImage();
    defer gpa.free(image);
    const list = [_]Record{
        .{ .offset = sector_count * sector_bytes + 5, .data = "gone" },
        .{ .offset = 1 * sector_bytes, .data = "kept" },
    };
    var b = try Builder.v1(&list);
    defer b.deinit();
    try expectAppliesAs(image, b.out.items, &list);
}

test "a PPF2 whose blockcheck matches the image applies" {
    const image = try makeImage();
    defer gpa.free(image);
    const list = [_]Record{.{ .offset = 20 * sector_bytes + 2000, .data = "v2" }};
    var b = try Builder.v2(image, &list, null);
    defer b.deinit();
    try expectAppliesAs(image, b.out.items, &list);
}

test "a PPF2 made against a different image is refused" {
    const image = try makeImage();
    defer gpa.free(image);
    const other = try gpa.dupe(u8, image);
    defer gpa.free(other);
    other[blockcheck_offset + 512] ^= 0xFF;
    var b = try Builder.v2(other, &.{.{ .offset = 0, .data = "x" }}, null);
    defer b.deinit();
    try expectError(error.PpfMismatch, ppf.build(gpa, Disc.init(image), b.out.items));
}

test "a FILE_ID.DIZ trailer is never read as records" {
    const image = try makeImage();
    defer gpa.free(image);
    const list = [_]Record{.{ .offset = 4 * sector_bytes, .data = "diz" }};

    var b2 = try Builder.v2(image, &list, "a patch by somebody\r\n");
    defer b2.deinit();
    try expectAppliesAs(image, b2.out.items, &list);

    var b3 = try Builder.v3(.{}, &list, "a patch by somebody\r\n");
    defer b3.deinit();
    try expectAppliesAs(image, b3.out.items, &list);
}

test "a PPF3 with 64-bit offsets and no blockcheck applies" {
    const image = try makeImage();
    defer gpa.free(image);
    const list = [_]Record{.{ .offset = 11 * sector_bytes + 7, .data = "three" }};
    var b = try Builder.v3(.{}, &list, null);
    defer b.deinit();
    try expectAppliesAs(image, b.out.items, &list);
}

test "a PPF3 blockcheck is checked when its flag is set" {
    const image = try makeImage();
    defer gpa.free(image);
    const list = [_]Record{.{ .offset = 0, .data = "ok" }};
    var good = try Builder.v3(.{ .blockcheck = image[blockcheck_offset..][0..blockcheck_bytes] }, &list, null);
    defer good.deinit();
    try expectAppliesAs(image, good.out.items, &list);

    const wrong: [blockcheck_bytes]u8 = @splat(0x5A);
    var bad = try Builder.v3(.{ .blockcheck = &wrong }, &list, null);
    defer bad.deinit();
    try expectError(error.PpfMismatch, ppf.build(gpa, Disc.init(image), bad.out.items));
}

test "PPF3 undo data must match the bytes it would restore" {
    const image = try makeImage();
    defer gpa.free(image);
    const at = 6 * sector_bytes - 2;
    const original = image[at..][0..4];
    const list = [_]Record{.{ .offset = at, .data = "undo", .undo = original }};
    var good = try Builder.v3(.{ .undo = true }, &list, null);
    defer good.deinit();
    try expectAppliesAs(image, good.out.items, &list);

    var bad = try Builder.v3(.{ .undo = true }, &.{.{ .offset = at, .data = "undo", .undo = "nope" }}, null);
    defer bad.deinit();
    try expectError(error.PpfMismatch, ppf.build(gpa, Disc.init(image), bad.out.items));
}

test "malformed patches are refused" {
    const image = try makeImage();
    defer gpa.free(image);
    const d = Disc.init(image);

    try expectError(error.PpfBadFormat, ppf.build(gpa, d, "PPF40\x03 not a version"));
    try expectError(error.PpfBadFormat, ppf.build(gpa, d, "PPF1"));

    var truncated = try Builder.v1(&.{.{ .offset = 0, .data = "abcdef" }});
    defer truncated.deinit();
    try expectError(error.PpfBadFormat, ppf.build(gpa, d, truncated.out.items[0 .. truncated.out.items.len - 2]));

    var gi = try Builder.v3(.{ .image_type = 1 }, &.{.{ .offset = 0, .data = "x" }}, null);
    defer gi.deinit();
    try expectError(error.PpfBadFormat, ppf.build(gpa, d, gi.out.items));
}

test "the fingerprint names the patched content" {
    const image = try makeImage();
    defer gpa.free(image);
    const d = Disc.init(image);
    try expectEqual(@as(u64, 0), (ppf.Overlay{}).fingerprint);

    var a = try Builder.v1(&.{.{ .offset = 100, .data = "same" }});
    defer a.deinit();
    var a3 = try Builder.v3(.{}, &.{.{ .offset = 100, .data = "same" }}, null);
    defer a3.deinit();
    var other = try Builder.v1(&.{.{ .offset = 100, .data = "diff" }});
    defer other.deinit();

    const oa = try ppf.build(gpa, d, a.out.items);
    defer oa.deinit(gpa);
    const oa3 = try ppf.build(gpa, d, a3.out.items);
    defer oa3.deinit(gpa);
    const ob = try ppf.build(gpa, d, other.out.items);
    defer ob.deinit(gpa);

    try expect(oa.fingerprint != 0);
    try expectEqual(oa.fingerprint, oa3.fingerprint);
    try expect(oa.fingerprint != ob.fingerprint);
}
