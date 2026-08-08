const std = @import("std");

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

pub const AdsrState = enum {
    Off,
    Attack,
    Decay,
    Sustain,
    Release,
};

pub const Voice = struct {
    vol_l: i16 = 0,
    vol_r: i16 = 0,
    pitch: u16 = 0,
    start_addr: u16 = 0,
    adsr1: u16 = 0,
    adsr2: u16 = 0,
    adsr_vol: i16 = 0,
    loop_addr: u16 = 0,

    // Internal state
    current_addr: u32 = 0,
    current_fraction: u16 = 0,
    adpcm_old: i32 = 0,
    adpcm_older: i32 = 0,
    decoded_buffer: [28]i16 = [_]i16{0} ** 28,
    history: [4]i16 = [_]i16{0} ** 4,
    buffer_index: usize = 28, // Start at 28 to trigger decode
    is_on: bool = false,
    ignore_samples: bool = false,
    has_reached_endx: bool = false,

    // ADSR State
    adsr_state: AdsrState = .Off,
    current_ad_vol: i32 = 0, // Ranging from 0 to 0x7FFF
    adsr_cycles: u32 = 0,

    pub fn read(self: *const Voice, reg_idx: u32) u16 {
        return switch (reg_idx) {
            0 => @bitCast(self.vol_l),
            1 => @bitCast(self.vol_r),
            2 => self.pitch,
            3 => self.start_addr,
            4 => self.adsr1,
            5 => self.adsr2,
            6 => @bitCast(@as(i16, @truncate(self.current_ad_vol))),
            7 => self.loop_addr,
            else => 0,
        };
    }

    pub fn write(self: *Voice, reg_idx: u32, value: u16) void {
        switch (reg_idx) {
            0 => self.vol_l = @bitCast(value),
            1 => self.vol_r = @bitCast(value),
            2 => self.pitch = value,
            3 => self.start_addr = value,
            4 => self.adsr1 = value,
            5 => self.adsr2 = value,
            6 => self.adsr_vol = @bitCast(value),
            7 => self.loop_addr = value,
            else => {},
        }
    }

    pub fn keyOn(self: *Voice) void {
        self.is_on = true;
        self.current_addr = @as(u32, self.start_addr) << 3;
        self.buffer_index = 28;
        self.current_fraction = 0;
        self.adpcm_old = 0;
        self.adpcm_older = 0;
        self.history = [_]i16{0} ** 4;
        self.ignore_samples = false;
        self.has_reached_endx = false;

        // Reset envelope
        self.adsr_state = .Attack;
        self.current_ad_vol = 0;
        self.adsr_cycles = 0;
    }

    pub fn keyOff(self: *Voice) void {
        // Don't turn is_on to false instantly! Move to Release phase.
        self.adsr_state = .Release;
        self.adsr_cycles = 0;
    }

    pub fn stepAdsr(self: *Voice) void {
        if (self.adsr_state == .Off) {
            self.current_ad_vol = 0;
            return;
        }

        const ar = (self.adsr1 >> 8) & 0x7F;
        const ar_shift = (ar >> 2) & 0x1F;
        const ar_step = @as(i32, ar & 3) + 4;

        const dr_shift = (self.adsr1 >> 4) & 0x0F;
        const dr_step: i32 = 8;

        var sl = (@as(i32, @intCast(self.adsr1 & 0x0F)) + 1) * 0x800;
        if (sl > 0x7FFF) sl = 0x7FFF;

        const sr = (self.adsr2 >> 6) & 0x7F;
        const sr_shift = (sr >> 2) & 0x1F;
        const sr_step = @as(i32, sr & 3) + 4;

        const rr_shift = self.adsr2 & 0x1F;
        const rr_step: i32 = 8;

        var shift: u32 = 0;
        var step: i32 = 0;
        var is_decrease = false;
        var is_exponential = false;

        switch (self.adsr_state) {
            .Attack => {
                shift = ar_shift;
                step = ar_step;
                is_exponential = ((self.adsr1 & 0x8000) != 0);
                is_decrease = false;
            },
            .Decay => {
                shift = dr_shift;
                step = dr_step;
                is_exponential = true;
                is_decrease = true;
            },
            .Sustain => {
                shift = sr_shift;
                is_decrease = ((self.adsr2 & 0x4000) != 0);
                if (is_decrease) {
                    step = 8;
                    is_exponential = true;
                } else {
                    step = sr_step;
                    is_exponential = ((self.adsr2 & 0x8000) != 0);
                }
            },
            .Release => {
                shift = rr_shift;
                step = rr_step;
                is_exponential = true;
                is_decrease = true;
            },
            .Off => return,
        }

        // Exponential increase: slow down when level > 0x6000 (hardware "fake" exponential)
        var cycles = if (shift > 11) @as(u32, 1) << @as(u5, @truncate(shift - 11)) else 1;
        if (is_exponential and !is_decrease and self.current_ad_vol > 0x6000) {
            cycles *= 4;
        }
        self.adsr_cycles += 1;
        if (self.adsr_cycles < cycles) return;
        self.adsr_cycles = 0;

        const shift_diff = if (shift < 11) (11 - shift) else 0;
        var actual_step = step << @as(u5, @truncate(shift_diff));

        if (is_exponential and is_decrease) {
            // Exponential decrease: the step scales with the current volume.
            // Avocado (voice.cpp:67-73) keeps the step NEGATIVE and arithmetic-
            // shifts it, so the magnitude can never round down to 0 -- that is
            // what guarantees a release actually terminates. Our step is
            // positive, so negate around the shift to get the same floor-toward
            // -infinity behaviour. Scaling the positive step directly floors to
            // 0 instead and strands the voice at a small non-zero level with
            // `is_on` set forever; games that poll for a free voice then never
            // trigger another sound effect.
            actual_step = -((-actual_step * self.current_ad_vol) >> 15);
        }

        if (is_decrease) {
            self.current_ad_vol -= actual_step;
            if (self.current_ad_vol < 0) self.current_ad_vol = 0;
        } else {
            self.current_ad_vol += actual_step;
            if (self.current_ad_vol > 0x7FFF) self.current_ad_vol = 0x7FFF;
        }

        switch (self.adsr_state) {
            .Attack => {
                if (self.current_ad_vol >= 0x7FFF) {
                    self.current_ad_vol = 0x7FFF;
                    self.adsr_state = .Decay;
                    self.adsr_cycles = 0;
                }
            },
            .Decay => {
                if (self.current_ad_vol <= sl) {
                    self.current_ad_vol = sl;
                    self.adsr_state = .Sustain;
                    self.adsr_cycles = 0;
                }
            },
            .Sustain => {},
            .Release => {
                if (self.current_ad_vol <= 0) {
                    self.current_ad_vol = 0;
                    self.adsr_state = .Off;
                    self.is_on = false;
                    self.adsr_cycles = 0;
                }
            },
            .Off => {},
        }
    }

    pub fn fetchAndDecode(self: *Voice, spu: *Spu) void {
        const sram = &spu.sram;
        if (self.ignore_samples) {
            @memset(&self.decoded_buffer, 0);
            self.buffer_index = 0;
            return;
        }

        const addr = self.current_addr & 0x7FFF0;
        spu.checkIrq(addr);
        spu.checkIrq(addr + 8);
        var block: [16]u8 = undefined;
        @memcpy(&block, sram[addr..][0..16]);

        decodeBlock(&block, &self.adpcm_old, &self.adpcm_older, &self.decoded_buffer);
        self.buffer_index = 0;

        const flags = block[1];
        if ((flags & 4) != 0) {
            self.loop_addr = @truncate(addr >> 3);
        }

        if ((flags & 1) != 0) { // End of sample
            self.has_reached_endx = true;
            if ((flags & 2) != 0) { // Loop - jump to loop_addr, don't advance
                self.current_addr = @as(u32, self.loop_addr) << 3;
            } else {
                self.adsr_state = .Release;
                self.adsr_cycles = 0;
                self.ignore_samples = true;
                self.current_addr = (self.current_addr + 16) & 0x7FFFF;
            }
        } else {
            self.current_addr = (self.current_addr + 16) & 0x7FFFF;
        }
    }
};

pub const Spu = struct {
    const Self = @This();

    // SPU has 512KB of Sound RAM
    sram: [512 * 1024]u8 = [_]u8{0} ** (512 * 1024),

    // Registers
    main_vol_l: i16 = 0,
    main_vol_r: i16 = 0,
    reverb_vol_l: i16 = 0,
    reverb_vol_r: i16 = 0,

    spu_cnt: u16 = 0, // SPU Control (1F801DAAh)
    spu_stat: u16 = 0, // SPU Status  (1F801DAEh)
    sram_addr: u32 = 0, // Internal Sound RAM byte address
    sram_read_buffer: u16 = 0, // Hardware prefetch buffer for reads
    dtc: u16 = 4, // DMA Transfer Control (1F801DACh)

    pmon: u32 = 0,
    non: u32 = 0,
    von: u32 = 0,

    noise_timer: i32 = 0,
    noise_lfsr: u32 = 1,
    noise_level: i32 = 0,

    cd_vol_l: i16 = 0,
    cd_vol_r: i16 = 0,
    ext_vol_l: i16 = 0,
    ext_vol_r: i16 = 0,

    current_cd_l: i16 = 0,
    current_cd_r: i16 = 0,
    current_ext_l: i16 = 0,
    current_ext_r: i16 = 0,

    irq_addr: u16 = 0, // IRQ Address (1F801DA4h)
    irq_flag: bool = false,

    reverb_regs: [32]i16 = [_]i16{0} ** 32,
    reverb_base: u16 = 0,
    reverb_curr_addr: u32 = 0,

    voices: [24]Voice = [_]Voice{.{}} ** 24,

    // Expanded to 65536 to hold more than a full frame of audio safely
    output_buffer: [65536]f32 = [_]f32{0} ** 65536,
    write_idx: usize = 0,
    read_idx: usize = 0,

    cycle_accumulator: u32 = 0,

    pub fn init() Self {
        return .{};
    }

    pub fn read(self: *Self, offset: u32) u16 {
        return switch (offset) {
            0x1D80 => @bitCast(self.main_vol_l),
            0x1D82 => @bitCast(self.main_vol_r),
            0x1D84 => @bitCast(self.reverb_vol_l),
            0x1D86 => @bitCast(self.reverb_vol_r),
            0x1D88 => { // Voice 0..15 ON/OFF status
                var mask: u16 = 0;
                for (0..16) |i| {
                    if (self.voices[i].is_on) mask |= (@as(u16, 1) << @as(u4, @truncate(i)));
                }
                return mask;
            },
            0x1D8A => { // Voice 16..23 ON/OFF status
                var mask: u16 = 0;
                for (0..8) |i| {
                    if (self.voices[16 + i].is_on) mask |= (@as(u16, 1) << @as(u4, @truncate(i)));
                }
                return mask;
            },
            0x1D90 => @truncate(self.pmon),
            0x1D92 => @truncate(self.pmon >> 16),
            0x1D94 => @truncate(self.non),
            0x1D96 => @truncate(self.non >> 16),
            0x1D98 => @truncate(self.von),
            0x1D9A => @truncate(self.von >> 16),
            0x1D9C => { // Voice 0..15 ENDX status
                var mask: u16 = 0;
                for (0..16) |i| {
                    if (self.voices[i].has_reached_endx) mask |= (@as(u16, 1) << @as(u4, @truncate(i)));
                }
                return mask;
            },
            0x1D9E => { // Voice 16..23 ENDX status
                var mask: u16 = 0;
                for (0..8) |i| {
                    if (self.voices[16 + i].has_reached_endx) mask |= (@as(u16, 1) << @as(u4, @truncate(i)));
                }
                return mask;
            },
            0x1DA2 => self.reverb_base,
            0x1DA4 => self.irq_addr,
            0x1DA6 => @truncate(self.sram_addr >> 3),
            0x1DA8 => self.readSram(),
            0x1DAA => self.spu_cnt,
            0x1DAC => self.dtc,
            0x1DAE => self.getStatus(),
            0x1DB0 => @bitCast(self.cd_vol_l),
            0x1DB2 => @bitCast(self.cd_vol_r),
            0x1DB4 => @bitCast(self.ext_vol_l),
            0x1DB6 => @bitCast(self.ext_vol_r),
            0x1DB8...0x1DBF => 0,
            0x1DC0...0x1DFF => @bitCast(self.reverb_regs[(offset - 0x1DC0) >> 1]),
            else => {
                // Voice range: 0x1C00 - 0x1D7F
                if (offset >= 0x1C00 and offset < 0x1D80) {
                    const voice_idx = (offset - 0x1C00) >> 4;
                    const reg_idx = (offset & 0xF) >> 1;
                    return self.voices[voice_idx].read(reg_idx);
                }
                return 0;
            },
        };
    }

    pub fn write(self: *Self, offset: u32, value: u16) void {
        switch (offset) {
            0x1D80 => self.main_vol_l = @bitCast(value),
            0x1D82 => self.main_vol_r = @bitCast(value),
            0x1D84 => self.reverb_vol_l = @bitCast(value),
            0x1D86 => self.reverb_vol_r = @bitCast(value),
            0x1D88 => { // Key ON 0..15
                for (0..16) |i| {
                    if ((value & (@as(u16, 1) << @as(u4, @truncate(i)))) != 0) {
                        self.voices[i].keyOn();
                    }
                }
            },
            0x1D8A => { // Key ON 16..23
                for (0..8) |i| {
                    if ((value & (@as(u16, 1) << @as(u4, @truncate(i)))) != 0) {
                        self.voices[16 + i].keyOn();
                    }
                }
            },
            0x1D8C => { // Key OFF 0..15
                for (0..16) |i| {
                    if ((value & (@as(u16, 1) << @as(u4, @truncate(i)))) != 0) {
                        self.voices[i].keyOff();
                    }
                }
            },
            0x1D8E => { // Key OFF 16..23
                for (0..8) |i| {
                    if ((value & (@as(u16, 1) << @as(u4, @truncate(i)))) != 0) {
                        self.voices[16 + i].keyOff();
                    }
                }
            },
            0x1D90 => self.pmon = (self.pmon & 0xFFFF0000) | value,
            0x1D92 => self.pmon = (self.pmon & 0x0000FFFF) | (@as(u32, value) << 16),
            0x1D94 => self.non = (self.non & 0xFFFF0000) | value,
            0x1D96 => self.non = (self.non & 0x0000FFFF) | (@as(u32, value) << 16),
            0x1D98 => self.von = (self.von & 0xFFFF0000) | value,
            0x1D9A => self.von = (self.von & 0x0000FFFF) | (@as(u32, value) << 16),
            0x1DA2 => self.reverb_base = value,
            0x1DA4 => self.irq_addr = value,
            0x1DA6 => self.sram_addr = @as(u32, value) << 3,
            0x1DA8 => self.writeSram(value),
            0x1DAA => {
                self.spu_cnt = value;
                if ((value & (1 << 6)) == 0) {
                    self.irq_flag = false;
                }
                // Bit 0-5 of SPUSTAT are a copy of Bit 0-5 of SPUCNT
                self.spu_stat = (self.spu_stat & ~@as(u16, 0x3F)) | (value & 0x3F);
            },
            0x1DAC => self.dtc = value,
            0x1DB0 => self.cd_vol_l = @bitCast(value),
            0x1DB2 => self.cd_vol_r = @bitCast(value),
            0x1DB4 => self.ext_vol_l = @bitCast(value),
            0x1DB6 => self.ext_vol_r = @bitCast(value),
            0x1DB8...0x1DBF => {},
            0x1DC0...0x1DFF => self.reverb_regs[(offset - 0x1DC0) >> 1] = @bitCast(value),
            else => {
                if (offset >= 0x1C00 and offset < 0x1D80) {
                    const voice_idx = (offset - 0x1C00) >> 4;
                    const reg_idx = (offset & 0xF) >> 1;
                    self.voices[voice_idx].write(reg_idx, value);
                }
            },
        }
    }

    fn getStatus(self: *const Self) u16 {
        var stat = self.spu_stat & 0x7FF;
        if (self.irq_flag) stat |= (1 << 6);
        return stat;
    }

    pub fn pushCdAudio(self: *Self, left: i16, right: i16) void {
        self.current_cd_l = left;
        self.current_cd_r = right;
    }

    pub fn pushExtAudio(self: *Self, left: i16, right: i16) void {
        self.current_ext_l = left;
        self.current_ext_r = right;
    }

    fn wrapReverbAddr(self: *Self, address: u32) u32 {
        const reverb_base_addr = @as(u32, self.reverb_base) * 8;
        const size = (512 * 1024) - reverb_base_addr;
        if (size == 0) return reverb_base_addr;

        var rel = @as(i32, @bitCast(address)) - @as(i32, @bitCast(reverb_base_addr));
        rel = @rem(rel, @as(i32, @intCast(size)));
        if (rel < 0) rel += @as(i32, @intCast(size));

        return (reverb_base_addr + @as(u32, @intCast(rel))) & 0x7FFFE;
    }

    fn readReverbSram(self: *Self, address: u32) i32 {
        const addr = self.wrapReverbAddr(self.reverb_curr_addr + address);
        const val = std.mem.readInt(u16, self.sram[addr..][0..2], .little);
        return @as(i16, @bitCast(val));
    }

    fn writeReverbSram(self: *Self, address: u32, sample: i32) void {
        const clamped = std.math.clamp(sample, -32768, 32767);
        const u16_val = @as(u16, @bitCast(@as(i16, @intCast(clamped))));
        const addr = self.wrapReverbAddr(self.reverb_curr_addr + address);
        std.mem.writeInt(u16, self.sram[addr..][0..2], u16_val, .little);
    }

    /// Avocado's `Sample` type (avocado_ref/src/device/spu/sample.h) saturates to
    /// i16 on every `+` and `-`, but not on `*`. Reverb expressions must therefore
    /// clamp after each add and subtract, not once at the end of the expression:
    /// {20000, 20000, -20000, -20000} sums to -7233 with per-step saturation and to
    /// 0 without it.
    fn sat(v: i32) i32 {
        return std.math.clamp(v, -32768, 32767);
    }

    /// One 22.05 kHz reverb tick. Public so `spu_test.zig` can drive it
    /// directly against the Avocado goldens.
    pub fn doReverb(self: *Self, left_in: i32, right_in: i32) struct { l: i32, r: i32 } {
        // Registers
        const dAPF1 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x00]))) * 8;
        const dAPF2 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x01]))) * 8;
        const vIIR = @as(i32, self.reverb_regs[0x02]);
        const vCOMB1 = @as(i32, self.reverb_regs[0x03]);
        const vCOMB2 = @as(i32, self.reverb_regs[0x04]);
        const vCOMB3 = @as(i32, self.reverb_regs[0x05]);
        const vCOMB4 = @as(i32, self.reverb_regs[0x06]);
        const vWALL = @as(i32, self.reverb_regs[0x07]);
        const vAPF1 = @as(i32, self.reverb_regs[0x08]);
        const vAPF2 = @as(i32, self.reverb_regs[0x09]);
        const mLSAME = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x0A]))) * 8;
        const mRSAME = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x0B]))) * 8;
        const mLCOMB1 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x0C]))) * 8;
        const mRCOMB1 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x0D]))) * 8;
        const mLCOMB2 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x0E]))) * 8;
        const mRCOMB2 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x0F]))) * 8;
        const dLSAME = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x10]))) * 8;
        const dRSAME = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x11]))) * 8;
        const mLDIFF = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x12]))) * 8;
        const mRDIFF = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x13]))) * 8;
        const mLCOMB3 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x14]))) * 8;
        const mRCOMB3 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x15]))) * 8;
        const mLCOMB4 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x16]))) * 8;
        const mRCOMB4 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x17]))) * 8;
        const dLDIFF = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x18]))) * 8;
        const dRDIFF = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x19]))) * 8;
        const mLAPF1 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x1A]))) * 8;
        const mRAPF1 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x1B]))) * 8;
        const mLAPF2 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x1C]))) * 8;
        const mRAPF2 = @as(u32, @as(u16, @bitCast(self.reverb_regs[0x1D]))) * 8;
        const vLIN = @as(i32, self.reverb_regs[0x1E]);
        const vRIN = @as(i32, self.reverb_regs[0x1F]);

        const clamped_left_in = std.math.clamp(left_in, -32768, 32767);
        const clamped_right_in = std.math.clamp(right_in, -32768, 32767);

        const Lin = (clamped_left_in * vLIN) >> 15;
        const Rin = (clamped_right_in * vRIN) >> 15;

        // IIR Filters
        var val: i32 = 0;
        val = sat(sat(Lin + ((self.readReverbSram(dLSAME) * vWALL) >> 15)) - self.readReverbSram(mLSAME -% 2));
        self.writeReverbSram(mLSAME, ((val * vIIR) >> 15) + self.readReverbSram(mLSAME -% 2));

        val = sat(sat(Rin + ((self.readReverbSram(dRSAME) * vWALL) >> 15)) - self.readReverbSram(mRSAME -% 2));
        self.writeReverbSram(mRSAME, ((val * vIIR) >> 15) + self.readReverbSram(mRSAME -% 2));

        val = sat(sat(Lin + ((self.readReverbSram(dRDIFF) * vWALL) >> 15)) - self.readReverbSram(mLDIFF -% 2));
        self.writeReverbSram(mLDIFF, ((val * vIIR) >> 15) + self.readReverbSram(mLDIFF -% 2));

        val = sat(sat(Rin + ((self.readReverbSram(dLDIFF) * vWALL) >> 15)) - self.readReverbSram(mRDIFF -% 2));
        self.writeReverbSram(mRDIFF, ((val * vIIR) >> 15) + self.readReverbSram(mRDIFF -% 2));

        // COMB Filters. Accumulated one term at a time so each partial sum
        // saturates, matching Avocado's left-associative chain of clamping
        // Sample::operator+ calls.
        var Lout: i32 = sat((vCOMB1 * self.readReverbSram(mLCOMB1)) >> 15);
        Lout = sat(Lout + ((vCOMB2 * self.readReverbSram(mLCOMB2)) >> 15));
        Lout = sat(Lout + ((vCOMB3 * self.readReverbSram(mLCOMB3)) >> 15));
        Lout = sat(Lout + ((vCOMB4 * self.readReverbSram(mLCOMB4)) >> 15));

        var Rout: i32 = sat((vCOMB1 * self.readReverbSram(mRCOMB1)) >> 15);
        Rout = sat(Rout + ((vCOMB2 * self.readReverbSram(mRCOMB2)) >> 15));
        Rout = sat(Rout + ((vCOMB3 * self.readReverbSram(mRCOMB3)) >> 15));
        Rout = sat(Rout + ((vCOMB4 * self.readReverbSram(mRCOMB4)) >> 15));

        // APF Filters
        Lout = std.math.clamp(Lout - ((vAPF1 * self.readReverbSram(mLAPF1 -% dAPF1)) >> 15), -32768, 32767);
        self.writeReverbSram(mLAPF1, Lout);
        Lout = std.math.clamp(((Lout * vAPF1) >> 15) + self.readReverbSram(mLAPF1 -% dAPF1), -32768, 32767);

        Rout = std.math.clamp(Rout - ((vAPF1 * self.readReverbSram(mRAPF1 -% dAPF1)) >> 15), -32768, 32767);
        self.writeReverbSram(mRAPF1, Rout);
        Rout = std.math.clamp(((Rout * vAPF1) >> 15) + self.readReverbSram(mRAPF1 -% dAPF1), -32768, 32767);

        Lout = std.math.clamp(Lout - ((vAPF2 * self.readReverbSram(mLAPF2 -% dAPF2)) >> 15), -32768, 32767);
        self.writeReverbSram(mLAPF2, Lout);
        Lout = std.math.clamp(((Lout * vAPF2) >> 15) + self.readReverbSram(mLAPF2 -% dAPF2), -32768, 32767);

        Rout = std.math.clamp(Rout - ((vAPF2 * self.readReverbSram(mRAPF2 -% dAPF2)) >> 15), -32768, 32767);
        self.writeReverbSram(mRAPF2, Rout);
        Rout = std.math.clamp(((Rout * vAPF2) >> 15) + self.readReverbSram(mRAPF2 -% dAPF2), -32768, 32767);

        // Advance Window
        self.reverb_curr_addr = self.wrapReverbAddr(self.reverb_curr_addr + 2);

        // Final Volume Mix
        const rev_l_clean = @as(i32, self.reverb_vol_l);
        const rev_r_clean = @as(i32, self.reverb_vol_r);
        return .{
            .l = (Lout * rev_l_clean) >> 15,
            .r = (Rout * rev_r_clean) >> 15,
        };
    }

    pub fn checkIrq(self: *Self, addr: u32) void {
        if ((addr & 0x7FFF8) == (@as(u32, self.irq_addr) << 3)) {
            if ((self.spu_cnt & (1 << 6)) != 0) {
                self.irq_flag = true;
            }
        }
    }

    /// Used by DMA Channel 4 to push data into Sound RAM
    pub fn writeSram(self: *Self, value: u16) void {
        const addr = self.sram_addr & 0x7FFFF;
        self.checkIrq(addr);
        if (addr + 1 < self.sram.len) {
            std.mem.writeInt(u16, self.sram[addr..][0..2], value, .little);
        }
        self.sram_addr = (self.sram_addr + 2) & 0x7FFFF;
    }

    pub fn readSram(self: *Self) u16 {
        const return_val = self.sram_read_buffer;

        const addr = self.sram_addr & 0x7FFFF;
        self.checkIrq(addr);
        if (addr + 1 < self.sram.len) {
            self.sram_read_buffer = std.mem.readInt(u16, self.sram[addr..][0..2], .little);
        } else {
            self.sram_read_buffer = 0;
        }

        self.sram_addr = (self.sram_addr + 2) & 0x7FFFF;
        return return_val;
    }

    pub fn dmaReadSram(self: *Self) u16 {
        const addr = self.sram_addr & 0x7FFFF;
        self.checkIrq(addr);
        const value = if (addr + 1 < self.sram.len)
            std.mem.readInt(u16, self.sram[addr..][0..2], .little)
        else
            0;

        self.sram_addr = (self.sram_addr + 2) & 0x7FFFF;
        return value;
    }

    pub fn step(self: *Self, cpu_cycles: u32) void {
        self.cycle_accumulator += cpu_cycles;
        // 33.868 MHz / 44100 Hz = 768.004...
        while (self.cycle_accumulator >= 768) {
            self.cycle_accumulator -= 768;
            self.generateSample();
        }
    }

    fn generateSample(self: *Self) void {
        var left_mix: i32 = 0;
        var right_mix: i32 = 0;
        var left_reverb_mix: i32 = 0;
        var right_reverb_mix: i32 = 0;

        // Tick Noise LFSR
        const noise_step = @as(i32, (self.spu_cnt >> 8) & 3) + 4; // 4..7
        const noise_shift = @as(u4, @truncate((self.spu_cnt >> 10) & 15));

        self.noise_timer -= noise_step;
        if (self.noise_timer <= 0) {
            self.noise_timer += (@as(i32, 0x20000) >> noise_shift);

            const lfsr = self.noise_lfsr;
            const parity = ((lfsr >> 15) & 1) ^ ((lfsr >> 12) & 1) ^ ((lfsr >> 11) & 1) ^ ((lfsr >> 10) & 1) ^ 1;
            self.noise_lfsr = (lfsr << 1) | parity;
            self.noise_level = @as(i16, @bitCast(@as(u16, @truncate(self.noise_lfsr))));
        }

        var prev_voice_sample: i32 = 0;

        for (&self.voices, 0..) |*voice, voice_idx| {
            if (!voice.is_on) {
                prev_voice_sample = 0;
                continue;
            }

            // Ensure we have valid decoded data BEFORE reading
            if (voice.buffer_index >= 28) {
                voice.fetchAndDecode(self);
            }

            if (!voice.is_on) {
                prev_voice_sample = 0;
                continue; // Voice might have ended during fetch
            }

            // --- READ sample FIRST at current position ---
            const frac = @as(u32, voice.current_fraction);
            const ind: usize = (frac >> 4) & 0xFF; // 8-bit index

            const spu_gauss = @import("spu_gauss.zig").spu_gauss;
            var out: i32 = 0;
            out += (@as(i32, voice.history[0]) * @as(i32, spu_gauss[0x0FF - ind])) >> 15;
            out += (@as(i32, voice.history[1]) * @as(i32, spu_gauss[0x1FF - ind])) >> 15;
            out += (@as(i32, voice.history[2]) * @as(i32, spu_gauss[0x100 + ind])) >> 15;
            out += (@as(i32, voice.history[3]) * @as(i32, spu_gauss[0x000 + ind])) >> 15;

            var sample = out;

            // Save raw sample for next voice PMON
            const current_raw_sample = sample;
            prev_voice_sample = current_raw_sample;

            // Check NON
            if ((self.non & (@as(u32, 1) << @as(u5, @truncate(voice_idx)))) != 0) {
                sample = self.noise_level;
            }

            // Apply the ADSR Envelope to the raw PCM sample
            voice.stepAdsr();

            if (!voice.is_on) continue; // It might have died during Release

            const enveloped_sample = (sample * voice.current_ad_vol) >> 15;

            // Strip the 15th bit (Sweep flag) so it doesn't invert phase as a negative i16
            const vol_l_clean = @as(i32, @intCast(voice.vol_l & 0x3FFF));
            const vol_r_clean = @as(i32, @intCast(voice.vol_r & 0x3FFF));

            const left_voice = (enveloped_sample * vol_l_clean) >> 14;
            const right_voice = (enveloped_sample * vol_r_clean) >> 14;
            left_mix += left_voice;
            right_mix += right_voice;

            if ((self.von & (@as(u32, 1) << @as(u5, @truncate(voice_idx)))) != 0) {
                left_reverb_mix += left_voice;
                right_reverb_mix += right_voice;
            }

            // --- THEN advance the pitch counter ---
            var pitch_clamped = if (voice.pitch > 0x3FFF) @as(u16, 0x3FFF) else voice.pitch;

            // Check PMON
            if ((self.pmon & (@as(u32, 1) << @as(u5, @truncate(voice_idx)))) != 0) {
                const mod_factor = prev_voice_sample + 0x8000;
                const modulated = (@as(i64, pitch_clamped) * mod_factor) >> 15;
                pitch_clamped = @intCast(std.math.clamp(modulated, 0, 0x3FFF));
            }

            const total_fraction = @as(u32, voice.current_fraction) + pitch_clamped;
            const advance = total_fraction >> 12;
            voice.current_fraction = @truncate(total_fraction & 0xFFF);

            for (0..advance) |_| {
                if (voice.buffer_index >= 28) {
                    voice.fetchAndDecode(self);
                    if (!voice.is_on) {
                        break;
                    }
                }

                voice.history[0] = voice.history[1];
                voice.history[1] = voice.history[2];
                voice.history[2] = voice.history[3];
                voice.history[3] = voice.decoded_buffer[voice.buffer_index];
                voice.buffer_index += 1;
            }
        }

        // CD-ROM Audio Mix
        if ((self.spu_cnt & (1 << 0)) != 0) {
            const cd_l_clean = @as(i32, @intCast(self.cd_vol_l & 0x3FFF));
            const cd_r_clean = @as(i32, @intCast(self.cd_vol_r & 0x3FFF));
            left_mix += (@as(i32, self.current_cd_l) * cd_l_clean) >> 14;
            right_mix += (@as(i32, self.current_cd_r) * cd_r_clean) >> 14;
        }

        // External Audio Mix
        if ((self.spu_cnt & (1 << 1)) != 0) {
            const ext_l_clean = @as(i32, @intCast(self.ext_vol_l & 0x3FFF));
            const ext_r_clean = @as(i32, @intCast(self.ext_vol_r & 0x3FFF));
            left_mix += (@as(i32, self.current_ext_l) * ext_l_clean) >> 14;
            right_mix += (@as(i32, self.current_ext_r) * ext_r_clean) >> 14;
        }

        // Apply main volume, explicitly promoted to i64 to prevent overflow!
        const main_l_clean = @as(i64, @intCast(self.main_vol_l & 0x3FFF));
        const main_r_clean = @as(i64, @intCast(self.main_vol_r & 0x3FFF));

        const final_l = @as(i32, @truncate((@as(i64, left_mix) * main_l_clean) >> 14));
        const final_r = @as(i32, @truncate((@as(i64, right_mix) * main_r_clean) >> 14));

        // Push to ring buffer
        self.output_buffer[self.write_idx] = @as(f32, @floatFromInt(final_l)) / 32768.0;
        self.output_buffer[(self.write_idx + 1) % self.output_buffer.len] = @as(f32, @floatFromInt(final_r)) / 32768.0;
        self.write_idx = (self.write_idx + 2) % self.output_buffer.len;
    }
};
