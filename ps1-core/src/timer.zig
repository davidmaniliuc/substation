const std = @import("std");

/// Timer mode register's 2-bit Clock Source field (bits 9-8). `Timer` is one
/// struct shared by all three timer instances, and this `step()` decodes the
/// field the same way regardless of which instance it is — real hardware's
/// per-timer semantics (Timer0: dotclock, Timer1: hblank, Timer2: sysclk/8)
/// are not modeled here; that distinction, if it matters, lives in whatever
/// tick count each caller hands to `step()`. Naming these bit patterns is not
/// a claim that the mask's uniform "0x0200 means /8" treatment is correct for
/// every timer on real hardware.
const mode_clock_source_mask: u32 = 0x0300;
const mode_clock_source_sysclk_div8: u32 = 0x0200;
const mode_clock_source_external: u32 = 0x0100;
const sysclk_div8_divisor: u32 = 8;

/// PS1 timers are 16-bit: the counter/target registers are masked to this
/// width on write, and the counter overflows one past it.
const counter_mask: u32 = 0xFFFF;
const counter_overflow: u32 = 0x10000;

pub const Timer = struct {
    counter: u32 = 0,
    mode: u32 = 0,
    target: u32 = 0,
    prescale_counter: u32 = 0,

    /// Input ticks stepped past without applying them, and the input ticks
    /// until the counter next reaches its target or overflows — the guard
    /// `cdrom.zig` and `gpu.zig` carry; `cdrom.zig`'s `pending_cycles` holds
    /// the rules all three obey.
    ///
    /// Unlike those two, `stepRaw` has no order-dependence between its
    /// blocks, so a batch is interchangeable with a stream of small steps and
    /// needs no `applyElapsed` split — PROVIDED it crosses at most one
    /// boundary, which is what `nextDeadline` buys.
    ///
    /// `counter` is software-readable at any instruction, so `read` and
    /// `write` settle first; `ps1-golden` settles before each sample.
    pending_ticks: u32 = 0,
    event_countdown: i64 = 0,

    pub fn read(self: *Timer, offset: u32) u32 {
        self.catchUp();
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
        self.catchUp();
        switch (offset) {
            0x0 => self.counter = value & counter_mask,
            0x4 => {
                self.mode = value;
                self.counter = 0; // Reset counter on mode write
            },
            0x8 => self.target = value & counter_mask,
            else => {},
        }
    }

    pub inline fn step(self: *Timer, ticks: u32) bool {
        self.pending_ticks += ticks;
        self.event_countdown -= ticks;
        if (self.event_countdown > 0) return false;
        return self.stepEvents();
    }

    fn stepEvents(self: *Timer) bool {
        @branchHint(.cold);
        const ticks = self.pending_ticks;
        self.pending_ticks = 0;
        const irq = self.stepRaw(ticks);
        self.event_countdown = self.nextDeadline();
        return irq;
    }

    /// Input ticks until the counter next reaches its target or overflows,
    /// whichever comes first. BOTH must be in the minimum: `stepRaw` detects
    /// one crossing per call, so a batch that crossed the target on its way
    /// to overflow would never raise the target IRQ.
    fn nextDeadline(self: *const Timer) i64 {
        const div: i64 = if ((self.mode & mode_clock_source_mask) == mode_clock_source_sysclk_div8)
            sysclk_div8_divisor
        else
            1;

        var counter_ticks: i64 = @as(i64, counter_overflow) - @as(i64, self.counter);
        if (self.target > 0 and self.counter < self.target) {
            counter_ticks = @min(counter_ticks, @as(i64, self.target) - @as(i64, self.counter));
        }
        return @max(counter_ticks * div - @as(i64, self.prescale_counter), 1);
    }

    /// Applies everything `step` deferred. Cannot raise an IRQ: no crossing
    /// falls inside the skipped window. Re-arms FIRST and unconditionally,
    /// for the reason on `cdrom.zig`'s `catchUp`.
    pub fn catchUp(self: *Timer) void {
        self.event_countdown = 0;
        if (self.pending_ticks == 0) return;
        const ticks = self.pending_ticks;
        self.pending_ticks = 0;
        _ = self.stepRaw(ticks);
    }

    fn stepRaw(self: *Timer, ticks: u32) bool {
        var actual_ticks = ticks;

        if ((self.mode & mode_clock_source_mask) == mode_clock_source_sysclk_div8) {
            // Sysclock / 8
            self.prescale_counter += ticks;
            actual_ticks = self.prescale_counter / sysclk_div8_divisor;
            self.prescale_counter %= sysclk_div8_divisor;
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
        if (self.counter >= counter_overflow) {
            if ((self.mode & (1 << 5)) != 0) { // IRQ on 0xFFFF overflow
                self.mode |= (1 << 12);
                irq = true;
            }
            self.counter &= counter_mask; // Wrap around to 16-bit range
        }

        return irq;
    }

    pub fn usesExternalClock(self: *const Timer) bool {
        return (self.mode & mode_clock_source_mask) == mode_clock_source_external;
    }
};
