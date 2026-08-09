const Cop2 = @import("cop2.zig").Cop2;

/// Reciprocal seed table for the UNR division (Avocado gte.cpp:11).
const unr_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [0x101]u8 = undefined;
    for (&table, 0..) |*entry, i| {
        const v = @divTrunc(@divTrunc(0x40000, @as(i32, @intCast(i)) + 0x100) + 1, 2) - 0x101;
        entry.* = if (v < 0) 0 else @as(u8, @intCast(v));
    }
    break :blk table;
};

fn recip(divisor: u16) i64 {
    const x: i32 = 0x101 + @as(i32, unr_table[((@as(u32, divisor) & 0x7FFF) + 0x40) >> 7]);
    const tmp: i32 = ((@as(i32, divisor) * -x) + 0x80) >> 8;
    return @as(i64, (x * (131072 + tmp)) + 0x80) >> 8;
}

/// Newton-Raphson (UNR) division, exactly as the GTE does it
/// (Avocado opcodes.cpp:291). The result carries 16 fractional bits and may
/// legally reach 1FFFFh, i.e. a H/SZ3 ratio just under 2.0.
pub fn divideUNR(cop2: *Cop2, lhs: u32, rhs: u32) u32 {
    if (!(rhs * 2 > lhs)) {
        cop2.setFlag(17);
        return 0x1FFFF;
    }

    const shift: u5 = @clz(@as(u16, @truncate(rhs)));
    const n = @as(u64, lhs << shift);
    const d = rhs << shift;

    const reciprocal = recip(@as(u16, @truncate(d)) | 0x8000);
    const res = (n * @as(u64, @intCast(reciprocal)) + 0x8000) >> 16;

    return if (res > 0x1FFFF) 0x1FFFF else @as(u32, @truncate(res));
}

/// Sign-extend a 44-bit MAC accumulator (Avocado's extend_sign<44>).
fn extendMac(value: i64) i64 {
    return @as(i64, @as(i44, @truncate(value)));
}

/// Accumulate into MAC1..3 with the 44-bit overflow check applied at every
/// step, matching Avocado's `O()` macro (opcodes.cpp:26-40).
pub fn accumulateMac(cop2: *Cop2, i: usize, value: i64) i64 {
    if (value >= (1 << 43)) {
        cop2.setFlag(@as(u5, @intCast(31 - i))); // 30, 29, 28
    } else if (value < -(1 << 43)) {
        cop2.setFlag(@as(u5, @intCast(28 - i))); // 27, 26, 25
    }
    return extendMac(value);
}

/// MAC0..3 are 32-bit *registers* (Avocado declares `int32_t mac[4]`,
/// gte.h:83) even though the accumulator feeding them is 44 bits wide. The
/// narrowing therefore happens on the way in, so everything downstream —
/// `mfc2`, the `>> 4` into the colour FIFO, GPL's `<< sf` re-scale — works
/// on the low word, not on the wide intermediate.
pub fn storeMac(cop2: *Cop2, i: usize, value: i64) void {
    cop2.macs[i] = @as(i64, @as(i32, @truncate(value)));
}

/// MAC0 overflows at 32 bits (Avocado setMac<0>, opcodes.cpp:42).
pub fn setMac0(cop2: *Cop2, value: i64) i64 {
    if (value >= (1 << 31)) {
        cop2.setFlag(16);
    } else if (value < -(1 << 31)) {
        cop2.setFlag(15);
    }
    storeMac(cop2, 0, value);
    return value;
}

/// MAC1..3 are 44-bit accumulators, so the overflow flags trip at ±2^43 —
/// the same bound `accumulateMac` uses (Avocado's `checkOverflow<44>`,
/// opcodes.cpp:49-65). A 32-bit bound here raises MAC_OVERFLOW on values
/// the hardware carries without complaint.
/// Takes the wide accumulator explicitly: `macs` only holds the narrowed
/// 32-bit register, so it cannot be re-derived from there.
pub fn checkMacOverflow(cop2: *Cop2, i: usize, value: i64) void {
    if (i < 1 or i > 3) return;
    if (value >= (1 << 43)) {
        cop2.setFlag(@as(u5, @intCast(31 - i))); // 30, 29, 28
    } else if (value < -(1 << 43)) {
        cop2.setFlag(@as(u5, @intCast(28 - i))); // 27, 26, 25
    }
}

/// Avocado's `setIr` takes an `int32_t`, so the 44-bit MAC is narrowed to 32
/// bits before being clipped (opcodes.cpp:68-81); at sf=0 nothing has shrunk
/// the accumulator, so the low word regularly disagrees in sign with the
/// whole. `clip()` also ors in the *same* flag mask on both branches, so a
/// downward saturation raises IR{1,2,3}_SATURATED too — never the
/// colour-FIFO bits.
pub fn saturateToIr(cop2: *Cop2, i: usize, val: i64, lm: bool) void {
    if (i < 1 or i > 3) return;
    const narrowed = @as(i64, @as(i32, @truncate(val)));
    var res = narrowed;
    const min: i64 = if (lm) 0 else -32768;
    const max: i64 = 32767;

    if (narrowed > max) {
        cop2.setFlag(@as(u5, @intCast(25 - i))); // 24, 23, 22
        res = max;
    } else if (narrowed < min) {
        cop2.setFlag(@as(u5, @intCast(25 - i))); // 24, 23, 22
        res = min;
    }
    cop2.data_regs[8 + i] = @as(u32, @bitCast(@as(i32, @as(i16, @intCast(res)))));
}

/// `val` is already the >>16 screen coordinate (Avocado pushScreenXY).
pub fn saturateSxy(cop2: *Cop2, val: i64, bit: u5) i16 {
    var res = val;
    if (res < -1024) {
        cop2.setFlag(bit);
        res = -1024;
    } else if (res > 1023) {
        cop2.setFlag(bit);
        res = 1023;
    }
    return @as(i16, @intCast(res));
}

fn saturateColor(cop2: *Cop2, val: i64, bit: u5) u8 {
    return clampColor(cop2, val >> 12, bit);
}

/// Clamp an already-scaled colour component to 0..255, flagging saturation.
/// Callers that hold an un-shifted MAC want `saturateColor` instead.
///
pub fn clampColor(cop2: *Cop2, val: i64, bit: u5) u8 {
    if (val < 0) {
        cop2.setFlag(bit);
        return 0;
    } else if (val > 255) {
        cop2.setFlag(bit);
        return 255;
    }
    return @as(u8, @intCast(val));
}

/// Build one of the GTE's 3x3 matrices from five consecutive control regs
/// (`base` = 8 light source, 16 light colour).
pub fn matrixFromCtrl(cop2: *const Cop2, comptime base: usize) [3][3]i16 {
    const m0 = @as(Cop2.DualI16, @bitCast(cop2.ctrl_regs[base + 0]));
    const m1 = @as(Cop2.DualI16, @bitCast(cop2.ctrl_regs[base + 1]));
    const m2 = @as(Cop2.DualI16, @bitCast(cop2.ctrl_regs[base + 2]));
    const m3 = @as(Cop2.DualI16, @bitCast(cop2.ctrl_regs[base + 3]));
    const m4 = @as(Cop2.DualI16, @bitCast(cop2.ctrl_regs[base + 4]));
    return .{
        .{ m0.low, m0.high, m1.low },
        .{ m1.high, m2.low, m2.high },
        .{ m3.low, m3.high, m4.low },
    };
}

/// V0/V1/V2 as a vector (DataRegs 0/1, 2/3, 4/5).
pub fn vertex(cop2: *const Cop2, n: usize) [3]i16 {
    const p = @as(Cop2.Point2D, @bitCast(cop2.data_regs[n * 2]));
    return .{ p.x, p.y, Cop2.asI16(cop2.data_regs[n * 2 + 1]) };
}

pub fn irVector(cop2: *const Cop2) [3]i16 {
    return .{
        Cop2.asI16(cop2.data_regs[9]),
        Cop2.asI16(cop2.data_regs[10]),
        Cop2.asI16(cop2.data_regs[11]),
    };
}

/// RGBC as the GTE uses it internally: each component shifted up by 4
/// (Avocado's R/G/B macros, opcodes.cpp:90).
pub fn rgbcScaled(cop2: *const Cop2) [3]i16 {
    const c = @as(Cop2.ColorCode, @bitCast(cop2.data_regs[6]));
    return .{
        @as(i16, c.r) << 4,
        @as(i16, c.g) << 4,
        @as(i16, c.b) << 4,
    };
}

/// Background colour (Ctrl 13..15), the translation vector of the
/// light-colour matrix multiply.
pub fn backgroundColor(cop2: *const Cop2) [3]i32 {
    return .{
        @bitCast(cop2.ctrl_regs[13]),
        @bitCast(cop2.ctrl_regs[14]),
        @bitCast(cop2.ctrl_regs[15]),
    };
}

/// Far colour (Ctrl 21..23).
pub fn farColor(cop2: *const Cop2) [3]i64 {
    return .{
        @as(i32, @bitCast(cop2.ctrl_regs[21])),
        @as(i32, @bitCast(cop2.ctrl_regs[22])),
        @as(i32, @bitCast(cop2.ctrl_regs[23])),
    };
}

/// Avocado `multiplyMatrixByVector` (opcodes.cpp:104). The `O()` macro
/// applies the 44-bit overflow check after *every* accumulation step, not
/// just to the final sum.
pub fn multiplyMatrixByVector(cop2: *Cop2, m: [3][3]i16, v: [3]i16, tr: [3]i32, sf: u6, lm: bool) void {
    for (0..3) |i| {
        var acc = accumulateMac(cop2, i + 1, (@as(i64, tr[i]) << 12) + @as(i64, m[i][0]) * @as(i64, v[0]));
        acc = accumulateMac(cop2, i + 1, acc + @as(i64, m[i][1]) * @as(i64, v[1]));
        acc = accumulateMac(cop2, i + 1, acc + @as(i64, m[i][2]) * @as(i64, v[2]));
        setMacAndIr(cop2, i + 1, acc, sf, lm);
    }
}

/// Avocado `multiplyVectors` (opcodes.cpp:98).
pub fn multiplyVectors(cop2: *Cop2, v1: [3]i16, v2: [3]i16, tr: [3]i16, sf: u6, lm: bool) void {
    for (0..3) |i| {
        setMacAndIr(cop2, i + 1, (@as(i64, tr[i]) << 12) + @as(i64, v1[i]) * @as(i64, v2[i]), sf, lm);
    }
}

/// Avocado `setMacAndIr`: flag-check the full-width value, store MAC with the
/// `sf` shift applied, then saturate that stored MAC into IR. MAC1..3 are
/// readable via `mfc2` (data regs 25..27), so the shift must land in `macs`
/// itself — not only on the way to IR.
pub fn setMacAndIr(cop2: *Cop2, i: usize, value: i64, sf: u6, lm: bool) void {
    checkMacOverflow(cop2, i, value);
    const shifted = value >> sf;
    storeMac(cop2, i, shifted);
    saturateToIr(cop2, i, shifted, lm);
}
