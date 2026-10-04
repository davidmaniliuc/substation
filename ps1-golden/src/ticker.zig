//! A schedule over a counter that can advance by more than one at a time.
//! A block engine's `run()` stands for up to a block's worth of steps, so a
//! frontend's counter can step over the instruction an event names. An event
//! fires at the first count at or past it. With a counter that advances by
//! one, that is exactly the named instruction, which is why the
//! interpreter's goldens do not move.

const std = @import("std");

pub const Ticker = struct {
    next: u64,
    period: u64,

    /// Every `period`, first at `phase`.
    pub fn init(period: u64, phase: u64) Ticker {
        return .{ .next = phase, .period = period };
    }

    /// The event's own count once `i` has reached it, else null. One event
    /// per call, so a period shorter than one `run()` would fall behind;
    /// `ps1-golden` refuses such a period.
    pub fn due(t: *Ticker, i: u64) ?u64 {
        if (i < t.next) return null;
        const at = t.next;
        t.next += t.period;
        return at;
    }
};

test "a ticker fires on its exact count when the counter steps by one" {
    var t = Ticker.init(10, 0);
    var fired: [3]u64 = undefined;
    var n: usize = 0;
    for (0..25) |i| {
        if (t.due(i)) |at| {
            try std.testing.expectEqual(@as(u64, i), at);
            fired[n] = at;
            n += 1;
        }
    }
    try std.testing.expectEqualSlices(u64, &.{ 0, 10, 20 }, fired[0..n]);
}

test "an event the counter steps over fires once, at the first count past it" {
    var t = Ticker.init(10, 3);
    try std.testing.expectEqual(@as(?u64, null), t.due(0));
    try std.testing.expectEqual(@as(?u64, 3), t.due(7));
    try std.testing.expectEqual(@as(?u64, null), t.due(9));
    try std.testing.expectEqual(@as(?u64, 13), t.due(15));
    try std.testing.expectEqual(@as(?u64, null), t.due(16));
}
