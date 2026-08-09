const std = @import("std");
const Spu = @import("spu.zig").Spu;
const Adsr = @import("adsr.zig");
const AdsrState = Adsr.AdsrState;

const adpcm_filters = [5][2]i32{
    .{ 0, 0 },
    .{ 60, 0 },
    .{ 115, -52 },
    .{ 98, -55 },
    .{ 122, -60 },
};

pub fn decodeBlock(block: *const [16]u8, old: *i32, older: *i32, out_pcm: *[28]i16) void {
    const shift_factor = block[0] & 0x0F;
    const filter = (block[0] >> 4) & 0x07;

    // Shift factor is subtracted from 12. If shift_factor > 12, shift is often 0 or clamped.
    const shift = if (shift_factor <= 12) 12 - @as(u5, @truncate(shift_factor)) else 0;

    const f0 = if (filter < 5) adpcm_filters[filter][0] else 0;
    const f1 = if (filter < 5) adpcm_filters[filter][1] else 0;

    var pcm_idx: usize = 0;
    for (block[2..16]) |byte| {
        for (0..2) |nibble_idx| {
            const nibble = if (nibble_idx == 0) (byte & 0x0F) else (byte >> 4);
            // Sign-extend 4-bit to 32-bit i32
            const sample: i32 = @as(i4, @bitCast(@as(u4, @truncate(nibble))));

            var val: i32 = sample << shift;

            // IIR Filter
            val += @divFloor(old.* * f0 + older.* * f1 + 32, 64);

            const clamped = std.math.clamp(val, -32768, 32767);

            older.* = old.*;
            old.* = clamped;

            out_pcm[pcm_idx] = @intCast(clamped);
            pcm_idx += 1;
        }
    }
}

pub const Voice = struct {
    /// The 8 register-backed words software reads and writes (0x1F801C00+).
    regs: struct {
        vol_l: i16 = 0,
        vol_r: i16 = 0,
        pitch: u16 = 0,
        start_addr: u16 = 0,
        adsr1: u16 = 0,
        adsr2: u16 = 0,
        adsr_vol: i16 = 0,
        loop_addr: u16 = 0,
    } = .{},

    /// ADPCM decode position and predictor history.
    adpcm: struct {
        current_addr: u32 = 0,
        current_fraction: u16 = 0,
        old: i32 = 0,
        older: i32 = 0,
        decoded_buffer: [28]i16 = [_]i16{0} ** 28,
        history: [4]i16 = [_]i16{0} ** 4,
        buffer_index: usize = 28, // starts at 28 to trigger the first decode
    } = .{},

    /// Envelope state machine.
    env: struct {
        state: AdsrState = .Off,
        current_ad_vol: i32 = 0, // 0..0x7FFF
        cycles: u32 = 0,
    } = .{},

    is_on: bool = false,
    ignore_samples: bool = false,
    has_reached_endx: bool = false,

    pub fn read(self: *const Voice, reg_idx: u32) u16 {
        return switch (reg_idx) {
            0 => @bitCast(self.regs.vol_l),
            1 => @bitCast(self.regs.vol_r),
            2 => self.regs.pitch,
            3 => self.regs.start_addr,
            4 => self.regs.adsr1,
            5 => self.regs.adsr2,
            6 => @bitCast(@as(i16, @truncate(self.env.current_ad_vol))),
            7 => self.regs.loop_addr,
            else => 0,
        };
    }

    pub fn write(self: *Voice, reg_idx: u32, value: u16) void {
        switch (reg_idx) {
            0 => self.regs.vol_l = @bitCast(value),
            1 => self.regs.vol_r = @bitCast(value),
            2 => self.regs.pitch = value,
            3 => self.regs.start_addr = value,
            4 => self.regs.adsr1 = value,
            5 => self.regs.adsr2 = value,
            6 => self.regs.adsr_vol = @bitCast(value),
            7 => self.regs.loop_addr = value,
            else => {},
        }
    }

    pub fn keyOn(self: *Voice) void {
        self.is_on = true;
        self.adpcm.current_addr = @as(u32, self.regs.start_addr) << 3;
        self.adpcm.buffer_index = 28;
        self.adpcm.current_fraction = 0;
        self.adpcm.old = 0;
        self.adpcm.older = 0;
        self.adpcm.history = [_]i16{0} ** 4;
        self.ignore_samples = false;
        self.has_reached_endx = false;

        // Reset envelope
        self.env.state = .Attack;
        self.env.current_ad_vol = 0;
        self.env.cycles = 0;
    }

    pub fn keyOff(self: *Voice) void {
        // Don't turn is_on to false instantly! Move to Release phase.
        self.env.state = .Release;
        self.env.cycles = 0;
    }

    pub const stepAdsr = Adsr.step;

    pub fn fetchAndDecode(self: *Voice, spu: *Spu) void {
        const sram = &spu.sram;
        if (self.ignore_samples) {
            @memset(&self.adpcm.decoded_buffer, 0);
            self.adpcm.buffer_index = 0;
            return;
        }

        const addr = self.adpcm.current_addr & 0x7FFF0;
        spu.checkIrq(addr);
        spu.checkIrq(addr + 8);
        var block: [16]u8 = undefined;
        @memcpy(&block, sram[addr..][0..16]);

        decodeBlock(&block, &self.adpcm.old, &self.adpcm.older, &self.adpcm.decoded_buffer);
        self.adpcm.buffer_index = 0;

        const flags = block[1];
        if ((flags & 4) != 0) {
            self.regs.loop_addr = @truncate(addr >> 3);
        }

        if ((flags & 1) != 0) { // End of sample
            self.has_reached_endx = true;
            if ((flags & 2) != 0) { // Loop - jump to loop_addr, don't advance
                self.adpcm.current_addr = @as(u32, self.regs.loop_addr) << 3;
            } else {
                self.env.state = .Release;
                self.env.cycles = 0;
                self.ignore_samples = true;
                self.adpcm.current_addr = (self.adpcm.current_addr + 16) & 0x7FFFF;
            }
        } else {
            self.adpcm.current_addr = (self.adpcm.current_addr + 16) & 0x7FFFF;
        }
    }
};
