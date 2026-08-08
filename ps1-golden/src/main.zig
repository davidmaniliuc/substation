const std = @import("std");

const usage =
    \\usage: ps1-golden <capture|verify> [options]
    \\
    \\  --filter=<substring>    only run workloads whose key contains this
    \\  --instructions=<n>      instructions per workload (default 600000000)
    \\  --interval=<n>          instructions between samples (default 2500000)
    \\  --bios=<path>           override the auto-selected BIOS
    \\
;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var it = init.minimal.args.iterate();
    _ = it.skip();
    const mode = it.next() orelse {
        std.debug.print("{s}", .{usage});
        return error.MissingMode;
    };

    if (!std.mem.eql(u8, mode, "capture") and !std.mem.eql(u8, mode, "verify")) {
        std.debug.print("{s}", .{usage});
        return error.UnknownMode;
    }

    std.debug.print("ps1-golden: mode={s}\n", .{mode});
}
