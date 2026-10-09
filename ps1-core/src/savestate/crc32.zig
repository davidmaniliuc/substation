//! CRC-32 (the zlib polynomial, `std.hash.Crc32`'s exact value) for the
//! savestate checksum.
//!
//! `std.hash.Crc32` is a byte-at-a-time table loop: every lookup waits on the
//! one before it, so it runs at ~0.4 GB/s and a 6.9 MB state took 18 ms to
//! checksum on an M1, 97% of a save. arm64's CRC extension implements this
//! polynomial in one instruction per 8 bytes (~8.5 GB/s); everything else
//! (wasm, x86) slices by eight (~2.3 GB/s).
//!
//! The value is the wire format: any state saved by an older build must still
//! verify, so both paths are pinned to `std.hash.Crc32` by test.

const std = @import("std");
const builtin = @import("builtin");

const hardware = builtin.cpu.arch == .aarch64 and builtin.cpu.has(.aarch64, .crc);

pub fn hash(bytes: []const u8) u32 {
    return if (hardware) hashHardware(bytes) else hashSliced(bytes);
}

fn hashHardware(bytes: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        crc = asm ("crc32x %[out:w], %[crc:w], %[v]"
            : [out] "=r" (-> u32),
            : [crc] "r" (crc),
              [v] "r" (std.mem.readInt(u64, bytes[i..][0..8], .little)),
        );
    }
    while (i < bytes.len) : (i += 1) {
        crc = asm ("crc32b %[out:w], %[crc:w], %[v:w]"
            : [out] "=r" (-> u32),
            : [crc] "r" (crc),
              [v] "r" (@as(u32, bytes[i])),
        );
    }
    return ~crc;
}

/// `tables[k][b]` is byte `b`'s contribution `k` bytes before the end of an
/// eight-byte step, so the eight lookups of one step are independent.
const tables = blk: {
    @setEvalBranchQuota(10_000);
    var t: [8][256]u32 = undefined;
    for (&t[0], 0..) |*e, b| {
        var c: u32 = b;
        for (0..8) |_| c = if (c & 1 != 0) 0xedb88320 ^ (c >> 1) else c >> 1;
        e.* = c;
    }
    for (1..8) |k| {
        for (&t[k], t[k - 1]) |*e, prev| e.* = (prev >> 8) ^ t[0][prev & 0xff];
    }
    break :blk t;
};

/// Public so the test can pin it on a machine that takes the hardware path.
pub fn hashSliced(bytes: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const lo = std.mem.readInt(u32, bytes[i..][0..4], .little) ^ crc;
        const hi = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        crc = tables[7][lo & 0xff] ^ tables[6][(lo >> 8) & 0xff] ^
            tables[5][(lo >> 16) & 0xff] ^ tables[4][lo >> 24] ^
            tables[3][hi & 0xff] ^ tables[2][(hi >> 8) & 0xff] ^
            tables[1][(hi >> 16) & 0xff] ^ tables[0][hi >> 24];
    }
    while (i < bytes.len) : (i += 1) crc = tables[0][(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    return ~crc;
}
