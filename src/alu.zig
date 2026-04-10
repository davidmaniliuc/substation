const std = @import("std");

pub fn sll(value: u32, shamt: u5) u32 {
    return value << shamt;
}

pub fn sllv(value: u32, shift_reg_val: u32) u32 {
    // MIPS hardware ignores everything except the bottom 5 bits of the shift amount
    const amount = @as(u5, @truncate(shift_reg_val & 0x1F));
    return value << amount;
}

pub fn srl(value: u32, shamt: u5) u32 {
    return value >> shamt;
}

pub fn srlv(value: u32, shift_reg_val: u32) u32 {
    const amount = @as(u5, @truncate(shift_reg_val & 0x1F));
    return value >> amount;
}
