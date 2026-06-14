const std = @import("std");

pub const Irq = enum(u5) {
    Vblank = 0,
    Gpu = 1,
    Cdrom = 2,
    Dma = 3,
    Timer0 = 4,
    Timer1 = 5,
    Timer2 = 6,
    Controller = 7,
    Sio = 8,
    Spu = 9,
    Lightpen = 10,
};

pub const InterruptController = struct {
    const Self = @This();

    stat: u32 = 0,
    mask: u32 = 0,

    pub fn readStat(self: *const Self) u32 {
        return self.stat;
    }

    pub fn writeStat(self: *Self, value: u32) void {
        // Writing 0 to a bit acknowledges (clears) the interrupt.
        // Writing 1 has no effect.
        if (value == 0xFFFFFFFB) {
        } else if ((value & 4) == 0) {
        }
        self.stat &= value;
    }

    pub fn readMask(self: *const Self) u32 {
        return self.mask;
    }

    pub fn writeMask(self: *Self, value: u32) void {
        // Only 11 bits are used (0-10)
        self.mask = value & 0xFFFF0FFF;
    }

    pub fn trigger(self: *Self, irq: Irq) void {
        const bit = @as(u32, 1) << @intFromEnum(irq);
        if (irq == .Cdrom) {
        }
        self.stat |= bit;
    }

    pub fn hasPendingIrq(self: *const Self) bool {
        return (self.stat & self.mask) != 0;
    }
};
