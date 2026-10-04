//! A pure arm64 instruction encoder: each function returns one instruction
//! word. Only the forms the JIT emits, each pinned in `jit_test.zig` against
//! the assembler's own encoding.

pub const Reg = enum(u5) {
    x0,
    x1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x7,
    x8,
    x9,
    x10,
    x11,
    x12,
    x13,
    x14,
    x15,
    x16,
    x17,
    x18,
    x19,
    x20,
    x21,
    x22,
    x23,
    x24,
    x25,
    x26,
    x27,
    x28,
    x29,
    x30,
    /// Register 31 is the stack pointer as an add-immediate operand or a
    /// load/store base, and the zero register everywhere else.
    sp,

    pub const zr: Reg = .sp;
    pub const fp: Reg = .x29;
    pub const lr: Reg = .x30;

    fn n(r: Reg) u32 {
        return @backingInt(r);
    }
};

/// Operand width: `w` (32-bit) or `x` (64-bit) registers.
pub const Width = enum(u1) {
    w,
    x,

    fn sf(width: Width) u32 {
        return @as(u32, @backingInt(width)) << 31;
    }
};

/// ADD (immediate), unshifted. Register 31 is SP here.
pub fn addImm(width: Width, rd: Reg, rn: Reg, imm12: u12) u32 {
    return width.sf() | 0x1100_0000 | @as(u32, imm12) << 10 | rn.n() << 5 | rd.n();
}

/// ADD (shifted register), LSL #0. Register 31 is the zero register here.
pub fn addReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return width.sf() | 0x0B00_0000 | rm.n() << 16 | rn.n() << 5 | rd.n();
}

/// MOV (register), which is ORR rd, zr, rm. Not for SP: copy SP with
/// `addImm(.x, rd, .sp, 0)`.
pub fn movReg(width: Width, rd: Reg, rm: Reg) u32 {
    return width.sf() | 0x2A00_03E0 | rm.n() << 16 | rd.n();
}

/// MOVZ: `imm16 << (16 * hw)`, every other bit zero. `hw` is 0 or 1 for `w`.
pub fn movz(width: Width, rd: Reg, imm16: u16, hw: u2) u32 {
    return width.sf() | 0x5280_0000 | @as(u32, hw) << 21 | @as(u32, imm16) << 5 | rd.n();
}

/// MOVK: replaces bits `16 * hw` to `16 * hw + 15` and keeps the rest.
pub fn movk(width: Width, rd: Reg, imm16: u16, hw: u2) u32 {
    return width.sf() | 0x7280_0000 | @as(u32, hw) << 21 | @as(u32, imm16) << 5 | rd.n();
}

/// Addressing for STP/LDP. `offset` is in bytes.
pub const PairMode = enum(u32) {
    /// `[base, #offset]!`
    pre_index = 0x2980_0000,
    /// `[base, #offset]`
    signed_offset = 0x2900_0000,
    /// `[base], #offset`
    post_index = 0x2880_0000,
};

/// STP of two `x` registers. `offset` is a multiple of 8 in -512..504.
pub fn stp(mode: PairMode, rt: Reg, rt2: Reg, rn: Reg, offset: i10) u32 {
    return pair(mode, false, rt, rt2, rn, offset);
}

/// LDP of two `x` registers. `offset` is a multiple of 8 in -512..504.
pub fn ldp(mode: PairMode, rt: Reg, rt2: Reg, rn: Reg, offset: i10) u32 {
    return pair(mode, true, rt, rt2, rn, offset);
}

fn pair(mode: PairMode, load: bool, rt: Reg, rt2: Reg, rn: Reg, offset: i10) u32 {
    const imm7: u7 = @bitCast(@as(i7, @intCast(@divExact(offset, 8))));
    return 0x8000_0000 | @backingInt(mode) | @as(u32, @intFromBool(load)) << 22 |
        @as(u32, imm7) << 15 | rt2.n() << 10 | rn.n() << 5 | rt.n();
}

pub fn blr(rn: Reg) u32 {
    return 0xD63F_0000 | rn.n() << 5;
}

pub fn ret() u32 {
    return 0xD65F_03C0;
}

/// B. `offset` is in bytes from this instruction: a multiple of 4 within
/// ±128 MB.
pub fn b(offset: i28) u32 {
    const imm26: u26 = @bitCast(@as(i26, @intCast(@divExact(offset, 4))));
    return 0x1400_0000 | @as(u32, imm26);
}

/// CBNZ. `offset` is in bytes from this instruction: a multiple of 4
/// within ±1 MB.
pub fn cbnz(width: Width, rt: Reg, offset: i21) u32 {
    const imm19: u19 = @bitCast(@as(i19, @intCast(@divExact(offset, 4))));
    return width.sf() | 0x3500_0000 | @as(u32, imm19) << 5 | rt.n();
}
