const std = @import("std");

pub const Timer = struct {
    counter: u32 = 0,
    mode: u32 = 0,
    target: u32 = 0,
    prescale_counter: u32 = 0,

    pub fn read(self: *Timer, offset: u32) u32 {
        return switch (offset) {
            0x0 => self.counter,
            0x4 => blk: {
                // PSX-SPX: reading the mode register returns the current value but
                // then resets bit 11 (reached target) and bit 12 (reached 0xFFFF).
                // Without this, a BIOS/game poll of those flags sees them stuck set.
                const v = self.mode;
                self.mode &= ~@as(u32, (1 << 11) | (1 << 12));
                break :blk v;
            },
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
        var actual_ticks = ticks;

        if ((self.mode & 0x0300) == 0x0200) {
            // Sysclock / 8
            self.prescale_counter += ticks;
            actual_ticks = self.prescale_counter / 8;
            self.prescale_counter %= 8;
        }

        if (actual_ticks == 0) return false;

        const old_counter = self.counter;
        self.counter += actual_ticks;
        var irq = false;

        // Fire IRQ exactly when crossing the target (Edge Trigger)
        if (self.target > 0 and old_counter < self.target and self.counter >= self.target) {
            if ((self.mode & (1 << 3)) != 0) { // Reset counter on target
                self.counter %= self.target; // Keep the remainder for accuracy
            }
            if ((self.mode & (1 << 4)) != 0) { // IRQ on target
                self.mode |= (1 << 11);
                irq = true;
            }
        }

        // PS1 timers are 16-bit, so they overflow at 0x10000
        if (self.counter >= 0x10000) {
            if ((self.mode & (1 << 5)) != 0) { // IRQ on 0xFFFF overflow
                self.mode |= (1 << 12);
                irq = true;
            }
            self.counter &= 0xFFFF; // Wrap around to 16-bit range
        }

        return irq;
    }

    pub fn usesExternalClock(self: *const Timer) bool {
        return (self.mode & 0x0300) == 0x0100;
    }
};
