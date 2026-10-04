//! A deterministic pad schedule, keyed in MILLIONS of instructions.
//!
//! "700:circle;730:cross" presses Circle at 700M and Cross at 730M. The key is
//! millions because that is what `ps1-trace`'s `frame_*.ppm` snapshots are named
//! by, so a schedule is written by reading snapshots and naming the frame to act
//! on.
//!
//! It exists because the wandering `explore` walker cannot work a MENU: reaching
//! a saved game needs "Continue" chosen deliberately, not stumbled into. When a
//! schedule is present it OWNS the pad and the wandering presses are suppressed
//! for the run — two schedulers fighting over one button mask is not
//! reproducible, which is the whole point. The rotation lives here so the three
//! loops in `main.zig` share one copy of it.

const std = @import("std");
const Ticker = @import("ticker.zig").Ticker;

/// Buttons are active-low: 0 is pressed, so a press CLEARS one bit of 0xFFFF.
pub const released: u16 = 0xFFFF;

pub const Press = struct { at: u64, mask: u16 };

pub const Error = error{ Malformed, UnknownButton } || std.mem.Allocator.Error;

/// The bit each name occupies in the pad word, per `sio.zig`'s digital layout.
pub fn buttonBit(name: []const u8) ?u4 {
    const names = [_]struct { name: []const u8, bit: u4 }{
        .{ .name = "select", .bit = 0 },    .{ .name = "start", .bit = 3 },
        .{ .name = "up", .bit = 4 },        .{ .name = "right", .bit = 5 },
        .{ .name = "down", .bit = 6 },      .{ .name = "left", .bit = 7 },
        .{ .name = "l2", .bit = 8 },        .{ .name = "r2", .bit = 9 },
        .{ .name = "l1", .bit = 10 },       .{ .name = "r1", .bit = 11 },
        .{ .name = "triangle", .bit = 12 }, .{ .name = "circle", .bit = 13 },
        .{ .name = "cross", .bit = 14 },    .{ .name = "square", .bit = 15 },
    };
    for (names) |n| {
        if (std.mem.eql(u8, n.name, name)) return n.bit;
    }
    return null;
}

/// Parses "<millions>:<button>" items separated by ';' or ','. The result is
/// sorted by instruction, so events may be written in any order; events sharing
/// an instruction collapse to the last one rather than being dropped, which is
/// what makes a two-button press expressible at all.
pub fn parse(a: std.mem.Allocator, text: []const u8) Error![]Press {
    var out = std.ArrayList(Press).empty;
    errdefer out.deinit(a);

    var it = std.mem.tokenizeAny(u8, text, ";,");
    while (it.next()) |item| {
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse return Error.Malformed;
        const at = std.fmt.parseInt(u64, std.mem.trim(u8, item[0..colon], " "), 10) catch
            return Error.Malformed;
        const name = std.mem.trim(u8, item[colon + 1 ..], " ");
        const bit = buttonBit(name) orelse return Error.UnknownButton;
        try out.append(a, .{ .at = at * 1_000_000, .mask = released & ~(@as(u16, 1) << bit) });
    }

    const items = try out.toOwnedSlice(a);
    std.mem.sort(Press, items, {}, struct {
        fn lt(_: void, x: Press, y: Press) bool {
            return x.at < y.at;
        }
    }.lt);
    return items;
}

/// The rotation that walks intros, FMVs and title menus when no schedule is
/// given: Start, Cross, Circle, one press every `rotation_period`
/// instructions, each held for `hold`.
pub const rotation_period: u64 = 4_000_000;
pub const hold: u64 = 1_000_000;
const rotation = [_]u16{
    released & ~@as(u16, 1 << 3), // Start
    released & ~@as(u16, 1 << 14), // Cross
    released & ~@as(u16, 1 << 13), // Circle
};

/// What the pad holds over a run, as a function of the step count. A
/// schedule, when given, owns the pad and the rotation is off. Every event
/// fires at the first count at or past its instruction (see `ticker.zig`).
pub const Pad = struct {
    script: []const Press = &.{},
    idx: usize = 0,
    /// When the last scheduled press is released.
    release: ?u64 = null,
    press_at: Ticker = .init(rotation_period, 0),
    release_at: Ticker = .init(rotation_period, hold),
    rotation_idx: usize = 0,

    /// The mask to install at count `i`, or null when nothing changes.
    pub fn maskAt(p: *Pad, i: u64) ?u16 {
        if (p.script.len > 0) return p.scheduled(i);
        var mask: ?u16 = null;
        if (p.press_at.due(i) != null) {
            mask = rotation[p.rotation_idx];
            p.rotation_idx = (p.rotation_idx + 1) % rotation.len;
        }
        if (p.release_at.due(i) != null) mask = released;
        return mask;
    }

    /// The first count at which `maskAt` can return a mask. A linked chain
    /// stops there (`Cpu.runFor`), as one block per call would.
    pub fn next(p: *const Pad) u64 {
        if (p.script.len > 0) {
            const press = if (p.idx < p.script.len) p.script[p.idx].at else std.math.maxInt(u64);
            return @min(press, p.release orelse std.math.maxInt(u64));
        }
        return @min(p.press_at.next, p.release_at.next);
    }

    /// Events sharing a count collapse to the last; a later press moves the
    /// release, so a press is never cut short by an earlier one's hold.
    fn scheduled(p: *Pad, i: u64) ?u16 {
        var mask: ?u16 = null;
        while (p.idx < p.script.len and p.script[p.idx].at <= i) : (p.idx += 1) {
            mask = p.script[p.idx].mask;
            p.release = p.script[p.idx].at + hold;
        }
        if (mask) |m| return m;
        const r = p.release orelse return null;
        if (i < r) return null;
        p.release = null;
        return released;
    }
};

test "parse orders events and encodes active-low presses" {
    const items = try parse(std.testing.allocator, "730:cross;700:circle");
    defer std.testing.allocator.free(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(u64, 700_000_000), items[0].at);
    try std.testing.expectEqual(released & ~(@as(u16, 1) << 13), items[0].mask);
    try std.testing.expectEqual(@as(u64, 730_000_000), items[1].at);
    try std.testing.expectEqual(released & ~(@as(u16, 1) << 14), items[1].mask);
}

test "an unknown button is refused rather than silently ignored" {
    try std.testing.expectError(Error.UnknownButton, parse(std.testing.allocator, "700:banana"));
    try std.testing.expectError(Error.Malformed, parse(std.testing.allocator, "700circle"));
}

test "a schedule presses on its count and releases after the hold" {
    const items = try parse(std.testing.allocator, "1:cross");
    defer std.testing.allocator.free(items);
    var p = Pad{ .script = items };
    const cross = released & ~(@as(u16, 1) << 14);
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(0));
    try std.testing.expectEqual(@as(?u16, cross), p.maskAt(1_000_000));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1_000_000 + hold - 1));
    try std.testing.expectEqual(@as(?u16, released), p.maskAt(1_000_000 + hold));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1_000_000 + hold + 1));
}

test "a scheduled press inside a block fires once, at the first count past it" {
    const items = try parse(std.testing.allocator, "1:cross");
    defer std.testing.allocator.free(items);
    var p = Pad{ .script = items };
    const cross = released & ~(@as(u16, 1) << 14);
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(999_990));
    try std.testing.expectEqual(@as(?u16, cross), p.maskAt(1_000_031));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1_000_090));
    try std.testing.expectEqual(@as(?u16, released), p.maskAt(1_000_000 + hold + 40));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1_000_000 + hold + 90));
}

test "with no schedule the pad rotates Start, Cross, Circle" {
    var p = Pad{};
    try std.testing.expectEqual(@as(?u16, rotation[0]), p.maskAt(0));
    try std.testing.expectEqual(@as(?u16, null), p.maskAt(1));
    try std.testing.expectEqual(@as(?u16, released), p.maskAt(hold));
    try std.testing.expectEqual(@as(?u16, rotation[1]), p.maskAt(rotation_period));
    try std.testing.expectEqual(@as(?u16, released), p.maskAt(rotation_period + hold + 17));
    try std.testing.expectEqual(@as(?u16, rotation[2]), p.maskAt(2 * rotation_period + 5));
}

test "next names the first count at which the pad can change" {
    var p = Pad{};
    try std.testing.expectEqual(@as(u64, 0), p.next());
    _ = p.maskAt(0);
    try std.testing.expectEqual(hold, p.next());
    _ = p.maskAt(hold);
    try std.testing.expectEqual(rotation_period, p.next());

    const items = try parse(std.testing.allocator, "1:cross");
    defer std.testing.allocator.free(items);
    var s = Pad{ .script = items };
    try std.testing.expectEqual(@as(u64, 1_000_000), s.next());
    _ = s.maskAt(1_000_000);
    try std.testing.expectEqual(1_000_000 + hold, s.next());
}
