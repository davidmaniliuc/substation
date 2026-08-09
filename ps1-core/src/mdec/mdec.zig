const std = @import("std");
const algorithm = @import("algorithm.zig");

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

    /// MDEC_STAT bit layout (PSX-SPX; Avocado `MDEC::Status`, mdec.h:22-40):
    ///
    ///   31    data-out FIFO **empty**    30    data-in FIFO full
    ///   29    command busy               28    data-in request  (DMA0 enabled)
    ///   27    data-out request (DMA1)    26-25 output depth
    ///   24    output signed              23    output bit15
    ///   18-16 current block              15-0  parameter words remaining, minus 1
    ///
    /// Bit 31 reads *empty*, not "data ready". Every decoder poll loop spins
    /// waiting for it to go low, so inverting it hangs the caller outright —
    /// that is what the `mdec/4bit` and `mdec/8bit` ROMs do
    /// (`do { } while (stat < 0)`).
    ///
    /// Avocado never writes `currentBlock`, so bits 18-16 keep the reset value 4.
    const reset_status: u32 = 0x80040000;

    fn applyBit(value: u32, comptime bit: u5, set: bool) u32 {
        const mask = @as(u32, 1) << bit;
        return if (set) value | mask else value & ~mask;
    }

    pub fn init() Mdec {
        return .{ .status = reset_status };
    }

    fn reset(self: *Mdec) void {
        self.status = reset_status;
        self.words_remaining = 0;
        self.current_cmd = 0;
        self.input_len = 0;
        self.output_len = 0;
        self.output_ptr = 0;
        // The reset value clears the depth field, i.e. 4bpp (Avocado sets
        // `status._reg` wholesale, mdec.cpp:16).
        self.output_depth = 0;
        self.output_set_bit15 = false;
    }

    /// The three FIFO/busy bits are recomputed on every read rather than
    /// latched (Avocado mdec.cpp:66-70).
    pub fn readStatus(self: *Mdec) u32 {
        var stat = self.status;
        stat = applyBit(stat, 31, self.output_len == 0);
        stat = applyBit(stat, 30, self.input_len != 0);
        stat = applyBit(stat, 29, self.output_len != 0);
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

                // The command's output format is mirrored into STAT bits 26-23
                // (Avocado mdec.cpp:83-85). `outputSigned` is reported but not
                // yet honoured by the decoder — no test ROM exercises it.
                self.status = (self.status & ~@as(u32, 0x0F800000)) |
                    (@as(u32, self.output_depth) << 25) |
                    (if (val & (1 << 26) != 0) @as(u32, 1) << 24 else 0) |
                    (if (self.output_set_bit15) @as(u32, 1) << 23 else 0);

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

    /// The control register carries reset + the DMA enable bits only; the output
    /// depth belongs to the MDEC(1) command word (see writeCommandInternal).
    /// Latching it here made the depth depend on whichever control write
    /// happened last.
    pub fn writeControl(self: *Mdec, val: u32) void {
        if (val & (1 << 31) != 0) self.reset();

        // Bit 30 enables DMA0 and bit 29 enables DMA1; each gates the matching
        // request bit in STAT (Avocado mdec.cpp:191-193).
        self.status = applyBit(self.status, 28, val & (1 << 30) != 0);
        self.status = applyBit(self.status, 27, val & (1 << 29) != 0);
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

        // STAT bits 15-0 hold the remaining parameter word count *minus one*, so
        // an exhausted FIFO reads FFFFh (Avocado mdec.cpp:180-184).
        self.status = (self.status & 0xFFFF0000) | ((self.words_remaining -% 1) & 0xFFFF);
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
                    algorithm.decodeAllMacroblocks(self);
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

    /// Called across the algorithm.zig boundary as the pixel-packing paths
    /// finish each output word.
    pub fn pushOutput(self: *Mdec, val: u32) void {
        if (self.output_len < 131072) {
            self.output_fifo[(self.output_ptr + self.output_len) % 131072] = val;
            self.output_len += 1;
        }
    }
};
