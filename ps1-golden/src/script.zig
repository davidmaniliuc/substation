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
//! reproducible, which is the whole point.

const std = @import("std");

/// Buttons are active-low: 0 is pressed, so a press CLEARS one bit of 0xFFFF.
pub const released: u16 = 0xFFFF;

pub const Press = struct { at: u64, mask: u16 };

pub const Error = error{ Malformed, UnknownButton } || std.mem.Allocator.Error;

/// The bit each name occupies in the pad word, per `sio.zig`'s digital layout.
pub fn buttonBit(name: []const u8) ?u4 {
    const names = [_]struct { name: []const u8, bit: u4 }{
        .{ .name = "select", .bit = 0 },   .{ .name = "start", .bit = 3 },
        .{ .name = "up", .bit = 4 },       .{ .name = "right", .bit = 5 },
        .{ .name = "down", .bit = 6 },     .{ .name = "left", .bit = 7 },
        .{ .name = "l2", .bit = 8 },       .{ .name = "r2", .bit = 9 },
        .{ .name = "l1", .bit = 10 },      .{ .name = "r1", .bit = 11 },
        .{ .name = "triangle", .bit = 12 }, .{ .name = "circle", .bit = 13 },
        .{ .name = "cross", .bit = 14 },   .{ .name = "square", .bit = 15 },
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

/// Applies the schedule at instruction `i`. `hold` is how long a press is held.
/// Returns the mask to install, or null when nothing changes this instruction.
pub fn maskAt(items: []const Press, idx: *usize, i: u64, hold: u64) ?u16 {
    var mask: ?u16 = null;
    while (idx.* < items.len and items[idx.*].at == i) : (idx.* += 1) mask = items[idx.*].mask;
    if (mask) |m| return m;
    if (idx.* > 0 and i == items[idx.* - 1].at + hold) return released;
    return null;
}

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

test "maskAt presses on the tick and releases after the hold" {
    const items = try parse(std.testing.allocator, "1:cross");
    defer std.testing.allocator.free(items);
    var idx: usize = 0;
    try std.testing.expectEqual(@as(?u16, null), maskAt(items, &idx, 0, 100));
    try std.testing.expectEqual(released & ~(@as(u16, 1) << 14), maskAt(items, &idx, 1_000_000, 100).?);
    try std.testing.expectEqual(@as(?u16, null), maskAt(items, &idx, 1_000_050, 100));
    try std.testing.expectEqual(released, maskAt(items, &idx, 1_000_100, 100).?);
}
