const std = @import("std");

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

pub const Mdec = struct {
    status: u32 = 0,

    quant_luminance: [64]u8 = [_]u8{0} ** 64,
    quant_color: [64]u8 = [_]u8{0} ** 64,
    scale_table: [64]i16 = [_]i16{0} ** 64,

    current_cmd: u32 = 0,
    words_remaining: u32 = 0,

    input_fifo: [131072]u16 = [_]u16{0} ** 131072,
    input_len: usize = 0,

    y_blocks: [4][64]i32 = [_][64]i32{[_]i32{0} ** 64} ** 4,
    cb_block: [64]i32 = [_]i32{0} ** 64,
    cr_block: [64]i32 = [_]i32{0} ** 64,

    output_fifo: [131072]u32 = [_]u32{0} ** 131072,
    output_ptr: usize = 0,
    output_len: usize = 0,
    output_depth: u3 = 3,
    output_set_bit15: bool = false,

    pub fn init() Mdec {
        return .{
            // Bit 31: Data Out Ready (1=Ready)
            // Bit 28: Data In FIFO Empty (1=Empty)
            .status = (1 << 31) | (1 << 28),
        };
    }

    pub fn readStatus(self: *Mdec) u32 {
        var stat = self.status;
        if (self.words_remaining > 0) {
            stat |= (1 << 29); // Data In Request (Busy receiving data)
            stat &= ~@as(u32, 1 << 28); // Data In FIFO not empty
        } else {
            stat &= ~@as(u32, 1 << 29);
            stat |= (1 << 28); // Data In FIFO empty
        }
        if (self.output_len > 0) {
            stat |= (1 << 31); // Data Out Ready
        } else {
            stat &= ~@as(u32, 1 << 31);
        }

        // Data Output Depth is mirrored in bits 26-25 of the Status Register
        stat = (stat & ~(@as(u32, 3) << 25)) | (@as(u32, self.output_depth) << 25);
        return stat;
    }

    fn writeCommandInternal(self: *Mdec, val: u32) void {
        const cmd = (val >> 29) & 0x7;
        self.current_cmd = cmd;

        switch (cmd) {
            0 => { // NOP
                self.words_remaining = 0;
            },
            1 => { // Decode Macroblocks
                self.words_remaining = val & 0xFFFF;
                // Output depth rides on the *command* word (bits 28-27), not on
                // the control register (PSX-SPX MDEC(1); Avocado mdec.cpp:81).
                self.output_depth = @truncate((val >> 27) & 3);
                self.output_set_bit15 = (val & (1 << 25)) != 0;
                self.input_len = 0; // Reset input FIFO for new macroblocks
            },
            2 => { // Set Quantize Tables
                self.words_remaining = 32; // 64 bytes total
            },
            3 => { // Set Scale Table
                self.words_remaining = 32; // 64 half-words
            },
            else => {
                std.log.warn("Unknown MDEC command: {}", .{cmd});
                self.words_remaining = 0;
            },
        }
    }

    pub fn writeControl(self: *Mdec, val: u32) void {
        if (val & (1 << 31) != 0) {
            // Reset MDEC
            self.status = (1 << 31) | (1 << 28);
            self.words_remaining = 0;
            self.output_len = 0;
            self.input_len = 0;
        }

        // The control register carries reset + the DMA enable bits only; the
        // output depth belongs to the MDEC(1) command word (see
        // writeCommandInternal). Latching it here made the depth depend on
        // whichever control write happened last.
    }

    pub fn readData(self: *Mdec) u32 {
        if (self.output_len == 0) return 0;
        const val = self.output_fifo[self.output_ptr];
        self.output_ptr = (self.output_ptr + 1) % 131072;
        self.output_len -= 1;
        return val;
    }

    pub fn write(self: *Mdec, val: u32) void {
        if (self.words_remaining > 0) {
            self.writeDataInternal(val);
        } else {
            self.writeCommandInternal(val);
        }
    }

    fn writeDataInternal(self: *Mdec, val: u32) void {
        if (self.words_remaining == 0) return;
        self.words_remaining -= 1;

        switch (self.current_cmd) {
            1 => {
                self.input_fifo[self.input_len] = @truncate(val & 0xFFFF);
                self.input_fifo[self.input_len + 1] = @truncate(val >> 16);
                self.input_len += 2;

                // Sync decode once the DMA transfer finishes pushing all words
                if (self.words_remaining == 0) {
                    self.decodeAllMacroblocks();
                }
            },
            2 => {
                const idx = (31 - self.words_remaining) * 4;
                if (idx < 64) {
                    self.quant_luminance[idx + 0] = @truncate(val >> 0);
                    self.quant_luminance[idx + 1] = @truncate(val >> 8);
                    self.quant_luminance[idx + 2] = @truncate(val >> 16);
                    self.quant_luminance[idx + 3] = @truncate(val >> 24);
                } else if (idx < 128) {
                    const c_idx = idx - 64;
                    self.quant_color[c_idx + 0] = @truncate(val >> 0);
                    self.quant_color[c_idx + 1] = @truncate(val >> 8);
                    self.quant_color[c_idx + 2] = @truncate(val >> 16);
                    self.quant_color[c_idx + 3] = @truncate(val >> 24);
                }
            },
            3 => {
                const idx = (31 - self.words_remaining) * 2;
                self.scale_table[idx + 0] = @as(i16, @bitCast(@as(u16, @truncate(val >> 0))));
                self.scale_table[idx + 1] = @as(i16, @bitCast(@as(u16, @truncate(val >> 16))));
            },
            else => {},
        }
    }

    fn decodeAllMacroblocks(self: *Mdec) void {
        var input_idx: usize = 0;

        // A macroblock consists of 6 specific blocks: Cr, Cb, Y1, Y2, Y3, Y4
        while (input_idx < self.input_len) {
            if (!self.decodeBlock(&self.cr_block, true, &input_idx)) break;
            if (!self.decodeBlock(&self.cb_block, true, &input_idx)) break;
            if (!self.decodeBlock(&self.y_blocks[0], false, &input_idx)) break;
            if (!self.decodeBlock(&self.y_blocks[1], false, &input_idx)) break;
            if (!self.decodeBlock(&self.y_blocks[2], false, &input_idx)) break;
            if (!self.decodeBlock(&self.y_blocks[3], false, &input_idx)) break;
            self.assembleMacroblock();
        }
    }

    fn signExtend10(val: u16) i32 {
        var v = @as(i32, @intCast(val & 0x3FF));
        if ((v & 0x200) != 0) v |= ~@as(i32, 0x3FF);
        return v;
    }

    fn decodeBlock(self: *Mdec, block: *[64]i32, is_color: bool, input_idx: *usize) bool {
        @memset(block, 0);
        const q_table = if (is_color) &self.quant_color else &self.quant_luminance;

        // Block structure (Avocado algorithm.cpp:123 decodeBlock):
        //   (optional) 0xFE00 padding, DCT word, 0-63 RLE words, (optional) 0xFE00.
        while (input_idx.* < self.input_len and self.input_fifo[input_idx.*] == 0xFE00) {
            input_idx.* += 1;
        }
        if (input_idx.* >= self.input_len) return false;

        // DCT word: bits 9-0 = DC, bits 15-10 = quantization factor. The qFactor
        // scales every AC coefficient and is NOT the uploaded scale/IDCT table.
        const dct = self.input_fifo[input_idx.*];
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

            if (input_idx.* >= self.input_len) return false;
            const rle = self.input_fifo[input_idx.*];
            input_idx.* += 1;

            current = signExtend10(rle);
            n += @as(usize, (rle >> 10) & 0x3F) + 1;
            if (n >= 64) break;

            value = @divTrunc(current * @as(i32, q_table[n]) * q_factor + 4, 8);
        }

        self.idct(block);
        return true;
    }

    // Two-pass IDCT using the table the game uploads with MDEC(3), NOT a
    // hardcoded cosine matrix (Avocado algorithm.cpp:167 idct).
    fn idct(self: *Mdec, block: *[64]i32) void {
        var tmp: [64]i64 = @splat(0);

        for (0..8) |x| {
            for (0..8) |y| {
                var sum: i64 = 0;
                for (0..8) |i| {
                    sum += @as(i64, self.scale_table[i * 8 + y]) * @as(i64, block[x + i * 8]);
                }
                tmp[x + y * 8] = sum;
            }
        }

        for (0..8) |x| {
            for (0..8) |y| {
                var sum: i64 = 0;
                for (0..8) |i| {
                    sum += tmp[i + y * 8] * @as(i64, self.scale_table[x + i * 8]);
                }
                const round: i64 = (sum >> 31) & 1;
                // Avocado stores through an int16_t array; keep that truncation.
                block[x + y * 8] = @as(i16, @truncate((sum >> 32) + round));
            }
        }
    }

    fn assembleMacroblock(self: *Mdec) void {
        var pixel_latch: u32 = 0;

        for (0..16) |y| {
            for (0..16) |x| {
                const by = y >> 3;
                const bx = x >> 3;
                const block_idx = by * 2 + bx;

                const ly = y & 7;
                const lx = x & 7;

                const py = self.y_blocks[block_idx][ly * 8 + lx];

                // Cb and Cr are 4:2:0 subsampled, so we map 16x16 down to 8x8
                const pcb = self.cb_block[(y >> 1) * 8 + (x >> 1)];
                const pcr = self.cr_block[(y >> 1) * 8 + (x >> 1)];

                const rgb24 = ycrcb_to_rgb(py, pcr, pcb);

                if (self.output_depth == 3) {
                    // 15bpp (Used by PlayStation GPU)
                    const r = (rgb24 & 0xFF) >> 3;
                    const g = ((rgb24 >> 8) & 0xFF) >> 3;
                    const b = ((rgb24 >> 16) & 0xFF) >> 3;

                    // Bit 15 is STP (semi-transparency), from command bit 25.
                    const stp: u32 = if (self.output_set_bit15) 0x8000 else 0;
                    const rgb15 = r | (g << 5) | (b << 10) | stp;

                    // Pack two 15-bit pixels into one 32-bit word
                    if ((x & 1) == 0) {
                        pixel_latch = rgb15;
                    } else {
                        self.pushOutput(pixel_latch | (rgb15 << 16));
                    }
                } else {
                    // 24bpp (Used for raw 24-bit output, fallback)
                    self.pushOutput(rgb24);
                }
            }
        }
    }

    fn pushOutput(self: *Mdec, val: u32) void {
        if (self.output_len < 131072) {
            self.output_fifo[(self.output_ptr + self.output_len) % 131072] = val;
            self.output_len += 1;
        }
    }

    fn ycrcb_to_rgb(y: i32, cr: i32, cb: i32) u32 {
        // The IDCT output is signed and centred on 0, so the +128 bias is what
        // turns it back into an unsigned level (Avocado algorithm.cpp:62-64).
        var r = y + ((cr * 1435) >> 10) + 128;
        var g = y - ((cb * 352 + cr * 731) >> 10) + 128;
        var b = y + ((cb * 1814) >> 10) + 128;

        r = std.math.clamp(r, 0, 255);
        g = std.math.clamp(g, 0, 255);
        b = std.math.clamp(b, 0, 255);

        return @as(u32, @intCast(r)) | (@as(u32, @intCast(g)) << 8) | (@as(u32, @intCast(b)) << 16);
    }
};
