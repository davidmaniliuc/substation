const std = @import("std");

pub const Voice = @import("voice.zig").Voice;
const Adsr = @import("adsr.zig");
const Reverb = @import("reverb.zig");
const Noise = @import("noise.zig");
const Regs = @import("regs.zig");

pub const AdsrState = Adsr.AdsrState;
pub const decodeBlock = @import("voice.zig").decodeBlock;

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

    noise: struct {
        timer: i32 = 0,
        lfsr: u32 = 1,
        level: i32 = 0,
    } = .{},

    mix: struct {
        cd_vol_l: i16 = 0,
        cd_vol_r: i16 = 0,
        ext_vol_l: i16 = 0,
        ext_vol_r: i16 = 0,

        current_cd_l: i16 = 0,
        current_cd_r: i16 = 0,
        current_ext_l: i16 = 0,
        current_ext_r: i16 = 0,
    } = .{},

    irq_addr: u16 = 0, // IRQ Address (1F801DA4h)
    irq_flag: bool = false,

    reverb: struct {
        regs: [32]i16 = [_]i16{0} ** 32,
        base: u16 = 0,
        curr_addr: u32 = 0,
        /// Reverb runs at 22.05 kHz: doReverb on even samples, output re-used on odd.
        counter: u32 = 0,
        out_l: i32 = 0,
        out_r: i32 = 0,
    } = .{},

    /// Host-side kill switch, with no hardware counterpart. Reverb affected
    /// nothing until now and real-game audio has no automated coverage, so one
    /// field must be able to isolate a regression without a code edit.
    reverb_enable: bool = true,

    voices: [24]Voice = [_]Voice{.{}} ** 24,

    // Expanded to 65536 to hold more than a full frame of audio safely
    output_buffer: [65536]f32 = [_]f32{0} ** 65536,
    write_idx: usize = 0,
    read_idx: usize = 0,

    cycle_accumulator: u32 = 0,

    pub fn init() Self {
        return .{};
    }

    pub const read = Regs.read;
    pub const write = Regs.write;

    pub fn pushCdAudio(self: *Self, left: i16, right: i16) void {
        self.mix.current_cd_l = left;
        self.mix.current_cd_r = right;
    }

    pub fn pushExtAudio(self: *Self, left: i16, right: i16) void {
        self.mix.current_ext_l = left;
        self.mix.current_ext_r = right;
    }

    pub const doReverb = Reverb.doReverb;

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
        Noise.step(self);

        var prev_voice_sample: i32 = 0;

        for (&self.voices, 0..) |*voice, voice_idx| {
            if (!voice.is_on) {
                prev_voice_sample = 0;
                continue;
            }

            // Ensure we have valid decoded data BEFORE reading
            if (voice.adpcm.buffer_index >= 28) {
                voice.fetchAndDecode(self);
            }

            if (!voice.is_on) {
                prev_voice_sample = 0;
                continue; // Voice might have ended during fetch
            }

            // --- READ sample FIRST at current position ---
            const frac = @as(u32, voice.adpcm.current_fraction);
            const ind: usize = (frac >> 4) & 0xFF; // 8-bit index

            const spu_gauss = @import("gauss.zig").spu_gauss;
            var out: i32 = 0;
            out += (@as(i32, voice.adpcm.history[0]) * @as(i32, spu_gauss[0x0FF - ind])) >> 15;
            out += (@as(i32, voice.adpcm.history[1]) * @as(i32, spu_gauss[0x1FF - ind])) >> 15;
            out += (@as(i32, voice.adpcm.history[2]) * @as(i32, spu_gauss[0x100 + ind])) >> 15;
            out += (@as(i32, voice.adpcm.history[3]) * @as(i32, spu_gauss[0x000 + ind])) >> 15;

            var sample = out;

            // Save raw sample for next voice PMON
            const current_raw_sample = sample;
            prev_voice_sample = current_raw_sample;

            // Check NON
            if ((self.non & (@as(u32, 1) << @as(u5, @truncate(voice_idx)))) != 0) {
                sample = self.noise.level;
            }

            // Apply the ADSR Envelope to the raw PCM sample
            voice.stepAdsr();

            if (!voice.is_on) continue; // It might have died during Release

            const enveloped_sample = (sample * voice.env.current_ad_vol) >> 15;

            // Strip the 15th bit (Sweep flag) so it doesn't invert phase as a negative i16
            const vol_l_clean = @as(i32, @intCast(voice.regs.vol_l & 0x3FFF));
            const vol_r_clean = @as(i32, @intCast(voice.regs.vol_r & 0x3FFF));

            const left_voice = (enveloped_sample * vol_l_clean) >> 14;
            const right_voice = (enveloped_sample * vol_r_clean) >> 14;
            left_mix += left_voice;
            right_mix += right_voice;

            // Avocado accumulates the send into `Sample`, which saturates to
            // i16 on every +=. (left_mix/right_mix have the same divergence and
            // are deliberately left alone -- see the spec's non-goals.)
            if ((self.von & (@as(u32, 1) << @as(u5, @truncate(voice_idx)))) != 0) {
                left_reverb_mix = Reverb.sat(left_reverb_mix + left_voice);
                right_reverb_mix = Reverb.sat(right_reverb_mix + right_voice);
            }

            // --- THEN advance the pitch counter ---
            var pitch_clamped = if (voice.regs.pitch > 0x3FFF) @as(u16, 0x3FFF) else voice.regs.pitch;

            // Check PMON
            if ((self.pmon & (@as(u32, 1) << @as(u5, @truncate(voice_idx)))) != 0) {
                const mod_factor = prev_voice_sample + 0x8000;
                const modulated = (@as(i64, pitch_clamped) * mod_factor) >> 15;
                pitch_clamped = @intCast(std.math.clamp(modulated, 0, 0x3FFF));
            }

            const total_fraction = @as(u32, voice.adpcm.current_fraction) + pitch_clamped;
            const advance = total_fraction >> 12;
            voice.adpcm.current_fraction = @truncate(total_fraction & 0xFFF);

            for (0..advance) |_| {
                if (voice.adpcm.buffer_index >= 28) {
                    voice.fetchAndDecode(self);
                    if (!voice.is_on) {
                        break;
                    }
                }

                voice.adpcm.history[0] = voice.adpcm.history[1];
                voice.adpcm.history[1] = voice.adpcm.history[2];
                voice.adpcm.history[2] = voice.adpcm.history[3];
                voice.adpcm.history[3] = voice.adpcm.decoded_buffer[voice.adpcm.buffer_index];
                voice.adpcm.buffer_index += 1;
            }
        }

        // CD-ROM Audio Mix. SPUCNT bit 0 enables it; bit 2 additionally routes
        // it into the reverb bus (Avocado spu.cpp:103-108).
        if ((self.spu_cnt & (1 << 0)) != 0) {
            const cd_l_clean = @as(i32, @intCast(self.mix.cd_vol_l & 0x3FFF));
            const cd_r_clean = @as(i32, @intCast(self.mix.cd_vol_r & 0x3FFF));
            const cd_l = (@as(i32, self.mix.current_cd_l) * cd_l_clean) >> 14;
            const cd_r = (@as(i32, self.mix.current_cd_r) * cd_r_clean) >> 14;
            left_mix += cd_l;
            right_mix += cd_r;

            if ((self.spu_cnt & (1 << 2)) != 0) {
                left_reverb_mix = Reverb.sat(left_reverb_mix + cd_l);
                right_reverb_mix = Reverb.sat(right_reverb_mix + cd_r);
            }
        }

        // External Audio Mix. Bit 1 enables it, bit 3 sends it to reverb.
        // Wired but inert: nothing calls pushExtAudio, so current_ext_l/r are
        // structurally always 0 (the bit-1 mix was already inert before this
        // branch existed). Kept for whenever a producer shows up.
        if ((self.spu_cnt & (1 << 1)) != 0) {
            const ext_l_clean = @as(i32, @intCast(self.mix.ext_vol_l & 0x3FFF));
            const ext_r_clean = @as(i32, @intCast(self.mix.ext_vol_r & 0x3FFF));
            const ext_l = (@as(i32, self.mix.current_ext_l) * ext_l_clean) >> 14;
            const ext_r = (@as(i32, self.mix.current_ext_r) * ext_r_clean) >> 14;
            left_mix += ext_l;
            right_mix += ext_r;

            if ((self.spu_cnt & (1 << 3)) != 0) {
                left_reverb_mix = Reverb.sat(left_reverb_mix + ext_l);
                right_reverb_mix = Reverb.sat(right_reverb_mix + ext_r);
            }
        }

        // Reverb runs at 22.05 kHz, so doReverb is invoked on even samples only
        // and the odd sample re-adds the same value (Avocado spu.cpp:115-119).
        // This sits after the CD/external mixes and before main volume.
        if (self.reverb_enable) {
            if (self.reverb.counter % 2 == 0) {
                const rev = self.doReverb(left_reverb_mix, right_reverb_mix);
                self.reverb.out_l = rev.l;
                self.reverb.out_r = rev.r;
            }
            self.reverb.counter +%= 1;
            left_mix += self.reverb.out_l;
            right_mix += self.reverb.out_r;
        } else {
            // Zeroed so re-enabling at runtime does not splice in a stale tail.
            self.reverb.out_l = 0;
            self.reverb.out_r = 0;
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
