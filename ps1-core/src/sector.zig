//! Building a raw 2352-byte CD sector from what an image keeps of it: the sync
//! pattern, the BCD header, the EDC and the P/Q parity. CHD restores the
//! parity it strips; cooked and ECM images supply a payload and get the rest.
const std = @import("std");
const constants = @import("constants.zig");
const disc = @import("disc.zig");

const sector_bytes = constants.sector_bytes;

pub const sync_pattern = [12]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };

/// What a cooked image stores per sector, and so how many bytes `dress` takes.
pub const CookedMode = enum {
    mode1,
    mode2,
    mode2_form1,
    mode2_form2,
    /// Subheader in the payload; its submode bit 5 picks Form 1 or Form 2.
    mode2_mixed,

    pub fn bytes(self: CookedMode) usize {
        return switch (self) {
            .mode1, .mode2_form1 => 2048,
            .mode2 => 2336,
            .mode2_form2 => 2324,
            .mode2_mixed => 2332,
        };
    }
};

const p_offset = 0x81C;
const p_rows = 86;
const p_terms = 24;
const q_offset = p_offset + 2 * p_rows;
const q_rows = 52;
const q_terms = 43;

/// GF(2^8) doubling, and the inverse that finishes each parity pair.
const ecc_low: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = @truncate((i << 1) ^ (if (i & 0x80 != 0) 0x11D else 0));
    break :blk t;
};
const ecc_high: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[ecc_low[i] ^ i] = @intCast(i);
    break :blk t;
};

/// CD-ROM EDC: CRC-32 with the reflected polynomial 0xD8018001, init 0.
const edc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var v: u32 = @intCast(i);
        for (0..8) |_| v = (v >> 1) ^ (if (v & 1 != 0) @as(u32, 0xD8018001) else 0);
        t[i] = v;
    }
    break :blk t;
};

pub fn edc(bytes: []const u8) u32 {
    var v: u32 = 0;
    for (bytes) |b| v = (v >> 8) ^ edc_table[(v ^ b) & 0xFF];
    return v;
}

fn pOffset(row: usize, term: usize) usize {
    return row + p_rows * term;
}

fn qOffset(row: usize, term: usize) usize {
    return (((row >> 1) * q_terms + term * (q_terms + 1)) % (q_rows * q_terms / 2)) * 2 + (row & 1);
}

/// One parity pair over the bytes after the sync pattern. A Mode 2 sector's
/// header is excluded from its parity, so its four bytes count as zero.
fn parity(sector: *const [sector_bytes]u8, comptime terms: usize, comptime offsetOf: fn (usize, usize) usize, row: usize) [2]u8 {
    const data = sector[sync_pattern.len..];
    const mode2 = sector[15] == 2;
    var v1: u8 = 0;
    var v2: u8 = 0;
    for (0..terms) |term| {
        const off = offsetOf(row, term);
        const byte: u8 = if (mode2 and off < 4) 0 else data[off];
        v1 = ecc_low[v1 ^ byte];
        v2 ^= byte;
    }
    v1 = ecc_high[ecc_low[v1] ^ v2];
    return .{ v1, v2 ^ v1 };
}

/// Writes P then Q, which covers P. The sector's mode byte must already be set.
pub fn writeEcc(sector: *[sector_bytes]u8) void {
    for (0..p_rows) |row| {
        const v = parity(sector, p_terms, pOffset, row);
        sector[p_offset + row] = v[0];
        sector[p_offset + p_rows + row] = v[1];
    }
    for (0..q_rows) |row| {
        const v = parity(sector, q_terms, qOffset, row);
        sector[q_offset + row] = v[0];
        sector[q_offset + q_rows + row] = v[1];
    }
}

pub fn writeHeader(sector: *[sector_bytes]u8, lba: i32, mode: u8) void {
    const msf = disc.MSF.fromLba(lba);
    sector[0..sync_pattern.len].* = sync_pattern;
    sector[12] = msf.m;
    sector[13] = msf.s;
    sector[14] = msf.f;
    sector[15] = mode;
}

fn putEdc(out: *[sector_bytes]u8, from: usize, at: usize) void {
    std.mem.writeInt(u32, out[at..][0..4], edc(out[from..at]), .little);
}

/// Builds the whole raw sector for `lba` from a cooked `payload`
/// (`mode.bytes()` long).
pub fn dress(mode: CookedMode, lba: i32, payload: []const u8, out: *[sector_bytes]u8) void {
    std.debug.assert(payload.len == mode.bytes());
    @memset(out, 0);
    switch (mode) {
        .mode1 => {
            writeHeader(out, lba, 1);
            @memcpy(out[0x10..][0..2048], payload);
            putEdc(out, 0, 0x810);
            writeEcc(out);
        },
        .mode2 => {
            writeHeader(out, lba, 2);
            @memcpy(out[0x10..][0..2336], payload);
        },
        .mode2_form1 => {
            writeHeader(out, lba, 2);
            out[0x12] = 0x08;
            out[0x16] = 0x08;
            @memcpy(out[0x18..][0..2048], payload);
            form1(out);
        },
        .mode2_form2 => {
            writeHeader(out, lba, 2);
            out[0x12] = 0x28;
            out[0x16] = 0x28;
            @memcpy(out[0x18..][0..2324], payload);
            putEdc(out, 0x10, 0x92C);
        },
        .mode2_mixed => {
            writeHeader(out, lba, 2);
            @memcpy(out[0x10..][0..2332], payload);
            if (out[0x12] & 0x20 != 0) putEdc(out, 0x10, 0x92C) else form1(out);
        },
    }
}

fn form1(out: *[sector_bytes]u8) void {
    putEdc(out, 0x10, 0x818);
    writeEcc(out);
}
