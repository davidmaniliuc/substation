//! The CHD v5 hunk map. Each hunk's compression type is Huffman-coded (with
//! run-length and "same as last self-reference" pseudo-types), then lengths,
//! CRCs and self-reference targets follow as packed bit fields. A CRC16 over
//! the decoded 12-byte records guards the whole map.
const std = @import("std");
const BitReader = @import("bitstream.zig").BitReader;
const chd = @import("chd.zig");

const Crc16 = std.hash.crc.@"CRC-16/IBM-3740";

pub const Kind = enum(u8) { codec0 = 0, codec1 = 1, codec2 = 2, codec3 = 3, none = 4, self = 5 };

pub const Entry = struct {
    kind: Kind,
    length: u32,
    /// A byte offset into the file, or the target hunk number for `.self`.
    offset: u64,
    crc: u16,
};

const parent = 6;
const rle_small = 7;
const rle_large = 8;
const self_0 = 9;
const self_1 = 10;
const parent_self = 11;
const parent_0 = 12;
const parent_1 = 13;

const map_header_bytes = 16;
const record_bytes = 12;

pub fn decode(gpa: std.mem.Allocator, file: []const u8, map_offset: u64, hunk_count: u32, hunk_bytes: u32) chd.Error![]Entry {
    if (map_offset > file.len or file.len - map_offset < map_header_bytes) return error.BadMap;
    const head = file[@intCast(map_offset)..][0..map_header_bytes];
    const map_bytes = std.mem.readInt(u32, head[0..4], .big);
    const first_offset = std.mem.readInt(u48, head[4..10], .big);
    const map_crc = std.mem.readInt(u16, head[10..12], .big);
    const length_bits = head[12];
    const self_bits = head[13];
    if (length_bits > 32 or self_bits > 32 or head[14] > 32) return error.BadMap;
    const start = map_offset + map_header_bytes;
    if (file.len - start < map_bytes) return error.BadMap;
    var br = BitReader.init(file[@intCast(start)..][0..map_bytes]);

    const huffman = try Huffman.importRle(&br);
    const kinds = try gpa.alloc(u8, hunk_count);
    defer gpa.free(kinds);
    var last: u8 = 0;
    var repeat: u32 = 0;
    for (kinds) |*k| {
        if (br.overflow) return error.BadMap;
        if (repeat > 0) {
            k.* = last;
            repeat -= 1;
            continue;
        }
        const v = try huffman.decodeOne(&br);
        if (v == rle_small) {
            k.* = last;
            repeat = 2 + @as(u32, try huffman.decodeOne(&br));
        } else if (v == rle_large) {
            k.* = last;
            repeat = 2 + 16 + (@as(u32, try huffman.decodeOne(&br)) << 4);
            repeat += try huffman.decodeOne(&br);
        } else {
            last = v;
            k.* = v;
        }
    }

    const entries = try gpa.alloc(Entry, hunk_count);
    errdefer gpa.free(entries);
    var crc = Crc16.init();
    var cursor: u64 = first_offset;
    var last_self: u64 = 0;
    for (kinds, entries) |k, *e| {
        if (br.overflow) return error.BadMap;
        e.* = switch (k) {
            0...3 => blk: {
                const length = br.read(@intCast(length_bits));
                const entry = Entry{ .kind = @fromBackingInt(@intCast(k)), .length = length, .offset = cursor, .crc = @intCast(br.read(16)) };
                cursor +%= length;
                break :blk entry;
            },
            @backingInt(Kind.none) => blk: {
                const entry = Entry{ .kind = .none, .length = hunk_bytes, .offset = cursor, .crc = @intCast(br.read(16)) };
                cursor +%= hunk_bytes;
                break :blk entry;
            },
            @backingInt(Kind.self), self_0, self_1 => blk: {
                if (k == @backingInt(Kind.self)) last_self = br.read(@intCast(self_bits));
                if (k == self_1) last_self += 1;
                break :blk .{ .kind = .self, .length = 0, .offset = last_self, .crc = 0 };
            },
            parent, parent_self, parent_0, parent_1 => return error.ParentChd,
            else => return error.BadMap,
        };
        var record: [record_bytes]u8 = undefined;
        record[0] = @backingInt(e.kind);
        std.mem.writeInt(u24, record[1..4], @truncate(e.length), .big);
        std.mem.writeInt(u48, record[4..10], @truncate(e.offset), .big);
        std.mem.writeInt(u16, record[10..12], e.crc, .big);
        crc.update(&record);
    }
    if (br.overflow or crc.final() != map_crc) return error.BadMap;
    return entries;
}

/// The map's 16-symbol, 8-bit-maximum Huffman code, with its code lengths
/// stored run-length encoded and the codes themselves canonical.
const Huffman = struct {
    const codes = 16;
    const max_bits = 8;
    const Slot = struct { value: u8 = 0, bits: u8 = 0 };

    lookup: [1 << max_bits]Slot = @splat(.{}),

    fn importRle(br: *BitReader) chd.Error!Huffman {
        var lengths: [codes]u8 = @splat(0);
        var n: usize = 0;
        while (n < codes) {
            const bits: u8 = @intCast(br.read(4));
            if (bits != 1) {
                lengths[n] = bits;
                n += 1;
                continue;
            }
            const next: u8 = @intCast(br.read(4));
            if (next == 1) {
                lengths[n] = 1;
                n += 1;
                continue;
            }
            const run: usize = @as(usize, br.read(4)) + 3;
            if (n + run > codes) return error.BadMap;
            @memset(lengths[n..][0..run], next);
            n += run;
        }

        // Canonical codes, assigned from the longest length down.
        var start_of: [33]u32 = @splat(0);
        for (lengths) |l| {
            if (l > max_bits) return error.BadMap;
            start_of[l] += 1;
        }
        var start: u32 = 0;
        var len: usize = 32;
        while (len > 0) : (len -= 1) {
            const next_start = (start + start_of[len]) >> 1;
            if (len != 1 and next_start * 2 != start + start_of[len]) return error.BadMap;
            start_of[len] = start;
            start = next_start;
        }

        var h = Huffman{};
        for (lengths, 0..) |l, value| {
            if (l == 0) continue;
            const code = start_of[l];
            start_of[l] += 1;
            const shift: u3 = @intCast(max_bits - l);
            const first = @as(usize, code) << shift;
            const count = @as(usize, 1) << shift;
            if (first + count > h.lookup.len) return error.BadMap;
            @memset(h.lookup[first..][0..count], .{ .value = @intCast(value), .bits = l });
        }
        return h;
    }

    fn decodeOne(self: *const Huffman, br: *BitReader) chd.Error!u8 {
        const slot = self.lookup[br.peek(max_bits)];
        if (slot.bits == 0) return error.BadMap;
        br.skip(slot.bits);
        return slot.value;
    }
};
