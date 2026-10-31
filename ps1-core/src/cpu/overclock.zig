//! The CPU clock as a whole percentage of the real one.
//!
//! The machine runs on two clocks once the CPU is overclocked. REAL time is
//! what the player sees and hears and does not move with the setting: the
//! GPU's video timing (and so the frame rate and timers 0/1 on their external
//! clocks), the CD drive and the SPU. CPU time scales with it: the root
//! counters on the system clock, DMA and its CPU window, MDEC, the SIO /ACK
//! and the GPU's drawing time. The scheduler hands every device CPU cycles;
//! `toReal` converts the real-clock devices' share at the hand-over, and
//! `cpuCyclesFor` converts their deadlines back. At 100% both are the
//! identity, which is what keeps the machine bit-identical there.

const std = @import("std");

pub const min_percent: u32 = 10;
pub const max_percent: u32 = 1000;

/// CPU cycles per real cycle, `num/den`: a reduced fraction of `percent/100`, so `num <= 1000` and `den <= 100`.
pub const Ratio = struct {
    num: u32 = 1,
    den: u32 = 1,

    /// Clamped to `min_percent..max_percent`, never refused.
    pub fn fromPercent(p: u32) Ratio {
        const clamped = std.math.clamp(p, min_percent, max_percent);
        const g = std.math.gcd(clamped, 100);
        return .{ .num = clamped / g, .den = 100 / g };
    }

    /// Exact: a reduced `p/100` scales back to `p`.
    pub fn percent(self: Ratio) u32 {
        return self.num * 100 / self.den;
    }

    pub fn isUnit(self: Ratio) bool {
        return self.num == self.den;
    }

    /// Real cycles in `cycles` CPU cycles: `floor((cycles*den + frac) / num)`,
    /// leaving the remainder in `frac`, which stays in `[0, num)`.
    pub fn toReal(self: Ratio, cycles: u32, frac: *u32) u32 {
        if (self.isUnit()) return cycles;
        const scaled = @as(u64, cycles) * self.den + frac.*;
        frac.* = @intCast(scaled % self.num);
        return @intCast(scaled / self.num);
    }

    /// CPU cycles after which `toReal`, starting from `frac`, has handed over
    /// `real` real cycles: `ceil((real*num - frac) / den)`. Zero or less for
    /// a `real` that is.
    pub fn cpuCyclesFor(self: Ratio, real: i64, frac: u32) i64 {
        if (self.isUnit()) return real;
        const den: i64 = self.den;
        return @divFloor(real * self.num - frac + den - 1, den);
    }

    /// The real video cycles a draw of `video` cycles at the real clock costs
    /// once drawing follows the CPU: `ceil(video*den / num)`, so a draw never
    /// costs nothing.
    pub fn drawCost(self: Ratio, video: u32) u32 {
        if (self.isUnit()) return video;
        return @intCast((@as(u64, video) * self.den + self.num - 1) / self.num);
    }

    /// CPU cycles to drain `debt` video cycles: 7/11 of them at the real
    /// clock, scaled by `num/den`.
    pub fn stallCycles(self: Ratio, debt: i32) u32 {
        const scaled: i64 = @divTrunc(@as(i64, debt) * 7 * self.num, 11 * @as(i64, self.den));
        return @intCast(scaled);
    }
};
