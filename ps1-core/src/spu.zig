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
    buffer_index: usize = 28, // Start at 28 to trigger decode
    is_on: bool = false,

    // ADSR State
    adsr_state: AdsrState = .Off,
    current_ad_vol: i32 = 0, // Ranging from 0 to 0x7FFF

    pub fn read(self: *const Voice, reg_idx: u32) u16 {
        return switch (reg_idx) {
            0 => @bitCast(self.vol_l),
            1 => @bitCast(self.vol_r),
            2 => self.pitch,
            3 => self.start_addr,
            4 => self.adsr1,
            5 => self.adsr2,
            6 => @bitCast(self.adsr_vol),
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

        // Reset envelope
        self.adsr_state = .Attack;
        self.current_ad_vol = 0;
    }

    pub fn keyOff(self: *Voice) void {
        // Don't turn is_on to false instantly! Move to Release phase.
        self.adsr_state = .Release;
    }

    pub fn stepAdsr(self: *Voice) void {
        if (self.adsr_state == .Off) {
            self.current_ad_vol = 0;
            return;
        }

        // Simplified linear approximation of PS1 ADSR
        const ar = (self.adsr1 >> 8) & 0x7F;
        const dr = (self.adsr1 >> 4) & 0x0F;
        const sl = (@as(i32, @intCast(self.adsr1 & 0x0F)) + 1) * 0x800;

        const sr = (self.adsr2 >> 8) & 0x7F;
        const rr = self.adsr2 & 0x1F;

        switch (self.adsr_state) {
            .Attack => {
                self.current_ad_vol += (@as(i32, @intCast(ar)) + 1) * 16;
                if (self.current_ad_vol >= 0x7FFF) {
                    self.current_ad_vol = 0x7FFF;
                    self.adsr_state = .Decay;
                }
            },
            .Decay => {
                self.current_ad_vol -= (@as(i32, @intCast(dr)) + 1) * 16;
                if (self.current_ad_vol <= sl) {
                    self.current_ad_vol = sl;
                    self.adsr_state = .Sustain;
                }
            },
            .Sustain => {
                const decrease = (self.adsr2 & (1 << 14)) != 0;
                if (decrease) {
                    self.current_ad_vol -= @as(i32, @intCast(sr)); // Allow 0 to hold flat!
                    if (self.current_ad_vol <= 0) self.current_ad_vol = 0;
                } else {
                    self.current_ad_vol += @as(i32, @intCast(sr));
                    if (self.current_ad_vol >= 0x7FFF) self.current_ad_vol = 0x7FFF;
                }
            },
            .Release => {
                self.current_ad_vol -= (@as(i32, @intCast(rr)) + 1) * 16;
                if (self.current_ad_vol <= 0) {
                    self.current_ad_vol = 0;
                    self.adsr_state = .Off;
                    self.is_on = false; // Voice is finally dead
                }
            },
            .Off => {},
        }
    }

    pub fn fetchAndDecode(self: *Voice, sram: []const u8) void {
        const addr = self.current_addr & 0x7FFF0;
        var block: [16]u8 = undefined;
        @memcpy(&block, sram[addr..][0..16]);

        decodeBlock(&block, &self.adpcm_old, &self.adpcm_older, &self.decoded_buffer);
        self.buffer_index = 0;

        const flags = block[1];
        if ((flags & 4) != 0) {
            self.loop_addr = @truncate(addr >> 3);
        }

        if ((flags & 1) != 0) { // End of sample
            if ((flags & 2) != 0) { // Loop
                self.current_addr = @as(u32, self.loop_addr) << 3;
            } else {
                self.is_on = false;
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
    
    spu_cnt: u16 = 0,       // SPU Control (1F801DAAh)
    spu_stat: u16 = 0,      // SPU Status  (1F801DAEh)
    sram_addr: u32 = 0,     // Internal Sound RAM byte address
    sram_read_buffer: u16 = 0, // Hardware prefetch buffer for reads
    dtc: u16 = 4,           // DMA Transfer Control (1F801DACh)
    
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
            0x1DA6 => @truncate(self.sram_addr >> 3),
            0x1DA8 => self.readSram(),
            0x1DAA => self.spu_cnt,
            0x1DAC => self.dtc,
            0x1DAE => self.getStatus(),
            0x1DB0...0x1DFF => 0, // Various control registers
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
            0x1DAA => {
                self.spu_cnt = value;
                // Bit 0-5 of SPUSTAT are a copy of Bit 0-5 of SPUCNT
                self.spu_stat = (self.spu_stat & ~@as(u16, 0x3F)) | (value & 0x3F);
            },
            0x1DA6 => self.sram_addr = @as(u32, value) << 3,
            0x1DA8 => self.writeSram(value),
            0x1DAC => self.dtc = value,
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
        return self.spu_stat & 0x7FF;
    }

    /// Used by DMA Channel 4 to push data into Sound RAM
    pub fn writeSram(self: *Self, value: u16) void {
        const addr = self.sram_addr & 0x7FFFF;
        if (addr + 1 < self.sram.len) {
            std.mem.writeInt(u16, self.sram[addr..][0..2], value, .little);
        }
        self.sram_addr = (self.sram_addr + 2) & 0x7FFFF;
    }

    pub fn readSram(self: *Self) u16 {
        const return_val = self.sram_read_buffer;

        const addr = self.sram_addr & 0x7FFFF;
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

        for (&self.voices) |*voice| {
            if (!voice.is_on) continue;

            // Ensure we have valid decoded data BEFORE reading
            if (voice.buffer_index >= 28) {
                voice.fetchAndDecode(&self.sram);
            }

            if (!voice.is_on) continue; // Voice might have ended during fetch

            // Advance the pitch for the NEXT cycle
            const total_fraction = @as(u32, voice.current_fraction) + voice.pitch;
            const advance = total_fraction >> 12;
            voice.current_fraction = @truncate(total_fraction & 0xFFF);

            for (0..advance) |_| {
                voice.buffer_index += 1;
                if (voice.buffer_index >= 28) {
                    voice.fetchAndDecode(&self.sram);
                    if (!voice.is_on) break;
                }
            }

            // Advance ADSR by one tick
            voice.stepAdsr();

            if (!voice.is_on) continue; // It might have died during Release

            const sample = voice.decoded_buffer[voice.buffer_index];

            // Apply the ADSR Envelope to the raw PCM sample
            const enveloped_sample = (@as(i32, sample) * voice.current_ad_vol) >> 15;

            // Strip the 15th bit (Sweep flag) so it doesn't invert phase as a negative i16
            const vol_l_clean = @as(i32, @intCast(voice.vol_l & 0x3FFF));
            const vol_r_clean = @as(i32, @intCast(voice.vol_r & 0x3FFF));

            left_mix += (enveloped_sample * vol_l_clean) >> 15;
            right_mix += (enveloped_sample * vol_r_clean) >> 15;
        }

        // Apply main volume, explicitly promoted to i64 to prevent overflow!
        const main_l_clean = @as(i64, @intCast(self.main_vol_l & 0x3FFF));
        const main_r_clean = @as(i64, @intCast(self.main_vol_r & 0x3FFF));

        const final_l = @as(i32, @truncate((@as(i64, left_mix) * main_l_clean) >> 15));
        const final_r = @as(i32, @truncate((@as(i64, right_mix) * main_r_clean) >> 15));

        // Push to ring buffer
        self.output_buffer[self.write_idx] = @as(f32, @floatFromInt(final_l)) / 32768.0;
        self.output_buffer[(self.write_idx + 1) % self.output_buffer.len] = @as(f32, @floatFromInt(final_r)) / 32768.0;
        self.write_idx = (self.write_idx + 2) % self.output_buffer.len;
    }
};
