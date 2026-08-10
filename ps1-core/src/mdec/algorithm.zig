const std = @import("std");
const Mdec = @import("mdec.zig").Mdec;

const zigzag_table = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

pub fn decodeAllMacroblocks(mdec: *Mdec) void {
    var input_idx: usize = 0;

    // A macroblock consists of 6 specific blocks: Cr, Cb, Y1, Y2, Y3, Y4
    while (input_idx < mdec.input_len) {
        if (!decodeBlock(mdec, &mdec.cr_block, true, &input_idx)) break;
        if (!decodeBlock(mdec, &mdec.cb_block, true, &input_idx)) break;
        if (!decodeBlock(mdec, &mdec.y_blocks[0], false, &input_idx)) break;
        if (!decodeBlock(mdec, &mdec.y_blocks[1], false, &input_idx)) break;
        if (!decodeBlock(mdec, &mdec.y_blocks[2], false, &input_idx)) break;
        if (!decodeBlock(mdec, &mdec.y_blocks[3], false, &input_idx)) break;
        assembleMacroblock(mdec);
    }
}

fn signExtend10(val: u16) i32 {
    var v = @as(i32, @intCast(val & 0x3FF));
    if ((v & 0x200) != 0) v |= ~@as(i32, 0x3FF);
    return v;
}

fn decodeBlock(mdec: *Mdec, block: *[64]i32, is_color: bool, input_idx: *usize) bool {
    @memset(block, 0);
    const q_table = if (is_color) &mdec.quant_color else &mdec.quant_luminance;

    // Block structure:
    //   (optional) 0xFE00 padding, DCT word, 0-63 RLE words, (optional) 0xFE00.
    while (input_idx.* < mdec.input_len and mdec.input_fifo[input_idx.*] == 0xFE00) {
        input_idx.* += 1;
    }
    if (input_idx.* >= mdec.input_len) return false;

    // DCT word: bits 9-0 = DC, bits 15-10 = quantization factor. The qFactor
    // scales every AC coefficient and is NOT the uploaded scale/IDCT table.
    const dct = mdec.input_fifo[input_idx.*];
    input_idx.* += 1;
    const q_factor: i32 = @intCast((dct >> 10) & 0x3F);

    var current = signExtend10(dct);
    var value: i32 = current * @as(i32, q_table[0]);

    var n: usize = 0;
    while (n < 64) {
        // qFactor 0 bypasses dequantization *and* the zigzag reorder.
        if (q_factor == 0) value = current * 2;
        value = std.math.clamp(value, -0x400, 0x3FF);
        if (q_factor > 0) {
            block[zigzag_table[n]] = value;
        } else {
            block[n] = value;
        }

        if (input_idx.* >= mdec.input_len) return false;
        const rle = mdec.input_fifo[input_idx.*];
        input_idx.* += 1;

        current = signExtend10(rle);
        n += @as(usize, (rle >> 10) & 0x3F) + 1;
        if (n >= 64) break;

        value = @divTrunc(current * @as(i32, q_table[n]) * q_factor + 4, 8);
    }

    idct(mdec, block);
    return true;
}

// Two-pass IDCT using the table the game uploads with MDEC(3), NOT a
// hardcoded cosine matrix.
fn idct(mdec: *Mdec, block: *[64]i32) void {
    var tmp: [64]i64 = @splat(0);

    for (0..8) |x| {
        for (0..8) |y| {
            var sum: i64 = 0;
            for (0..8) |i| {
                sum += @as(i64, mdec.scale_table[i * 8 + y]) * @as(i64, block[x + i * 8]);
            }
            tmp[x + y * 8] = sum;
        }
    }

    for (0..8) |x| {
        for (0..8) |y| {
            var sum: i64 = 0;
            for (0..8) |i| {
                sum += tmp[i + y * 8] * @as(i64, mdec.scale_table[x + i * 8]);
            }
            const round: i64 = (sum >> 31) & 1;
            // The intermediate is stored as i16; keep that truncation.
            block[x + y * 8] = @as(i16, @truncate((sum >> 32) + round));
        }
    }
}

fn assembleMacroblock(mdec: *Mdec) void {
    var pixel_latch: u32 = 0;

    for (0..16) |y| {
        for (0..16) |x| {
            const by = y >> 3;
            const bx = x >> 3;
            const block_idx = by * 2 + bx;

            const ly = y & 7;
            const lx = x & 7;

            const py = mdec.y_blocks[block_idx][ly * 8 + lx];

            // Cb and Cr are 4:2:0 subsampled, so we map 16x16 down to 8x8
            const pcb = mdec.cb_block[(y >> 1) * 8 + (x >> 1)];
            const pcr = mdec.cr_block[(y >> 1) * 8 + (x >> 1)];

            const rgb24 = ycrcb_to_rgb(py, pcr, pcb);

            if (mdec.output_depth == 3) {
                // 15bpp (Used by PlayStation GPU)
                const r = (rgb24 & 0xFF) >> 3;
                const g = ((rgb24 >> 8) & 0xFF) >> 3;
                const b = ((rgb24 >> 16) & 0xFF) >> 3;

                // Bit 15 is STP (semi-transparency), from command bit 25.
                const stp: u32 = if (mdec.output_set_bit15) 0x8000 else 0;
                const rgb15 = r | (g << 5) | (b << 10) | stp;

                // Pack two 15-bit pixels into one 32-bit word
                if ((x & 1) == 0) {
                    pixel_latch = rgb15;
                } else {
                    mdec.pushOutput(pixel_latch | (rgb15 << 16));
                }
            } else {
                // 24bpp is packed densely — four pixels span exactly three
                // words, with no padding byte:
                //   word0: B0 G0 R0 | R1
                //   word1: B1 G1    | R2 G2
                //   word2: B2       | R3 G3 B3
                // 16 is a multiple of 4, so each row starts a fresh group.
                switch (x & 3) {
                    0 => pixel_latch = rgb24,
                    1 => {
                        mdec.pushOutput((pixel_latch & 0xFFFFFF) | ((rgb24 & 0xFF) << 24));
                        pixel_latch = rgb24;
                    },
                    2 => {
                        mdec.pushOutput(((pixel_latch & 0xFFFF00) >> 8) | ((rgb24 & 0xFFFF) << 16));
                        pixel_latch = rgb24;
                    },
                    else => mdec.pushOutput(((pixel_latch & 0xFF0000) >> 16) | ((rgb24 & 0xFFFFFF) << 8)),
                }
            }
        }
    }
}

fn ycrcb_to_rgb(y: i32, cr: i32, cb: i32) u32 {
    // The IDCT output is signed and centred on 0, so the +128 bias is what
    // turns it back into an unsigned level.
    var r = y + ((cr * 1435) >> 10) + 128;
    var g = y - ((cb * 352 + cr * 731) >> 10) + 128;
    var b = y + ((cb * 1814) >> 10) + 128;

    r = std.math.clamp(r, 0, 255);
    g = std.math.clamp(g, 0, 255);
    b = std.math.clamp(b, 0, 255);

    return @as(u32, @intCast(r)) | (@as(u32, @intCast(g)) << 8) | (@as(u32, @intCast(b)) << 16);
}
