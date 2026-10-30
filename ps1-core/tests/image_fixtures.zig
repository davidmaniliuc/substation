//! Disc-image encoders for tests: each turns a raw 2352-byte-per-sector image
//! into one of the formats the core reads, so a reader is checked against the
//! bytes it must reproduce.
const std = @import("std");
const sector = @import("ps1_core").sector;

const sector_bytes = 2352;

const ecm_raw = 0;
const ecm_mode1 = 1;
const ecm_form1 = 2;
const ecm_form2 = 3;

/// One run of records sharing a type: one chunk of the stream.
const EcmChunk = struct {
    type: u2 = ecm_raw,
    count: u32 = 0,
    records: std.ArrayList(u8) = .empty,
};

/// ECM-encodes `raw`: type 1 for a Mode 1 sector, the 16 sync/header bytes
/// raw then type 2 or 3 for a Mode 2 Form 1 or Form 2 sector, raw bytes for
/// anything else. A sector is only stripped when its rebuild matches it.
pub fn encodeEcm(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    std.debug.assert(raw.len % sector_bytes == 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "ECM\x00");

    var chunk: EcmChunk = .{};
    defer chunk.records.deinit(gpa);

    var at: usize = 0;
    while (at < raw.len) : (at += sector_bytes) {
        const s = raw[at..][0..sector_bytes];
        switch (ecmTypeOf(s)) {
            ecm_mode1 => try addRecord(gpa, &out, &chunk, ecm_mode1, &.{ s[0x0C..0x0F], s[0x10..0x810] }),
            ecm_form1 => {
                try addRecord(gpa, &out, &chunk, ecm_raw, &.{s[0..0x10]});
                try addRecord(gpa, &out, &chunk, ecm_form1, &.{s[0x14..0x818]});
            },
            ecm_form2 => {
                try addRecord(gpa, &out, &chunk, ecm_raw, &.{s[0..0x10]});
                try addRecord(gpa, &out, &chunk, ecm_form2, &.{s[0x14..0x92C]});
            },
            else => try addRecord(gpa, &out, &chunk, ecm_raw, &.{s}),
        }
    }
    try flushChunk(gpa, &out, &chunk);
    try putEcmHeader(gpa, &out, ecm_raw, 0xFFFFFFFF);
    var edc: [4]u8 = undefined;
    std.mem.writeInt(u32, &edc, sector.edc(raw), .little);
    try out.appendSlice(gpa, &edc);
    return out.toOwnedSlice(gpa);
}

fn addRecord(gpa: std.mem.Allocator, out: *std.ArrayList(u8), chunk: *EcmChunk, kind: u2, parts: []const []const u8) !void {
    if (chunk.count != 0 and chunk.type != kind) try flushChunk(gpa, out, chunk);
    chunk.type = kind;
    for (parts) |p| try chunk.records.appendSlice(gpa, p);
    // A raw chunk is one record of `count` bytes; the others count records.
    chunk.count += if (kind == ecm_raw) @intCast(parts[0].len) else 1;
}

fn flushChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), chunk: *EcmChunk) !void {
    if (chunk.count == 0) return;
    try putEcmHeader(gpa, out, chunk.type, chunk.count - 1);
    try out.appendSlice(gpa, chunk.records.items);
    chunk.records.clearRetainingCapacity();
    chunk.count = 0;
}

fn putEcmHeader(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: u2, count_minus_one: u32) !void {
    var n = count_minus_one >> 5;
    try out.append(gpa, @as(u8, kind) | (@as(u8, @intCast(count_minus_one & 0x1F)) << 2) | (if (n != 0) @as(u8, 0x80) else 0));
    while (n != 0) {
        const low: u8 = @intCast(n & 0x7F);
        n >>= 7;
        try out.append(gpa, low | (if (n != 0) @as(u8, 0x80) else 0));
    }
}

/// Which record a sector can be stored as: the rebuild from what that record
/// keeps must give back the sector exactly.
fn ecmTypeOf(s: *const [sector_bytes]u8) u2 {
    if (!std.mem.eql(u8, s[0..12], &sector.sync_pattern)) return ecm_raw;
    var rebuilt: [sector_bytes]u8 = @splat(0);
    rebuilt[0..12].* = sector.sync_pattern;
    rebuilt[0x0C..0x10].* = s[0x0C..0x10].*;
    switch (s[15]) {
        1 => {
            @memcpy(rebuilt[0x10..0x810], s[0x10..0x810]);
            std.mem.writeInt(u32, rebuilt[0x810..0x814], sector.edc(rebuilt[0..0x810]), .little);
            sector.writeEcc(&rebuilt);
            return if (std.mem.eql(u8, &rebuilt, s)) ecm_mode1 else ecm_raw;
        },
        2 => {
            if (!std.mem.eql(u8, s[0x10..0x14], s[0x14..0x18])) return ecm_raw;
            rebuilt[0x10..0x18].* = s[0x10..0x18].*;
            if (s[0x12] & 0x20 != 0) {
                @memcpy(rebuilt[0x18..0x92C], s[0x18..0x92C]);
                std.mem.writeInt(u32, rebuilt[0x92C..0x930], sector.edc(rebuilt[0x10..0x92C]), .little);
                return if (std.mem.eql(u8, &rebuilt, s)) ecm_form2 else ecm_raw;
            }
            @memcpy(rebuilt[0x18..0x818], s[0x18..0x818]);
            std.mem.writeInt(u32, rebuilt[0x818..0x81C], sector.edc(rebuilt[0x10..0x818]), .little);
            sector.writeEcc(&rebuilt);
            return if (std.mem.eql(u8, &rebuilt, s)) ecm_form1 else ecm_raw;
        },
        else => return ecm_raw,
    }
}
