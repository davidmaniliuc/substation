//! FLAC frame decoder for CHD's `cdfl` codec. A CHD stores each hunk's audio
//! as bare FLAC frames with no stream header, so this reads frames only: no
//! metadata blocks, no seeking. It takes anything an encoder can produce for
//! 16-bit stereo and refuses everything else. Every frame's CRC8 and CRC16 are
//! checked, and the arithmetic wraps, so a corrupt frame is an error and never
//! a panic.
const std = @import("std");
const BitReader = @import("bitstream.zig").BitReader;

const Crc8 = std.hash.crc.@"CRC-8/SMBUS";
const Crc16 = std.hash.crc.@"CRC-16/UMTS";

/// The largest block buffered. chdman writes 2352-sample blocks.
pub const max_block = 4608;
const channels = 2;
const sample_bits = 16;
const max_lpc_order = 32;

pub const Error = error{ BadFrame, BadCrc, Unsupported };

/// Counts of what was decoded; tests use it to prove a fixture covers a path.
pub const Stats = struct {
    constant: u32 = 0,
    verbatim: u32 = 0,
    fixed: u32 = 0,
    lpc: u32 = 0,
    escaped_partitions: u32 = 0,
    independent: u32 = 0,
    left_side: u32 = 0,
    right_side: u32 = 0,
    mid_side: u32 = 0,
};

pub const Stereo = enum { independent, left_side, right_side, mid_side };

const Frame = struct { block_size: usize, bytes: usize };

/// Fills `out` with `out.len / 4` stereo samples, big-endian L then R, as
/// chdman stores CD audio. Returns the bytes of `src` the frames occupied.
pub fn decodeFrames(src: []const u8, out: []u8, stats: ?*Stats) Error!usize {
    const total = out.len / 4;
    var done: usize = 0;
    var pos: usize = 0;
    var samples: [channels][max_block]i32 = undefined;
    while (done < total) {
        const frame = try decodeFrame(src[pos..], &samples, stats);
        const take = @min(frame.block_size, total - done);
        for (0..take) |i| {
            writeSample(out[(done + i) * 4 ..][0..2], samples[0][i]);
            writeSample(out[(done + i) * 4 + 2 ..][0..2], samples[1][i]);
        }
        done += take;
        pos += frame.bytes;
    }
    return pos;
}

fn writeSample(dst: *[2]u8, sample: i32) void {
    std.mem.writeInt(i16, dst, @truncate(sample), .big);
}

fn decodeFrame(src: []const u8, samples: *[channels][max_block]i32, stats: ?*Stats) Error!Frame {
    var br = BitReader.init(src);
    // 14-bit sync code plus the reserved zero bit.
    if (br.read(15) != 0x7FFC) return error.BadFrame;
    _ = br.read(1); // blocking strategy: irrelevant without seeking
    const size_code = br.read(4);
    const rate_code = br.read(4);
    const assignment = br.read(4);
    const size_bits = br.read(3);
    if (br.read(1) != 0) return error.BadFrame;
    try skipCodedNumber(&br);

    const block_size: usize = switch (size_code) {
        0 => return error.BadFrame,
        1 => 192,
        2...5 => @as(usize, 576) << @intCast(size_code - 2),
        6 => br.read(8) + 1,
        7 => br.read(16) + 1,
        else => @as(usize, 256) << @intCast(size_code - 8),
    };
    switch (rate_code) {
        12 => _ = br.read(8),
        13, 14 => _ = br.read(16),
        15 => return error.BadFrame,
        else => {},
    }
    // 0 means "from STREAMINFO", which a CHD never has: chdman's is 16-bit.
    if (size_bits != 0 and size_bits != 4) return error.Unsupported;
    const stereo: Stereo = switch (assignment) {
        1 => .independent,
        8 => .left_side,
        9 => .right_side,
        10 => .mid_side,
        else => return error.Unsupported,
    };
    if (block_size > max_block) return error.Unsupported;

    const header_end = br.bytePos();
    if (br.overflow or br.read(8) != Crc8.hash(src[0..header_end])) return error.BadCrc;

    for (0..channels) |ch| {
        const side = switch (stereo) {
            .independent => false,
            .left_side, .mid_side => ch == 1,
            .right_side => ch == 0,
        };
        try decodeSubframe(&br, samples[ch][0..block_size], sample_bits + @as(u32, @intFromBool(side)), stats);
    }
    restoreStereo(stereo, samples[0][0..block_size], samples[1][0..block_size]);

    br.alignToByte();
    const crc_pos = br.bytePos();
    if (br.overflow or crc_pos + 2 > src.len) return error.BadFrame;
    if (br.read(16) != Crc16.hash(src[0..crc_pos])) return error.BadCrc;

    if (stats) |s| switch (stereo) {
        .independent => s.independent += 1,
        .left_side => s.left_side += 1,
        .right_side => s.right_side += 1,
        .mid_side => s.mid_side += 1,
    };
    return .{ .block_size = block_size, .bytes = crc_pos + 2 };
}

/// The frame number, UTF-8-style: a lead byte whose high ones count the bytes.
fn skipCodedNumber(br: *BitReader) Error!void {
    const lead = br.read(8);
    if (lead & 0x80 == 0) return;
    var extra: u32 = 0;
    var mask: u32 = 0x40;
    while (mask != 0 and lead & mask != 0) : (mask >>= 1) extra += 1;
    if (extra == 0 or extra > 6) return error.BadFrame;
    for (0..extra) |_| {
        if (br.read(8) & 0xC0 != 0x80) return error.BadFrame;
    }
}

fn decodeSubframe(br: *BitReader, out: []i32, depth: u32, stats: ?*Stats) Error!void {
    if (br.read(1) != 0) return error.BadFrame;
    const kind = br.read(6);
    var wasted: u32 = 0;
    if (br.read(1) == 1) wasted = br.readUnary() + 1;
    if (wasted >= depth) return error.BadFrame;
    const bits: u6 = @intCast(depth - wasted);

    switch (kind) {
        0 => {
            @memset(out, br.readSigned(bits));
            if (stats) |s| s.constant += 1;
        },
        1 => {
            for (out) |*sample| sample.* = br.readSigned(bits);
            if (stats) |s| s.verbatim += 1;
        },
        8...12 => {
            try decodeFixed(br, out, kind - 8, bits, stats);
            if (stats) |s| s.fixed += 1;
        },
        32...63 => {
            try decodeLpc(br, out, kind - 31, bits, stats);
            if (stats) |s| s.lpc += 1;
        },
        else => return error.BadFrame,
    }
    if (wasted > 0) {
        for (out) |*sample| sample.* <<= @intCast(wasted);
    }
}

fn decodeFixed(br: *BitReader, out: []i32, order: usize, bits: u6, stats: ?*Stats) Error!void {
    if (order > out.len) return error.BadFrame;
    for (out[0..order]) |*sample| sample.* = br.readSigned(bits);
    try decodeResidual(br, out.len, order, out[order..], stats);
    var i = order;
    while (i < out.len) : (i += 1) {
        const r = out[i];
        out[i] = switch (order) {
            0 => r,
            1 => r +% out[i - 1],
            2 => r +% 2 *% out[i - 1] -% out[i - 2],
            3 => r +% 3 *% out[i - 1] -% 3 *% out[i - 2] +% out[i - 3],
            4 => r +% 4 *% out[i - 1] -% 6 *% out[i - 2] +% 4 *% out[i - 3] -% out[i - 4],
            else => unreachable,
        };
    }
}

fn decodeLpc(br: *BitReader, out: []i32, order: usize, bits: u6, stats: ?*Stats) Error!void {
    if (order > out.len) return error.BadFrame;
    for (out[0..order]) |*sample| sample.* = br.readSigned(bits);
    const precision = br.read(4) + 1;
    if (precision == 16) return error.BadFrame;
    const shift = br.readSigned(5);
    if (shift < 0) return error.BadFrame;
    var coefs: [max_lpc_order]i32 = undefined;
    for (coefs[0..order]) |*c| c.* = br.readSigned(@intCast(precision));
    try decodeResidual(br, out.len, order, out[order..], stats);
    var i = order;
    while (i < out.len) : (i += 1) {
        var sum: i64 = 0;
        for (coefs[0..order], 0..) |c, j| sum +%= @as(i64, c) *% out[i - 1 - j];
        out[i] +%= @truncate(sum >> @intCast(shift));
    }
}

/// Rice-coded residuals, partition by partition. An escaped partition stores
/// raw signed samples of a width it names itself.
pub fn decodeResidual(br: *BitReader, block_size: usize, order: usize, residual: []i32, stats: ?*Stats) Error!void {
    const method = br.read(2);
    if (method > 1) return error.BadFrame;
    const param_bits: u6 = if (method == 0) 4 else 5;
    const escape: u32 = if (method == 0) 15 else 31;
    const partitions = @as(usize, 1) << @intCast(br.read(4));
    if (block_size % partitions != 0) return error.BadFrame;
    const per = block_size / partitions;
    if (per < order) return error.BadFrame;

    var n: usize = 0;
    for (0..partitions) |p| {
        const count = if (p == 0) per - order else per;
        const param = br.read(param_bits);
        if (param == escape) {
            const width: u6 = @intCast(br.read(5));
            for (residual[n..][0..count]) |*r| r.* = br.readSigned(width);
            if (stats) |s| s.escaped_partitions += 1;
        } else {
            const k: u5 = @intCast(param);
            for (residual[n..][0..count]) |*r| {
                const folded = (br.readUnary() << k) | br.read(k);
                r.* = @bitCast((folded >> 1) ^ (0 -% (folded & 1)));
            }
        }
        n += count;
        if (br.overflow) return error.BadFrame;
    }
}

/// Undoes inter-channel decorrelation in place: `a` becomes left, `b` right.
pub fn restoreStereo(mode: Stereo, a: []i32, b: []i32) void {
    switch (mode) {
        .independent => {},
        .left_side => for (a, b) |left, *side| {
            side.* = left -% side.*;
        },
        .right_side => for (a, b) |*side, right| {
            side.* = side.* +% right;
        },
        .mid_side => for (a, b) |*m, *s| {
            const mid = (m.* *% 2) | (s.* & 1);
            const side = s.*;
            m.* = (mid +% side) >> 1;
            s.* = (mid -% side) >> 1;
        },
    }
}
