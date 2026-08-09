const Spu = @import("spu.zig").Spu;

pub fn read(self: *Spu, offset: u32) u16 {
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
        0x1DAE => getStatus(self),
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

pub fn write(self: *Spu, offset: u32, value: u16) void {
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
        0x1DA2 => {
            self.reverb_base = value;
            // Rebasing the work area rewinds the ring-buffer write cursor
            // (Avocado spu.cpp:429-431). Without this the cursor keeps
            // whatever offset it had drifted to under the old base.
            self.reverb_curr_addr = @as(u32, value) * 8;
        },
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

pub fn getStatus(self: *const Spu) u16 {
    var stat = self.spu_stat & 0x7FF;
    if (self.irq_flag) stat |= (1 << 6);
    return stat;
}
