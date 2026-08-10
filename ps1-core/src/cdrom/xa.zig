const std = @import("std");
const CdRom = @import("cdrom.zig").CdRom;

/// XA-ADPCM decoder + resampler state.
pub const Xa = struct {
    xa_filter_file: u8 = 0,
    xa_filter_channel: u8 = 0,
    xa_old_l: i32 = 0,
    xa_older_l: i32 = 0,
    xa_old_r: i32 = 0,
    xa_older_r: i32 = 0,
    // 37800Hz -> 44100Hz zigzag resampler state, one set per channel.
    xa_ringbuf: [2][32]i16 = [_][32]i16{[_]i16{0} ** 32} ** 2,
    xa_ring_p: [2]u32 = .{ 0, 0 },
    xa_sixstep: [2]u8 = .{ 6, 6 },
};

/// 37800Hz -> 44100Hz resampling kernels (Avocado src/sound/tables.cpp).
const xa_zigzag_table = [7][29]i16{
    .{
        0x0000,  0x0000,  0x0000,  0x0000,  0x0000,  -0x0002,
        0x000A,  -0x0022, 0x0041,  -0x0054, 0x0034,  0x0009,
        -0x010A, 0x0400,  -0x0A78, 0x234C,  0x6794,  -0x1780,
        0x0BCD,  -0x0623, 0x0350,  -0x016D, 0x006B,  0x000A,
        -0x0010, 0x0011,  -0x0008, 0x0003,  -0x0001,
    },
    .{
        0x0000,  0x0000,  0x0000,  -0x0002, 0x0000,  0x0003,
        -0x0013, 0x003C,  -0x004B, 0x00A2,  -0x00E3, 0x0132,
        -0x0043, -0x0267, 0x0C9D,  0x74BB,  -0x11B4, 0x09B8,
        -0x05BF, 0x0372,  -0x01A8, 0x00A6,  -0x001B, 0x0005,
        0x0006,  -0x0008, 0x0003,  -0x0001, 0x0000,
    },
    .{
        0x0000,  0x0000,  -0x0001, 0x0003,  -0x0002, -0x0005,
        0x001F,  -0x004A, 0x00B3,  -0x0192, 0x02B1,  -0x039E,
        0x04F8,  -0x05A6, 0x7939,  -0x05A6, 0x04F8,  -0x039E,
        0x02B1,  -0x0192, 0x00B3,  -0x004A, 0x001F,  -0x0005,
        -0x0002, 0x0003,  -0x0001, 0x0000,  0x0000,
    },
    .{
        0x0000,  -0x0001, 0x0003,  -0x0008, 0x0006,  0x0005,
        -0x001B, 0x00A6,  -0x01A8, 0x0372,  -0x05BF, 0x09B8,
        -0x11B4, 0x74BB,  0x0C9D,  -0x0267, -0x0043, 0x0132,
        -0x00E3, 0x00A2,  -0x004B, 0x003C,  -0x0013, 0x0003,
        0x0000,  -0x0002, 0x0000,  0x0000,  0x0000,
    },
    .{
        0x0001, 0x0003,  -0x0008, 0x0011,  -0x0010, 0x000A,
        0x006B, -0x016D, 0x0350,  -0x0623, 0x0BCD,  -0x1780,
        0x6794, 0x234C,  -0x0A78, 0x0400,  -0x010A, 0x0009,
        0x0034, -0x0054, 0x0041,  -0x0022, 0x000A,  -0x0001,
        0x0000, 0x0001,  0x0000,  0x0000,  0x0000,
    },
    .{
        0x0002,  -0x0008, 0x0010,  -0x0023, 0x002B,  0x001A,
        -0x00EB, 0x027B,  -0x0548, 0x0AFA,  -0x16FA, 0x53E0,
        0x3C07,  -0x1249, 0x080E,  -0x0347, 0x015B,  -0x0044,
        -0x0017, 0x0046,  -0x0023, 0x0011,  -0x0005, 0x0000,
        0x0000,  0x0000,  0x0000,  0x0000,  0x0000,
    },
    .{
        -0x0005, 0x0011,  -0x0023, 0x0046,  -0x0017, -0x0044,
        0x015B,  -0x0347, 0x080E,  -0x1249, 0x3C07,  0x53E0,
        -0x16FA, 0x0AFA,  -0x0548, 0x027B,  -0x00EB, 0x001A,
        0x002B,  -0x0023, 0x0010,  -0x0008, 0x0002,  0x0000,
        0x0000,  0x0000,  0x0000,  0x0000,  0x0000,
    },
};

pub fn isXaAudioSector(cdrom: *const CdRom, sector: *const [2352]u8) bool {
    _ = cdrom;
    const mode_byte = sector[0x0F];
    if (mode_byte != 2) return false;

    const submode = sector[0x12];
    const submode_copy = sector[0x16];
    if (submode != submode_copy) return false;

    // CD-XA submode bits (Avocado `cd::Submode`, utils/cd.h):
    // 0=endOfRecord 1=video 2=audio 3=data 4=trigger 5=form2 6=realtime 7=endOfFile
    const is_audio = (submode & 0x04) != 0;
    const is_form2 = (submode & 0x20) != 0;
    const is_realtime = (submode & 0x40) != 0;
    return is_realtime and is_form2 and is_audio;
}

pub fn playXaAudioSector(cdrom: *CdRom, sector: *const [2352]u8) void {
    const file = sector[0x10];
    const channel = sector[0x11];
    const coding_info = sector[0x13];

    if ((cdrom.drive.mode & 0x08) != 0) { // Filter bit
        if (file != cdrom.xa.xa_filter_file or channel != cdrom.xa.xa_filter_channel) {
            return; // Ignored by filter
        }
    }

    // Coding info is a set of 1-bit fields (Avocado `cd::Codinginfo`);
    // the odd bits are reserved and bit6 (emphasis) is commonly set.
    const is_stereo = (coding_info & 0x01) != 0;
    const is_18900 = (coding_info & 0x04) != 0;
    const is_8bit = (coding_info & 0x10) != 0;
    if (is_8bit) {
        std.log.warn("XA-ADPCM 8-bit mode not fully supported!", .{});
        return;
    }

    // Worst case per 128-byte group: mono, 8 blocks * 28 samples = 224 inputs,
    // resampled 6->7 and doubled for 18900Hz.
    var left_buf: [768]i16 = undefined;
    var right_buf: [768]i16 = undefined;

    var group: usize = 0;
    while (group < 18) : (group += 1) {
        const g = sector[0x18 + group * 128 ..][0..128];
        if (is_stereo) {
            const nl = decodeXaPacket(cdrom, g, .left, is_18900, &left_buf);
            const nr = decodeXaPacket(cdrom, g, .right, is_18900, &right_buf);
            for (0..@min(nl, nr)) |i| cdrom.pushXaSample(left_buf[i], right_buf[i]);
        } else {
            const n = decodeXaPacket(cdrom, g, .mono, is_18900, &left_buf);
            for (0..n) |i| cdrom.pushXaSample(left_buf[i], left_buf[i]);
        }
    }
}

const XaChannel = enum { mono, left, right };

/// Decodes one 128-byte sound group for a single channel, appending
/// 44100Hz samples to `out`. Port of Avocado `ADPCM::decodePacket`.
///
/// A group holds 8 sound units. Their headers live at group offsets 4..11
/// (0..3 is the redundant copy), and the 28 data words at 0x10..0x7F carry
/// unit `b` in bits `b*4` of each little-endian 32-bit word. Stereo splits
/// the units by parity: even -> left, odd -> right.
fn decodeXaPacket(
    cdrom: *CdRom,
    group: *const [128]u8,
    comptime channel: XaChannel,
    is_18900: bool,
    out: []i16,
) usize {
    const blocks: []const usize = switch (channel) {
        .mono => &[_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 },
        .left => &[_]usize{ 0, 2, 4, 6 },
        .right => &[_]usize{ 1, 3, 5, 7 },
    };
    const ch: usize = if (channel == .right) 1 else 0;
    const old = if (channel == .right) &cdrom.xa.xa_old_r else &cdrom.xa.xa_old_l;
    const older = if (channel == .right) &cdrom.xa.xa_older_r else &cdrom.xa.xa_older_l;

    const filter_pos = [5]i32{ 0, 60, 115, 98, 122 };
    const filter_neg = [5]i32{ 0, 0, -52, -55, -60 };

    var count: usize = 0;
    for (blocks) |block| {
        const header = group[4 + block];
        var shift: u5 = @truncate(header & 0x0F);
        if (shift > 12) shift = 9;
        const filter = (header & 0x30) >> 4;
        const f0 = filter_pos[filter];
        const f1 = filter_neg[filter];

        for (0..28) |n| {
            const base = 0x10 + n * 4;
            const word = @as(u32, group[base]) |
                (@as(u32, group[base + 1]) << 8) |
                (@as(u32, group[base + 2]) << 16) |
                (@as(u32, group[base + 3]) << 24);
            const nibble: u16 = @truncate((word >> @intCast(block * 4)) & 0x0F);

            // Sign-extend the 4-bit sample via bit 15, then scale by the shift.
            var sample: i32 = @as(i32, @as(i16, @bitCast(nibble << 12))) >> shift;
            sample += @divTrunc(old.* * f0 + older.* * f1 + 32, 64);

            const clamped = std.math.clamp(sample, -32768, 32767);
            // The predictor history keeps the *unclamped* value (Avocado adpcm.cpp:141-142).
            older.* = old.*;
            old.* = sample;

            count += interpolateXa(cdrom, ch, @intCast(clamped), is_18900, out[count..]);
        }
    }
    return count;
}

/// Feeds one 37800Hz sample into the per-channel ring buffer, emitting 7
/// output samples for every 6 inputs (37800 -> 44100Hz), doubled when the
/// source is 18900Hz. Port of Avocado `ADPCM::interpolate`.
fn interpolateXa(cdrom: *CdRom, ch: usize, sample: i16, is_18900: bool, out: []i16) usize {
    cdrom.xa.xa_ringbuf[ch][cdrom.xa.xa_ring_p[ch] & 0x1F] = sample;
    cdrom.xa.xa_ring_p[ch] +%= 1;

    cdrom.xa.xa_sixstep[ch] -= 1;
    if (cdrom.xa.xa_sixstep[ch] != 0) return 0;
    cdrom.xa.xa_sixstep[ch] = 6;

    var n: usize = 0;
    for (0..7) |table| {
        const v = zigzagXa(cdrom, ch, table);
        out[n] = v;
        n += 1;
        if (is_18900) {
            out[n] = v;
            n += 1;
        }
    }
    return n;
}

fn zigzagXa(cdrom: *const CdRom, ch: usize, table: usize) i16 {
    var sum: i32 = 0;
    var i: u32 = 1;
    while (i < 29) : (i += 1) {
        const idx = (cdrom.xa.xa_ring_p[ch] -% i) & 0x1F;
        sum += @divTrunc(@as(i32, cdrom.xa.xa_ringbuf[ch][idx]) * @as(i32, xa_zigzag_table[table][i]), 0x8000);
    }
    return @intCast(std.math.clamp(sum, -32768, 32767));
}
