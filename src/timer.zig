const std = @import("std");

pub const Timer = struct {
    counter: u32 = 0,
    mode: u32 = 0,
    target: u32 = 0,

    pub fn read(self: *const Timer, offset: u32) u32 {
        return switch (offset) {
            0x0 => self.counter,
            0x4 => self.mode,
            0x8 => self.target,
            else => 0,
        };
    }

    pub fn write(self: *Timer, offset: u32, value: u32) void {
        switch (offset) {
            0x0 => self.counter = value & 0xFFFF,
            0x4 => {
                self.mode = value;
                self.counter = 0; // Reset counter on mode write
            },
            0x8 => self.target = value & 0xFFFF,
            else => {},
        }
    }

    pub fn step(self: *Timer, ticks: u32) bool {
        self.counter +%= ticks;
        var irq = false;

        if (self.target > 0 and self.counter >= self.target) {
            if ((self.mode & (1 << 3)) != 0) { // Reset counter on target
                self.counter = 0;
            }
            if ((self.mode & (1 << 4)) != 0) { // IRQ on target
                self.mode |= (1 << 11);
                irq = true;
            }
        }

        if (self.counter >= 0xFFFF) {
            if ((self.mode & (1 << 5)) != 0) { // IRQ on 0xFFFF overflow
                self.mode |= (1 << 12);
                irq = true;
            }
            self.counter = 0;
        }

        return irq;
    }

    pub fn usesExternalClock(self: *const Timer) bool {
        return (self.mode & (1 << 8)) != 0;
    }
};
