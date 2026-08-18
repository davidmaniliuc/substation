const std = @import("std");
const Spu = @import("spu.zig").Spu;

fn wrapReverbAddr(self: *Spu, address: u32) u32 {
    // Unsigned throughout: `rel = address - reverb_base` wraps modulo 2^32,
    // then `% size`.
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
    // the default state of a fresh Spu). The address arithmetic is modular,
    // so a trapping `+` here panics on that same case instead of wrapping
    // back to "two bytes before the cursor", which is what the expression
    // actually means.
    const addr = wrapReverbAddr(self, self.reverb.curr_addr +% address);
    const val = std.mem.readInt(u16, self.sram[addr..][0..2], .little);
    return @as(i16, @bitCast(val));
}

fn writeReverbSram(self: *Spu, address: u32, sample: i32) void {
    // SPUCNT bit 7 (master reverb) gates the WRITES ONLY. Reads still
    // happen, the output is still produced, and reverb_curr_addr still
    // advances. Gating here rather than at the six call sites is what
    // makes that asymmetry
    // impossible to get half-right.
    if ((self.spu_cnt & (1 << 7)) == 0) return;
    const clamped = std.math.clamp(sample, -32768, 32767);
    const u16_val = @as(u16, @bitCast(@as(i16, @intCast(clamped))));
    // Wrapping add -- see readReverbSram above.
    const addr = wrapReverbAddr(self, self.reverb.curr_addr +% address);
    std.mem.writeInt(u16, self.sram[addr..][0..2], u16_val, .little);
}

/// Reverb samples saturate to i16 on every `+` and `-`, but not on `*`, so
/// reverb expressions must clamp after each add and subtract rather than
/// once at the end of the expression:
/// {20000, 20000, -20000, -20000} sums to -7233 with per-step saturation and to
/// 0 without it.
pub fn sat(v: i32) i32 {
    return std.math.clamp(v, -32768, 32767);
}

/// A reverb *address* register: a count of 8-byte units, so `* 8` makes it a
/// byte offset into reverb SRAM. Reads through the i16 store as unsigned,
/// because these are addresses, not signed coefficients.
fn addrReg(self: *const Spu, index: usize) u32 {
    return @as(u32, @as(u16, @bitCast(self.reverb.regs[index]))) * 8;
}

/// A reverb *volume* register: a signed 1.15 coefficient, widened for the
/// `(x * v) >> 15` products below.
fn volReg(self: *const Spu, index: usize) i32 {
    return self.reverb.regs[index];
}

/// One side of the IIR comb-feedback stage: mix the input with the wall
/// reflection at `d_tap`, difference it against the sample one step behind
/// the write cursor, and store the filtered result at `m`.
///
/// The three SRAM accesses must stay in this order -- both reads happen
/// before the write, and with an unprogrammed `m` they can name the same
/// cell.
fn iirStage(self: *Spu, in: i32, d_tap: u32, m: u32, v_wall: i32, v_iir: i32) void {
    const prev = m -% 2;
    const val = sat(sat(in + ((readReverbSram(self, d_tap) * v_wall) >> 15)) - readReverbSram(self, prev));
    writeReverbSram(self, m, ((val * v_iir) >> 15) + readReverbSram(self, prev));
}

/// One side of the four-tap comb filter. Accumulated one term at a time so
/// each partial sum saturates -- a left-associative chain of clamping adds,
/// not one clamp over the whole sum.
fn combStage(self: *Spu, v: [4]i32, m: [4]u32) i32 {
    var out = sat((v[0] * readReverbSram(self, m[0])) >> 15);
    for (v[1..], m[1..]) |vc, mc| {
        out = sat(out + ((vc * readReverbSram(self, mc)) >> 15));
    }
    return out;
}

/// One all-pass stage: subtract the delayed tap, store the intermediate at
/// the stage's write cursor, then add the tap back scaled by `v`.
///
/// The tap is re-read *after* the write on purpose: `d` is a delay behind
/// `m`, and when the reverb registers are unprogrammed both resolve to the
/// same cell, so the second read must see the value just written.
fn apfStage(self: *Spu, in: i32, v: i32, m: u32, d: u32) i32 {
    const tap = m -% d;
    const mid = sat(in - ((v * readReverbSram(self, tap)) >> 15));
    writeReverbSram(self, m, mid);
    return sat(((mid * v) >> 15) + readReverbSram(self, tap));
}

/// One 22.05 kHz reverb tick. Public so `spu_test.zig` can drive it
/// directly against the reverb goldens.
pub fn doReverb(self: *Spu, left_in: i32, right_in: i32) struct { l: i32, r: i32 } {
    // Registers
    const dAPF1 = addrReg(self, 0x00);
    const dAPF2 = addrReg(self, 0x01);
    const vIIR = volReg(self, 0x02);
    const vCOMB1 = volReg(self, 0x03);
    const vCOMB2 = volReg(self, 0x04);
    const vCOMB3 = volReg(self, 0x05);
    const vCOMB4 = volReg(self, 0x06);
    const vWALL = volReg(self, 0x07);
    const vAPF1 = volReg(self, 0x08);
    const vAPF2 = volReg(self, 0x09);
    const mLSAME = addrReg(self, 0x0A);
    const mRSAME = addrReg(self, 0x0B);
    const mLCOMB1 = addrReg(self, 0x0C);
    const mRCOMB1 = addrReg(self, 0x0D);
    const mLCOMB2 = addrReg(self, 0x0E);
    const mRCOMB2 = addrReg(self, 0x0F);
    const dLSAME = addrReg(self, 0x10);
    const dRSAME = addrReg(self, 0x11);
    const mLDIFF = addrReg(self, 0x12);
    const mRDIFF = addrReg(self, 0x13);
    const mLCOMB3 = addrReg(self, 0x14);
    const mRCOMB3 = addrReg(self, 0x15);
    const mLCOMB4 = addrReg(self, 0x16);
    const mRCOMB4 = addrReg(self, 0x17);
    const dLDIFF = addrReg(self, 0x18);
    const dRDIFF = addrReg(self, 0x19);
    const mLAPF1 = addrReg(self, 0x1A);
    const mRAPF1 = addrReg(self, 0x1B);
    const mLAPF2 = addrReg(self, 0x1C);
    const mRAPF2 = addrReg(self, 0x1D);
    const vLIN = volReg(self, 0x1E);
    const vRIN = volReg(self, 0x1F);

    const clamped_left_in = std.math.clamp(left_in, -32768, 32767);
    const clamped_right_in = std.math.clamp(right_in, -32768, 32767);

    const Lin = (clamped_left_in * vLIN) >> 15;
    const Rin = (clamped_right_in * vRIN) >> 15;

    // IIR filters. The "same side" pair reflects each channel back into
    // itself; the "different side" pair crosses over, so the left input
    // reads the right delay tap and vice versa.
    iirStage(self, Lin, dLSAME, mLSAME, vWALL, vIIR);
    iirStage(self, Rin, dRSAME, mRSAME, vWALL, vIIR);
    iirStage(self, Lin, dRDIFF, mLDIFF, vWALL, vIIR);
    iirStage(self, Rin, dLDIFF, mRDIFF, vWALL, vIIR);

    // COMB filters
    const v_comb = [4]i32{ vCOMB1, vCOMB2, vCOMB3, vCOMB4 };
    var Lout = combStage(self, v_comb, .{ mLCOMB1, mLCOMB2, mLCOMB3, mLCOMB4 });
    var Rout = combStage(self, v_comb, .{ mRCOMB1, mRCOMB2, mRCOMB3, mRCOMB4 });

    // APF filters, both stages, left before right within each stage.
    Lout = apfStage(self, Lout, vAPF1, mLAPF1, dAPF1);
    Rout = apfStage(self, Rout, vAPF1, mRAPF1, dAPF1);
    Lout = apfStage(self, Lout, vAPF2, mLAPF2, dAPF2);
    Rout = apfStage(self, Rout, vAPF2, mRAPF2, dAPF2);

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
