const std = @import("std");

pub fn sll(value: u32, shamt: u5) u32 {
    return value << shamt;
}

pub fn sllb(value: u32, shamt: u5) u32 {
    const amount = @as(u5, @truncate((shamt & 0x03) << 3));
    return value << amount;
}

pub fn sla(value: u32, shamt: u5) u32 {
    return shamt | (value << shamt);
}

pub fn sllv(value: u32, shift_reg_val: u32) u32 {
    // MIPS hardware ignores everything except the bottom 5 bits of the shift amount
    const amount = @as(u5, @truncate(shift_reg_val & 0x1F));
    return value << amount;
}

pub fn srl(value: u32, shamt: u5) u32 {
    return value >> shamt;
}

pub fn srlb(value: u32, shamt: u5) u32 {
    const amount = @as(u5, @truncate((shamt & 0x03) << 3));
    return value >> amount;
}

pub fn srlv(value: u32, shift_reg_val: u32) u32 {
    const amount = @as(u5, @truncate(shift_reg_val & 0x1F));
    return value >> amount;
}

pub fn sra(value: u32, shamt: u5) u32 {
    const signed_val: i32 = @bitCast(value);
    const shifted = signed_val >> shamt;

    return @bitCast(shifted);
}

pub fn srab(value: u32, shamt: u5) u32 {
    const amount = @as(u5, @truncate((shamt & 0x03) << 3));
    const signed_val: i32 = @bitCast(value);
    const shifted = signed_val >> amount;

    return @bitCast(shifted);
}

pub fn srav(value: u32, shift_reg_val: u32) u32 {
    const amount = @as(u5, @truncate(shift_reg_val & 0x1F));

    const signed_val: i32 = @bitCast(value);
    const shifted = signed_val >> amount;

    return @bitCast(shifted);
}
