const std = @import("std");
const Spu = @import("spu.zig").Spu;

fn wrapReverbAddr(self: *Spu, address: u32) u32 {
    // Unsigned throughout, matching Avocado (reverb.cpp:9-16): `rel =
    // address - reverbBase` wraps modulo 2^32 in uint32_t, then `% size`.
    // Bitcasting to i32 and correcting a negative @rem only agrees with
    // that when `size` divides 2^32 (e.g. the golden fixture's 0x400) —
    // for an arbitrary reverb_base it produces a different address.
    const reverb_base_addr = @as(u32, self.reverb.base) * 8;
    const size = (512 * 1024) - reverb_base_addr;
    const rel = (address -% reverb_base_addr) % size;
    return (reverb_base_addr + rel) & 0x7FFFE;
}

fn readReverbSram(self: *Spu, address: u32) i32 {
    // Wrapping add: several call sites pass a negative tap offset built
    // with wrapping subtraction (e.g. `mLSAME -% 2`), which is 0xFFFFFFFE
    // whenever that reverb register is still unprogrammed (the state on
    // every real hardware boot before a game touches the reverb regs, and
    // the default state of a fresh Spu). Avocado's C++ equivalent
    // (reverb.cpp:18-31) adds in uint32_t, where overflow is defined
    // modular arithmetic; a trapping `+` here panics on that same case
    // instead of wrapping back to "two bytes before the cursor", which is
    // what the expression actually means.
    const addr = wrapReverbAddr(self, self.reverb.curr_addr +% address);
    const val = std.mem.readInt(u16, self.sram[addr..][0..2], .little);
    return @as(i16, @bitCast(val));
}

fn writeReverbSram(self: *Spu, address: u32, sample: i32) void {
    // SPUCNT bit 7 (master reverb) gates the WRITES ONLY. Reads still
    // happen, the output is still produced, and reverb_curr_addr still
    // advances -- see Avocado's `W` lambda, reverb.cpp:39-43. Gating here
    // rather than at the six call sites is what makes that asymmetry
    // impossible to get half-right.
    if ((self.spu_cnt & (1 << 7)) == 0) return;
    const clamped = std.math.clamp(sample, -32768, 32767);
    const u16_val = @as(u16, @bitCast(@as(i16, @intCast(clamped))));
    // Wrapping add -- see readReverbSram above.
    const addr = wrapReverbAddr(self, self.reverb.curr_addr +% address);
    std.mem.writeInt(u16, self.sram[addr..][0..2], u16_val, .little);
}

/// Avocado's `Sample` type (avocado_ref/src/device/spu/sample.h) saturates to
/// i16 on every `+` and `-`, but not on `*`. Reverb expressions must therefore
/// clamp after each add and subtract, not once at the end of the expression:
/// {20000, 20000, -20000, -20000} sums to -7233 with per-step saturation and to
/// 0 without it.
pub fn sat(v: i32) i32 {
    return std.math.clamp(v, -32768, 32767);
}

/// One 22.05 kHz reverb tick. Public so `spu_test.zig` can drive it
/// directly against the Avocado goldens.
pub fn doReverb(self: *Spu, left_in: i32, right_in: i32) struct { l: i32, r: i32 } {
    // Registers
    const dAPF1 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x00]))) * 8;
    const dAPF2 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x01]))) * 8;
    const vIIR = @as(i32, self.reverb.regs[0x02]);
    const vCOMB1 = @as(i32, self.reverb.regs[0x03]);
    const vCOMB2 = @as(i32, self.reverb.regs[0x04]);
    const vCOMB3 = @as(i32, self.reverb.regs[0x05]);
    const vCOMB4 = @as(i32, self.reverb.regs[0x06]);
    const vWALL = @as(i32, self.reverb.regs[0x07]);
    const vAPF1 = @as(i32, self.reverb.regs[0x08]);
    const vAPF2 = @as(i32, self.reverb.regs[0x09]);
    const mLSAME = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x0A]))) * 8;
    const mRSAME = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x0B]))) * 8;
    const mLCOMB1 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x0C]))) * 8;
    const mRCOMB1 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x0D]))) * 8;
    const mLCOMB2 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x0E]))) * 8;
    const mRCOMB2 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x0F]))) * 8;
    const dLSAME = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x10]))) * 8;
    const dRSAME = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x11]))) * 8;
    const mLDIFF = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x12]))) * 8;
    const mRDIFF = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x13]))) * 8;
    const mLCOMB3 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x14]))) * 8;
    const mRCOMB3 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x15]))) * 8;
    const mLCOMB4 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x16]))) * 8;
    const mRCOMB4 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x17]))) * 8;
    const dLDIFF = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x18]))) * 8;
    const dRDIFF = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x19]))) * 8;
    const mLAPF1 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x1A]))) * 8;
    const mRAPF1 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x1B]))) * 8;
    const mLAPF2 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x1C]))) * 8;
    const mRAPF2 = @as(u32, @as(u16, @bitCast(self.reverb.regs[0x1D]))) * 8;
    const vLIN = @as(i32, self.reverb.regs[0x1E]);
    const vRIN = @as(i32, self.reverb.regs[0x1F]);

    const clamped_left_in = std.math.clamp(left_in, -32768, 32767);
    const clamped_right_in = std.math.clamp(right_in, -32768, 32767);

    const Lin = (clamped_left_in * vLIN) >> 15;
    const Rin = (clamped_right_in * vRIN) >> 15;

    // IIR Filters
    var val: i32 = 0;
    val = sat(sat(Lin + ((readReverbSram(self, dLSAME) * vWALL) >> 15)) - readReverbSram(self, mLSAME -% 2));
    writeReverbSram(self, mLSAME, ((val * vIIR) >> 15) + readReverbSram(self, mLSAME -% 2));

    val = sat(sat(Rin + ((readReverbSram(self, dRSAME) * vWALL) >> 15)) - readReverbSram(self, mRSAME -% 2));
    writeReverbSram(self, mRSAME, ((val * vIIR) >> 15) + readReverbSram(self, mRSAME -% 2));

    val = sat(sat(Lin + ((readReverbSram(self, dRDIFF) * vWALL) >> 15)) - readReverbSram(self, mLDIFF -% 2));
    writeReverbSram(self, mLDIFF, ((val * vIIR) >> 15) + readReverbSram(self, mLDIFF -% 2));

    val = sat(sat(Rin + ((readReverbSram(self, dLDIFF) * vWALL) >> 15)) - readReverbSram(self, mRDIFF -% 2));
    writeReverbSram(self, mRDIFF, ((val * vIIR) >> 15) + readReverbSram(self, mRDIFF -% 2));

    // COMB Filters. Accumulated one term at a time so each partial sum
    // saturates, matching Avocado's left-associative chain of clamping
    // Sample::operator+ calls.
    var Lout: i32 = sat((vCOMB1 * readReverbSram(self, mLCOMB1)) >> 15);
    Lout = sat(Lout + ((vCOMB2 * readReverbSram(self, mLCOMB2)) >> 15));
    Lout = sat(Lout + ((vCOMB3 * readReverbSram(self, mLCOMB3)) >> 15));
    Lout = sat(Lout + ((vCOMB4 * readReverbSram(self, mLCOMB4)) >> 15));

    var Rout: i32 = sat((vCOMB1 * readReverbSram(self, mRCOMB1)) >> 15);
    Rout = sat(Rout + ((vCOMB2 * readReverbSram(self, mRCOMB2)) >> 15));
    Rout = sat(Rout + ((vCOMB3 * readReverbSram(self, mRCOMB3)) >> 15));
    Rout = sat(Rout + ((vCOMB4 * readReverbSram(self, mRCOMB4)) >> 15));

    // APF Filters
    Lout = std.math.clamp(Lout - ((vAPF1 * readReverbSram(self, mLAPF1 -% dAPF1)) >> 15), -32768, 32767);
    writeReverbSram(self, mLAPF1, Lout);
    Lout = std.math.clamp(((Lout * vAPF1) >> 15) + readReverbSram(self, mLAPF1 -% dAPF1), -32768, 32767);

    Rout = std.math.clamp(Rout - ((vAPF1 * readReverbSram(self, mRAPF1 -% dAPF1)) >> 15), -32768, 32767);
    writeReverbSram(self, mRAPF1, Rout);
    Rout = std.math.clamp(((Rout * vAPF1) >> 15) + readReverbSram(self, mRAPF1 -% dAPF1), -32768, 32767);

    Lout = std.math.clamp(Lout - ((vAPF2 * readReverbSram(self, mLAPF2 -% dAPF2)) >> 15), -32768, 32767);
    writeReverbSram(self, mLAPF2, Lout);
    Lout = std.math.clamp(((Lout * vAPF2) >> 15) + readReverbSram(self, mLAPF2 -% dAPF2), -32768, 32767);

    Rout = std.math.clamp(Rout - ((vAPF2 * readReverbSram(self, mRAPF2 -% dAPF2)) >> 15), -32768, 32767);
    writeReverbSram(self, mRAPF2, Rout);
    Rout = std.math.clamp(((Rout * vAPF2) >> 15) + readReverbSram(self, mRAPF2 -% dAPF2), -32768, 32767);

    // Advance Window
    self.reverb.curr_addr = wrapReverbAddr(self, self.reverb.curr_addr + 2);

    // Final Volume Mix
    const rev_l_clean = @as(i32, self.reverb_vol_l);
    const rev_r_clean = @as(i32, self.reverb_vol_r);
    return .{
        .l = (Lout * rev_l_clean) >> 15,
        .r = (Rout * rev_r_clean) >> 15,
    };
}
