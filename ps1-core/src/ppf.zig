//! PPF, the PlayStation Patch Format: byte runs to write over a disc image.
//! Fan translations and fix patches ship as a `.ppf` beside an untouched rip.
//!
//! A patch is applied once, at load, into an `Overlay`: a private copy of
//! every sector it touches, sorted by LBA. `Disc.readSector2352` serves those
//! from the overlay and everything else from its `Source`, so the image is
//! never written to (a flat image is borrowed and a CHD is never whole) and
//! nothing above `disc.zig` knows a patch is there.

const std = @import("std");
const constants = @import("constants.zig");
const Disc = @import("disc.zig").Disc;

const sector_bytes = constants.sector_bytes;

pub const Error = error{ PpfBadFormat, PpfMismatch, OutOfMemory };

/// The 56 bytes every version opens with: "PPF" + version digit + "0", an
/// encoding byte, and a 50-byte description.
const common_header = 56;
/// PPF2's original image size (u32), then its 1024-byte blockcheck.
const v2_records = common_header + 4 + blockcheck_bytes;
/// PPF3's image type, blockcheck flag, undo flag and a pad byte.
const v3_fields = common_header + 4;
/// Every version that has a blockcheck copies these bytes of the image at
/// byte 0x9320, which is sector 16 (the primary volume descriptor) + 32.
const blockcheck_bytes = 1024;
const blockcheck_lba = 16;
const blockcheck_skip = 32;
/// A FILE_ID.DIZ trailer: "@BEGIN_FILE_ID.DIZ", the text,
/// "@END_FILE_ID.DIZ", then the text's length (u32 in PPF2, u16 in PPF3).
const diz_begin = "@BEGIN_FILE_ID.DIZ";
const diz_end = "@END_FILE_ID.DIZ";

pub const Overlay = struct {
    /// Ascending; `sectors[i]` is the patched copy of `lbas[i]`.
    lbas: []const i32 = &.{},
    sectors: []const [sector_bytes]u8 = &.{},
    /// Names the patched content for a savestate's identity; 0 is unpatched.
    fingerprint: u64 = 0,

    pub fn find(self: Overlay, lba: i32) ?*const [sector_bytes]u8 {
        const i = std.sort.binarySearch(i32, self.lbas, lba, orderLba) orelse return null;
        return &self.sectors[i];
    }

    pub fn deinit(self: Overlay, gpa: std.mem.Allocator) void {
        gpa.free(self.lbas);
        gpa.free(self.sectors);
    }
};

fn orderLba(key: i32, item: i32) std.math.Order {
    return std.math.order(key, item);
}

/// The fixed fields of one version, decoded from the header.
const Layout = struct {
    offset_bytes: u8,
    records: []const u8,
    blockcheck: ?*const [blockcheck_bytes]u8,
    undo: bool,
};

/// Parses `bytes` and builds its overlay against `d`, which must carry no
/// patch of its own. Refuses a patch made for another image rather than
/// corrupting this one quietly.
pub fn build(gpa: std.mem.Allocator, d: Disc, bytes: []const u8) Error!Overlay {
    std.debug.assert(d.patch.lbas.len == 0);
    const layout = try parse(bytes);
    if (layout.blockcheck) |want| {
        var raw: [sector_bytes]u8 = undefined;
        if (!d.readSector2352(blockcheck_lba, &raw)) return error.PpfMismatch;
        if (!std.mem.eql(u8, raw[blockcheck_skip..][0..blockcheck_bytes], want)) return error.PpfMismatch;
    }

    var work = Work{ .gpa = gpa, .disc = d };
    defer work.deinit();
    var rest = layout.records;
    while (rest.len > 0) {
        if (rest.len < layout.offset_bytes + 1) return error.PpfBadFormat;
        const offset: u64 = switch (layout.offset_bytes) {
            4 => std.mem.readInt(u32, rest[0..4], .little),
            else => std.mem.readInt(u64, rest[0..8], .little),
        };
        const len = rest[layout.offset_bytes];
        rest = rest[layout.offset_bytes + 1 ..];
        const record_bytes: usize = if (layout.undo) @as(usize, len) * 2 else len;
        if (rest.len < record_bytes) return error.PpfBadFormat;
        const undo = if (layout.undo) rest[len..][0..len] else null;
        try work.apply(offset, rest[0..len], undo);
        rest = rest[record_bytes..];
    }
    return work.finish();
}

fn parse(bytes: []const u8) Error!Layout {
    if (bytes.len < common_header or !std.mem.eql(u8, bytes[0..3], "PPF") or bytes[4] != '0')
        return error.PpfBadFormat;
    switch (bytes[3]) {
        '1' => return .{ .offset_bytes = 4, .records = bytes[common_header..], .blockcheck = null, .undo = false },
        '2' => {
            if (bytes.len < v2_records) return error.PpfBadFormat;
            const end = try recordsEnd(bytes, u32, v2_records);
            return .{
                .offset_bytes = 4,
                .records = bytes[v2_records..end],
                .blockcheck = bytes[common_header + 4 ..][0..blockcheck_bytes],
                .undo = false,
            };
        },
        '3' => {
            if (bytes.len < v3_fields) return error.PpfBadFormat;
            // Image type 0 is a BIN; 1 is a PrimoDVD GI file, whose sectors
            // do not sit where a bin's do.
            if (bytes[common_header] != 0) return error.PpfBadFormat;
            const has_blockcheck = bytes[common_header + 1] != 0;
            const start: usize = if (has_blockcheck) v3_fields + blockcheck_bytes else v3_fields;
            if (bytes.len < start) return error.PpfBadFormat;
            const end = try recordsEnd(bytes, u16, start);
            return .{
                .offset_bytes = 8,
                .records = bytes[start..end],
                .blockcheck = if (has_blockcheck) bytes[v3_fields..][0..blockcheck_bytes] else null,
                .undo = bytes[common_header + 2] != 0,
            };
        },
        else => return error.PpfBadFormat,
    }
}

/// Where the records stop: the end of the file, or the start of a
/// FILE_ID.DIZ trailer whose length field is a `Len`.
fn recordsEnd(bytes: []const u8, comptime Len: type, start: usize) Error!usize {
    const tail = @sizeOf(Len) + 4;
    if (bytes.len < start + tail or !std.mem.eql(u8, bytes[bytes.len - tail ..][0..4], ".DIZ")) return bytes.len;
    const text_len = std.mem.readInt(Len, bytes[bytes.len - @sizeOf(Len) ..][0..@sizeOf(Len)], .little);
    const trailer = diz_begin.len + @as(usize, text_len) + diz_end.len + @sizeOf(Len);
    if (bytes.len < start + trailer) return error.PpfBadFormat;
    return bytes.len - trailer;
}

/// The overlay while records are still landing: sectors in first-touch order,
/// indexed by LBA.
const Work = struct {
    gpa: std.mem.Allocator,
    disc: Disc,
    index: std.AutoHashMapUnmanaged(i32, u32) = .empty,
    sectors: std.ArrayList([sector_bytes]u8) = .empty,

    fn deinit(self: *Work) void {
        self.index.deinit(self.gpa);
        self.sectors.deinit(self.gpa);
    }

    fn apply(self: *Work, start: u64, data: []const u8, undo: ?[]const u8) Error!void {
        const count: u64 = @intCast(self.disc.sectorCount());
        var done: usize = 0;
        while (done < data.len) {
            const at = start + done;
            const lba = at / sector_bytes;
            if (lba >= count) return;
            const within: usize = @intCast(at % sector_bytes);
            const n = @min(data.len - done, sector_bytes - within);
            const sector = try self.touch(@intCast(lba));
            const target = sector[within..][0..n];
            if (undo) |u| if (!std.mem.eql(u8, u[done..][0..n], target)) return error.PpfMismatch;
            @memcpy(target, data[done..][0..n]);
            done += n;
        }
    }

    fn touch(self: *Work, lba: i32) Error!*[sector_bytes]u8 {
        const slot = try self.index.getOrPut(self.gpa, lba);
        if (!slot.found_existing) {
            slot.value_ptr.* = @intCast(self.sectors.items.len);
            const copy = try self.sectors.addOne(self.gpa);
            if (!self.disc.readSector2352(lba, copy)) copy.* = @splat(0);
        }
        return &self.sectors.items[slot.value_ptr.*];
    }

    fn finish(self: *Work) Error!Overlay {
        const n = self.sectors.items.len;
        if (n == 0) return .{};
        const lbas = try self.gpa.alloc(i32, n);
        errdefer self.gpa.free(lbas);
        const sectors = try self.gpa.alloc([sector_bytes]u8, n);
        errdefer self.gpa.free(sectors);

        var it = self.index.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) lbas[i] = e.key_ptr.*;
        std.mem.sort(i32, lbas, {}, std.sort.asc(i32));

        var hash = std.hash.Wyhash.init(0);
        for (lbas, sectors) |lba, *dst| {
            dst.* = self.sectors.items[self.index.get(lba).?];
            hash.update(std.mem.asBytes(&lba));
            hash.update(dst);
        }
        // Bit 0 forced on: 0 is reserved for "unpatched".
        return .{ .lbas = lbas, .sectors = sectors, .fingerprint = hash.final() | 1 };
    }
};
