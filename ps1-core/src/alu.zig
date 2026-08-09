const std = @import("std");

pub fn sll(value: u32, shamt: u5) u32 {
    return value << shamt;
}

pub fn srl(value: u32, shamt: u5) u32 {
    return value >> shamt;
}

pub fn sra(value: u32, shamt: u5) u32 {
    const signed: i32 = @bitCast(value);
    return @bitCast(signed >> shamt);
}

/// Signed addition. Returns null on overflow (triggers ArithmeticOverflow exception).
pub fn add(a: u32, b: u32) ?u32 {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    const result = @addWithOverflow(sa, sb);
    return if (result[1] != 0) null else @bitCast(result[0]);
}

/// Unsigned (wrapping) addition. Never traps.
pub fn addu(a: u32, b: u32) u32 {
    return a +% b;
}

/// Signed subtraction. Returns null on overflow (triggers ArithmeticOverflow exception).
pub fn sub(a: u32, b: u32) ?u32 {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    const result = @subWithOverflow(sa, sb);
    return if (result[1] != 0) null else @bitCast(result[0]);
}

/// Unsigned (wrapping) subtraction. Never traps.
pub fn subu(a: u32, b: u32) u32 {
    return a -% b;
}

pub const HiLo = struct { hi: u32, lo: u32 };

/// Signed multiply: rs * rt → HI:LO
pub fn mult(a: u32, b: u32) HiLo {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    const result: u64 = @bitCast(@as(i64, sa) * @as(i64, sb));
    return .{ .lo = @truncate(result), .hi = @truncate(result >> 32) };
}

/// Unsigned multiply: rs * rt → HI:LO
pub fn multu(a: u32, b: u32) HiLo {
    const result: u64 = @as(u64, a) * @as(u64, b);
    return .{ .lo = @truncate(result), .hi = @truncate(result >> 32) };
}

/// Signed divide with PS1 hardware quirks.
pub fn div(a: u32, b: u32) HiLo {
    const as: i32 = @bitCast(a);
    const bs: i32 = @bitCast(b);

    if (bs == 0) {
        // PS1 divide-by-zero quirk
        return .{ .hi = a, .lo = if (as >= 0) 0xFFFFFFFF else 1 };
    }
    if (a == 0x80000000 and bs == -1) {
        // PS1 INT_MIN / -1 overflow quirk
        return .{ .hi = 0, .lo = 0x80000000 };
    }
    return .{
        .lo = @bitCast(@divTrunc(as, bs)),
        .hi = @bitCast(@rem(as, bs)),
    };
}

/// Unsigned divide with PS1 hardware quirks.
pub fn divu(a: u32, b: u32) HiLo {
    if (b == 0) {
        return .{ .hi = a, .lo = 0xFFFFFFFF };
    }
    return .{ .lo = a / b, .hi = a % b };
}

pub fn and_(a: u32, b: u32) u32 {
    return a & b;
}

pub fn or_(a: u32, b: u32) u32 {
    return a | b;
}

pub fn xor(a: u32, b: u32) u32 {
    return a ^ b;
}

pub fn nor(a: u32, b: u32) u32 {
    return ~(a | b);
}

/// Signed less-than: 1 if a < b (signed), else 0.
pub fn slt(a: u32, b: u32) u32 {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    return if (sa < sb) 1 else 0;
}

/// Unsigned less-than: 1 if a < b (unsigned), else 0.
pub fn sltu(a: u32, b: u32) u32 {
    return if (a < b) 1 else 0;
}
