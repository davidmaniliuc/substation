//! ECM images: a raw `.bin` with every sector's rebuildable bytes (sync,
//! address, EDC, parity) stripped. The stream decodes to the original image
//! BYTE for byte; a Mode 2 sector is usually two chunks, its 16 sync/header
//! bytes raw and then a header-less record, so a sector is read by decoded
//! offset, never by chunk. See `Reader`.
const std = @import("std");
const sector = @import("sector.zig");
const sector_bytes = @import("constants.zig").sector_bytes;

const magic = "ECM\x00";
/// A header's count is 32 bits; this one ends the stream.
const terminator = 0xFFFFFFFF;
const max_count = 0x80000000;
/// One checkpoint per this many chunk headers.
const checkpoint_every = 64;

pub fn isEcm(data: []const u8) bool {
    return std.mem.startsWith(u8, data, magic);
}

const ChunkType = enum(u2) {
    /// One record of `count` bytes, stored as-is.
    raw,
    /// A whole Mode 1 sector from its address and 2048 data bytes.
    mode1,
    /// A Mode 2 Form 1 sector from 0x10, from its subheader and 2048 bytes.
    form1,
    /// A Mode 2 Form 2 sector from 0x10, from its subheader and 2324 bytes.
    form2,

    /// Bytes one record decodes to.
    fn decodedBytes(self: ChunkType) u64 {
        return switch (self) {
            .raw => 1,
            .mode1 => sector_bytes,
            .form1, .form2 => sector_bytes - 0x10,
        };
    }

    /// Bytes one record is stored as.
    fn storedBytes(self: ChunkType) u64 {
        return switch (self) {
            .raw => 1,
            .mode1 => 3 + 0x800,
            .form1 => 4 + 0x800,
            .form2 => 4 + 0x914,
        };
    }
};

/// Where a chunk header sits in the file and in the decoded image.
const Checkpoint = struct { decoded: u64, file: u64 };

/// One parsed chunk; `null` from `parseChunk` is the terminator.
const Chunk = struct {
    type: ChunkType,
    count: u64,
    at: Checkpoint,
    /// File offset of its first record.
    records: u64,

    fn decodedLen(self: Chunk) u64 {
        return self.count * self.type.decodedBytes();
    }

    fn next(self: Chunk) Checkpoint {
        return .{
            .decoded = self.at.decoded + self.decodedLen(),
            .file = self.records + self.count * self.type.storedBytes(),
        };
    }
};

/// Reads an ECM image in place, indexed lazily: a checkpoint at every 64th
/// chunk header, extended only as far as a read or `sectorCount` walks.
pub const Reader = struct {
    gpa: std.mem.Allocator,
    data: []const u8,
    checkpoints: std.ArrayList(Checkpoint),
    /// The next chunk header no walk has reached yet, and its index.
    frontier: Checkpoint,
    frontier_index: u64,
    /// How the walk ended: at the terminator with a whole number of sectors,
    /// or at a fault. `frontier.decoded` is then every byte that decodes.
    end: ?enum { complete, broken } = null,

    pub fn open(gpa: std.mem.Allocator, data: []const u8) error{ OutOfMemory, BadEcm }!*Reader {
        if (!isEcm(data)) return error.BadEcm;
        const self = try gpa.create(Reader);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .data = data,
            .checkpoints = .empty,
            .frontier = .{ .decoded = 0, .file = magic.len },
            .frontier_index = 0,
        };
        errdefer self.checkpoints.deinit(gpa);
        try self.advance();
        // An image that decodes to nothing is not a disc.
        if (self.end == .broken or self.frontier.decoded == 0) return error.BadEcm;
        return self;
    }

    pub fn close(self: *Reader) void {
        const gpa = self.gpa;
        self.checkpoints.deinit(gpa);
        gpa.destroy(self);
    }

    /// Whole sectors in the image. Walks the stream once, on first call.
    pub fn sectorCount(self: *Reader) i32 {
        while (self.end == null) self.advance() catch break;
        return @intCast(@min(self.frontier.decoded / sector_bytes, std.math.maxInt(i32)));
    }

    pub fn readSector(self: *Reader, lba: i32, out: *[sector_bytes]u8) bool {
        if (lba < 0) return false;
        const offset = @as(u64, @intCast(lba)) * sector_bytes;
        while (self.end == null and self.frontier.decoded < offset + sector_bytes) {
            self.advance() catch return false;
        }
        if (self.frontier.decoded < offset + sector_bytes) return false;
        self.copyDecoded(offset, out);
        return true;
    }

    /// Walks one chunk past the frontier, recording a checkpoint at its
    /// header when it is due one.
    fn advance(self: *Reader) error{OutOfMemory}!void {
        if (self.frontier_index % checkpoint_every == 0) try self.checkpoints.append(self.gpa, self.frontier);
        const chunk = parseChunk(self.data, self.frontier) catch {
            self.end = .broken;
            return;
        } orelse {
            self.end = if (self.frontier.decoded % sector_bytes == 0) .complete else .broken;
            return;
        };
        self.frontier = chunk.next();
        self.frontier_index += 1;
    }

    /// Fills `out` from decoded byte `offset`; every byte of it lies before
    /// the frontier, so every chunk on the way has been validated.
    fn copyDecoded(self: *Reader, offset: u64, out: []u8) void {
        var chunk = self.checkpointBefore(offset);
        var pos = offset;
        var filled: usize = 0;
        var scratch: [sector_bytes]u8 = undefined;
        while (filled < out.len) {
            // A count is at least one, so no chunk is empty: the first whose
            // range passes `pos` holds it.
            while (pos >= chunk.next().decoded) chunk = validated(self.data, chunk.next());
            const rel = pos - chunk.at.decoded;
            const record = rel / chunk.type.decodedBytes();
            const within = rel % chunk.type.decodedBytes();
            const stored = self.data[chunk.records + record * chunk.type.storedBytes() ..];
            const decoded: []const u8 = if (chunk.type == .raw)
                stored[0 .. chunk.count - record]
            else
                decodeRecord(chunk.type, stored, &scratch);
            const n = @min(out.len - filled, decoded.len - within);
            @memcpy(out[filled..][0..n], decoded[within..][0..n]);
            filled += n;
            pos += n;
        }
    }

    /// The chunk at the last checkpoint at or before decoded byte `offset`.
    fn checkpointBefore(self: *Reader, offset: u64) Chunk {
        const items = self.checkpoints.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].decoded <= offset) lo = mid else hi = mid;
        }
        return validated(self.data, items[lo]);
    }
};

/// A chunk behind the frontier, which `advance` has already parsed.
fn validated(data: []const u8, at: Checkpoint) Chunk {
    return (parseChunk(data, at) catch unreachable).?;
}

/// The chunk whose header is at `at`, or null for the terminator. A header or
/// record running past the end of `data` is `BadEcm`.
fn parseChunk(data: []const u8, at: Checkpoint) error{BadEcm}!?Chunk {
    var pos = at.file;
    if (pos >= data.len) return error.BadEcm;
    var b = data[pos];
    pos += 1;
    const kind: ChunkType = @fromBackingInt(@intCast(b & 3));
    var count: u64 = (b >> 2) & 0x1F;
    var shift: u6 = 5;
    while (b & 0x80 != 0) {
        if (pos >= data.len or shift > 32) return error.BadEcm;
        b = data[pos];
        pos += 1;
        count |= @as(u64, b & 0x7F) << shift;
        shift += 7;
    }
    if (count == terminator) return null;
    count += 1;
    if (count >= max_count) return error.BadEcm;
    const chunk: Chunk = .{ .type = kind, .count = count, .at = at, .records = pos };
    if (chunk.next().file > data.len) return error.BadEcm;
    return chunk;
}

/// Rebuilds one typed record into `scratch` and returns the bytes it decodes
/// to: the whole sector for Mode 1, from 0x10 on for Mode 2.
fn decodeRecord(kind: ChunkType, stored: []const u8, scratch: *[sector_bytes]u8) []const u8 {
    @memset(scratch, 0);
    scratch[0..sector.sync_pattern.len].* = sector.sync_pattern;
    switch (kind) {
        .raw => unreachable,
        .mode1 => {
            scratch[15] = 1;
            @memcpy(scratch[0x0C..0x0F], stored[0..3]);
            @memcpy(scratch[0x10..0x810], stored[3..][0..0x800]);
            putEdc(scratch, 0, 0x810);
            sector.writeEcc(scratch);
            return scratch;
        },
        .form1, .form2 => {
            // The mode byte excludes the (zero) header from the parity.
            scratch[15] = 2;
            const n: usize = if (kind == .form1) 0x804 else 0x918;
            @memcpy(scratch[0x14..][0..n], stored[0..n]);
            scratch[0x10..0x14].* = scratch[0x14..0x18].*;
            if (kind == .form1) {
                putEdc(scratch, 0x10, 0x818);
                sector.writeEcc(scratch);
            } else {
                putEdc(scratch, 0x10, 0x92C);
            }
            return scratch[0x10..];
        },
    }
}

fn putEdc(s: *[sector_bytes]u8, from: usize, at: usize) void {
    std.mem.writeInt(u32, s[at..][0..4], sector.edc(s[from..at]), .little);
}
