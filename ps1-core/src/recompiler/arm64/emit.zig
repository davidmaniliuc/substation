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

/// Condition codes for B.cond, CSEL and CSET.
pub const Cond = enum(u4) {
    eq,
    ne,
    hs,
    lo,
    mi,
    pl,
    vs,
    vc,
    hi,
    ls,
    ge,
    lt,
    gt,
    le,

    fn invert(c: Cond) u32 {
        return @as(u32, @backingInt(c)) ^ 1;
    }
};

/// Data processing (shifted register), LSL #0. Register 31 is the zero
/// register in every operand.
fn dpReg(width: Width, opcode: u32, rd: Reg, rn: Reg, rm: Reg) u32 {
    return width.sf() | opcode | rm.n() << 16 | rn.n() << 5 | rd.n();
}

pub fn addReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x0B00_0000, rd, rn, rm);
}
pub fn addsReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x2B00_0000, rd, rn, rm);
}
pub fn subReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x4B00_0000, rd, rn, rm);
}
pub fn subsReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x6B00_0000, rd, rn, rm);
}
pub fn andReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x0A00_0000, rd, rn, rm);
}
pub fn orrReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x2A00_0000, rd, rn, rm);
}
pub fn eorReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x4A00_0000, rd, rn, rm);
}
/// ORN: `rn | ~rm`. With `rn` the zero register it is MVN.
pub fn ornReg(width: Width, rd: Reg, rn: Reg, rm: Reg) u32 {
    return dpReg(width, 0x2A20_0000, rd, rn, rm);
}
/// MOV (register), which is ORR rd, zr, rm. Not for SP: copy SP with
/// `addImm(.x, rd, .sp, 0)`.
pub fn movReg(width: Width, rd: Reg, rm: Reg) u32 {
    return orrReg(width, rd, .zr, rm);
}
/// CMP (register): SUBS to the zero register.
pub fn cmpReg(width: Width, rn: Reg, rm: Reg) u32 {
    return subsReg(width, .zr, rn, rm);
}
/// NEG: SUB from the zero register.
pub fn neg(width: Width, rd: Reg, rm: Reg) u32 {
    return subReg(width, rd, .zr, rm);
}

/// SUB (immediate), unshifted. Register 31 is SP here.
pub fn subImm(width: Width, rd: Reg, rn: Reg, imm12: u12) u32 {
    return width.sf() | 0x5100_0000 | @as(u32, imm12) << 10 | rn.n() << 5 | rd.n();
}
/// CMP (immediate): SUBS to the zero register. `rn` 31 is SP here.
pub fn cmpImm(width: Width, rn: Reg, imm12: u12) u32 {
    return width.sf() | 0x7100_001F | @as(u32, imm12) << 10 | rn.n() << 5;
}

/// MADD: `rd = ra + rn * rm`.
pub fn madd(width: Width, rd: Reg, rn: Reg, rm: Reg, ra: Reg) u32 {
    return width.sf() | 0x1B00_0000 | rm.n() << 16 | ra.n() << 10 | rn.n() << 5 | rd.n();
}

/// CSEL: `rd = cond ? rn : rm`.
pub fn csel(width: Width, rd: Reg, rn: Reg, rm: Reg, cond: Cond) u32 {
    return width.sf() | 0x1A80_0000 | rm.n() << 16 | @as(u32, @backingInt(cond)) << 12 | rn.n() << 5 | rd.n();
}
/// CSET: 1 when `cond` holds, else 0. CSINC rd, zr, zr, !cond.
pub fn cset(width: Width, rd: Reg, cond: Cond) u32 {
    return width.sf() | 0x1A9F_07E0 | cond.invert() << 12 | rd.n();
}

pub const Shift = enum(u32) {
    lsl = 0x1AC0_2000,
    lsr = 0x1AC0_2400,
    asr = 0x1AC0_2800,
};

/// LSLV/LSRV/ASRV: shifts `rn` by `rm` modulo the register width.
pub fn shiftReg(width: Width, shift: Shift, rd: Reg, rn: Reg, rm: Reg) u32 {
    return width.sf() | @backingInt(shift) | rm.n() << 16 | rn.n() << 5 | rd.n();
}

/// UBFM/SBFM on `w` registers. Register 31 is the zero register.
fn bitfield(signed: bool, rd: Reg, rn: Reg, immr: u5, imms: u5) u32 {
    const opcode: u32 = if (signed) 0x1300_0000 else 0x5300_0000;
    return opcode | @as(u32, immr) << 16 | @as(u32, imms) << 10 | rn.n() << 5 | rd.n();
}

/// An immediate shift of a `w` register. `amount` 0 is a move.
pub fn shiftImm(shift: Shift, rd: Reg, rn: Reg, amount: u5) u32 {
    return switch (shift) {
        .lsl => bitfield(false, rd, rn, 0 -% amount, 31 - amount),
        .lsr => bitfield(false, rd, rn, amount, 31),
        .asr => bitfield(true, rd, rn, amount, 31),
    };
}

/// UBFX on `w` registers: `width` bits of `rn` from `lsb`, zero-extended.
pub fn ubfx(rd: Reg, rn: Reg, lsb: u5, width: u6) u32 {
    return bitfield(false, rd, rn, lsb, @intCast(@as(u32, lsb) + width - 1));
}

/// BL. `offset` is in bytes from this instruction: a multiple of 4 within
/// ±128 MB.
pub fn bl(offset: i28) u32 {
    const imm26: u26 = @bitCast(@as(i26, @intCast(@divExact(offset, 4))));
    return 0x9400_0000 | @as(u32, imm26);
}

pub fn br(rn: Reg) u32 {
    return 0xD61F_0000 | rn.n() << 5;
}

/// B.cond. `offset` is in bytes from this instruction: within ±1 MB.
pub fn bCond(cond: Cond, offset: i21) u32 {
    const imm19: u19 = @bitCast(@as(i19, @intCast(@divExact(offset, 4))));
    return 0x5400_0000 | @as(u32, imm19) << 5 | @backingInt(cond);
}

/// CBZ. `offset` is in bytes from this instruction: within ±1 MB.
pub fn cbz(width: Width, rt: Reg, offset: i21) u32 {
    const imm19: u19 = @bitCast(@as(i19, @intCast(@divExact(offset, 4))));
    return width.sf() | 0x3400_0000 | @as(u32, imm19) << 5 | rt.n();
}

/// TBNZ on bit `bit` (below 32) of `rt`. `offset` is in bytes from this
/// instruction: within ±32 KB.
pub fn tbnz(rt: Reg, bit: u5, offset: i16) u32 {
    const imm14: u14 = @bitCast(@as(i14, @intCast(@divExact(offset, 4))));
    return 0x3700_0000 | @as(u32, bit) << 19 | @as(u32, imm14) << 5 | rt.n();
}

/// LDR/STR (unsigned offset). The access size is the top two bits.
pub const MemImm = enum(u32) {
    strb = 0x3900_0000,
    ldrb = 0x3940_0000,
    str_w = 0xB900_0000,
    ldr_w = 0xB940_0000,
    str_x = 0xF900_0000,
    ldr_x = 0xF940_0000,
};

/// `offset` is in bytes: a multiple of the access size, below 4096 of
/// them. Register 31 is SP as the base and the zero register as `rt`.
pub fn memImm(op: MemImm, rt: Reg, rn: Reg, offset: u32) u32 {
    const scale: u5 = @intCast(@backingInt(op) >> 30);
    const imm12: u12 = @intCast(@divExact(offset, @as(u32, 1) << scale));
    return @backingInt(op) | @as(u32, imm12) << 10 | rn.n() << 5 | rt.n();
}

/// LDR/STR (register offset), with the size and sign-extension bits.
pub const MemReg = enum(u32) {
    strb = 0x0000_0000,
    ldrb = 0x0040_0000,
    ldrsb = 0x00C0_0000,
    strh = 0x4000_0000,
    ldrh = 0x4040_0000,
    ldrsh = 0x40C0_0000,
    str_w = 0x8000_0000,
    ldr_w = 0x8040_0000,
    ldr_x = 0xC040_0000,
};

/// `[rn, wm, uxtw]`: a `w` index, zero-extended, shifted by the access size
/// when `scaled`. Register 31 as `rt` is the zero register.
pub fn memReg(op: MemReg, rt: Reg, rn: Reg, rm: Reg, scaled: bool) u32 {
    return 0x3820_4800 | @backingInt(op) | rm.n() << 16 |
        @as(u32, @intFromBool(scaled)) << 12 | rn.n() << 5 | rt.n();
}
