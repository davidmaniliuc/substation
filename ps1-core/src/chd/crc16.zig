//! CRC-16/IBM-3740 (CCITT-FALSE), the checksum every CHD hunk carries.
//!
//! `std.hash.crc` is a byte-at-a-time table loop: every lookup waits on the
//! one before it, and on a whole-disc read it was a fifth of the decode time.
//! Slicing by eight makes the eight lookups of a step independent. There is
//! no arm64 instruction for this polynomial.

const std = @import("std");

const polynomial = 0x1021;

/// `tables[k][b]` is byte `b`'s contribution followed by `k` zero bytes, so
/// the eight lookups of one step are independent. MSB-first: the register
/// lines up with the step's first two bytes.
const tables = blk: {
    @setEvalBranchQuota(20_000);
    var t: [8][256]u16 = undefined;
    for (&t[0], 0..) |*e, b| {
        var c: u16 = b << 8;
        for (0..8) |_| c = if (c & 0x8000 != 0) (c << 1) ^ polynomial else c << 1;
        e.* = c;
    }
    for (1..8) |k| {
        for (&t[k], t[k - 1]) |*e, prev| e.* = (prev << 8) ^ t[0][prev >> 8];
    }
    break :blk t;
};

pub fn hash(bytes: []const u8) u16 {
    var crc: u16 = 0xffff;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const b = bytes[i..][0..8];
        crc = tables[7][b[0] ^ (crc >> 8)] ^ tables[6][b[1] ^ (crc & 0xff)] ^
            tables[5][b[2]] ^ tables[4][b[3]] ^ tables[3][b[4]] ^
            tables[2][b[5]] ^ tables[1][b[6]] ^ tables[0][b[7]];
    }
    while (i < bytes.len) : (i += 1) crc = (crc << 8) ^ tables[0][(crc >> 8) ^ bytes[i]];
    return crc;
}
