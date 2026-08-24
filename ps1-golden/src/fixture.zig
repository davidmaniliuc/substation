//! The .p1fx fixture format: a recorded GP0 command stream on disk, plus the
//! per-frame VRAM hash a consumer checks it against.
//!
//! Little-endian throughout, asserted rather than assumed.

const std = @import("std");
const ps1 = @import("ps1_core");

comptime {
    if (@import("builtin").cpu.arch.endian() != .little) {
        @compileError(".p1fx is little-endian; this target is not");
    }
}

/// FNV-1a 64.
///
/// Deliberately NOT `std.hash.Wyhash`, which state_hash.zig uses. Wyhash is a
/// standard-library implementation that may change across Zig releases, so a
/// FILE FORMAT pinned to it breaks silently on a toolchain upgrade — and the
/// failure presents as "Swift disagrees with Zig", the most confusing shape a
/// bridge bug can take. This is six lines in either language and frozen by
/// definition.
pub fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// The full 1024x512, as little-endian u16 in row-major order — not the
/// display window.
pub fn hashVram(v: *const ps1.gpu.Vram) u64 {
    return fnv1a(std.mem.sliceAsBytes(v.data[0..]));
}

const command = ps1.gpu.command;

pub const magic = "PS1FIXT\x00".*;
pub const version: u32 = 1;
pub const record_stride: u32 = @sizeOf(command.Command);
pub const kind_count: u32 = @typeInfo(command.Kind).@"enum".fields.len;
pub const header_bytes: usize = 48;
pub const frame_entry_bytes: usize = 24;

comptime {
    if (record_stride != 72) @compileError("Command stride changed; bump .p1fx version");
    if (kind_count != 17) @compileError("Kind count changed; bump .p1fx version and update ps1.h");
}

/// One frame's slice of the concatenated regions. `payload_off` is in WORDS.
pub const FrameEntry = struct {
    record_off: u32,
    record_count: u32,
    payload_off: u32,
    payload_count: u32,
    vram_hash: u64,
};

pub const ParseError = error{
    BadMagic,
    BadVersion,
    StrideMismatch,
    KindCountMismatch,
    Truncated,
    BadOffsets,
} || std.mem.Allocator.Error;

pub const Writer = struct {
    frames: std.ArrayList(FrameEntry),
    records: std.ArrayList(command.Command),
    payload: std.ArrayList(u32),

    pub const empty: Writer = .{
        .frames = .empty,
        .records = .empty,
        .payload = .empty,
    };

    pub fn deinit(self: *Writer, a: std.mem.Allocator) void {
        self.frames.deinit(a);
        self.records.deinit(a);
        self.payload.deinit(a);
    }

    /// Records are appended VERBATIM. A `vram_write_data` record's `.x` stays
    /// frame-relative and is never rebased — `command.replay` already reads it
    /// that way, and rebasing is arithmetic that two languages could disagree
    /// about.
    pub fn addFrame(self: *Writer, a: std.mem.Allocator, s: command.Stream, vram_hash: u64) !void {
        std.debug.assert(s.complete);
        try self.frames.append(a, .{
            .record_off = @intCast(self.records.items.len),
            .record_count = @intCast(s.records.len),
            .payload_off = @intCast(self.payload.items.len),
            .payload_count = @intCast(s.payload.len),
            .vram_hash = vram_hash,
        });
        try self.records.appendSlice(a, s.records);
        try self.payload.appendSlice(a, s.payload);
    }

    pub fn serialize(self: *const Writer, a: std.mem.Allocator) ![]u8 {
        const total = header_bytes +
            frame_entry_bytes * self.frames.items.len +
            @sizeOf(command.Command) * self.records.items.len +
            @sizeOf(u32) * self.payload.items.len;

        const out = try a.alloc(u8, total);
        errdefer a.free(out);

        @memcpy(out[0..8], &magic);
        std.mem.writeInt(u32, out[8..12], version, .little);
        std.mem.writeInt(u32, out[12..16], record_stride, .little);
        std.mem.writeInt(u32, out[16..20], kind_count, .little);
        std.mem.writeInt(u32, out[20..24], @intCast(self.frames.items.len), .little);
        std.mem.writeInt(u64, out[24..32], @intCast(self.records.items.len), .little);
        std.mem.writeInt(u64, out[32..40], @intCast(self.payload.items.len), .little);
        std.mem.writeInt(u64, out[40..48], 0, .little);

        var off: usize = header_bytes;
        for (self.frames.items) |f| {
            std.mem.writeInt(u32, out[off..][0..4], f.record_off, .little);
            std.mem.writeInt(u32, out[off..][4..8], f.record_count, .little);
            std.mem.writeInt(u32, out[off..][8..12], f.payload_off, .little);
            std.mem.writeInt(u32, out[off..][12..16], f.payload_count, .little);
            std.mem.writeInt(u64, out[off..][16..24], f.vram_hash, .little);
            off += frame_entry_bytes;
        }

        const rec_bytes = std.mem.sliceAsBytes(self.records.items);
        @memcpy(out[off .. off + rec_bytes.len], rec_bytes);
        off += rec_bytes.len;

        const pay_bytes = std.mem.sliceAsBytes(self.payload.items);
        @memcpy(out[off .. off + pay_bytes.len], pay_bytes);

        return out;
    }
};

pub const Parsed = struct {
    frames: []FrameEntry,
    records: []command.Command,
    payload: []u32,

    pub fn deinit(self: Parsed, a: std.mem.Allocator) void {
        a.free(self.frames);
        a.free(self.records);
        a.free(self.payload);
    }

    pub fn frameStream(self: Parsed, i: usize) command.Stream {
        const f = self.frames[i];
        return .{
            .records = self.records[f.record_off .. f.record_off + f.record_count],
            .payload = self.payload[f.payload_off .. f.payload_off + f.payload_count],
            .complete = true,
        };
    }
};

pub fn parse(a: std.mem.Allocator, bytes: []const u8) ParseError!Parsed {
    if (bytes.len < header_bytes) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &magic)) return error.BadMagic;
    if (std.mem.readInt(u32, bytes[8..12], .little) != version) return error.BadVersion;
    if (std.mem.readInt(u32, bytes[12..16], .little) != record_stride) return error.StrideMismatch;
    if (std.mem.readInt(u32, bytes[16..20], .little) != kind_count) return error.KindCountMismatch;

    const frame_count = std.mem.readInt(u32, bytes[20..24], .little);
    const total_records = std.mem.readInt(u64, bytes[24..32], .little);
    const total_payload = std.mem.readInt(u64, bytes[32..40], .little);

    const want = header_bytes +
        frame_entry_bytes * frame_count +
        @sizeOf(command.Command) * total_records +
        @sizeOf(u32) * total_payload;
    if (bytes.len != want) return error.Truncated;

    const frames = try a.alloc(FrameEntry, frame_count);
    errdefer a.free(frames);

    var off: usize = header_bytes;
    for (frames) |*f| {
        f.* = .{
            .record_off = std.mem.readInt(u32, bytes[off..][0..4], .little),
            .record_count = std.mem.readInt(u32, bytes[off..][4..8], .little),
            .payload_off = std.mem.readInt(u32, bytes[off..][8..12], .little),
            .payload_count = std.mem.readInt(u32, bytes[off..][12..16], .little),
            .vram_hash = std.mem.readInt(u64, bytes[off..][16..24], .little),
        };
        if (f.record_off + f.record_count > total_records) return error.BadOffsets;
        if (f.payload_off + f.payload_count > total_payload) return error.BadOffsets;
        off += frame_entry_bytes;
    }

    const records = try a.alloc(command.Command, @intCast(total_records));
    errdefer a.free(records);
    const rec_bytes = std.mem.sliceAsBytes(records);
    @memcpy(rec_bytes, bytes[off .. off + rec_bytes.len]);
    off += rec_bytes.len;

    const payload = try a.alloc(u32, @intCast(total_payload));
    errdefer a.free(payload);
    const pay_bytes = std.mem.sliceAsBytes(payload);
    @memcpy(pay_bytes, bytes[off .. off + pay_bytes.len]);

    return .{ .frames = frames, .records = records, .payload = payload };
}
