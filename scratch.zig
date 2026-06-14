const std = @import("std");

pub fn main() void {
    std.debug.print("{x}\n", .{0xDEADBEEF});
}
