const std = @import("std");

/// Column order of a golden row. Must stay in lockstep with
/// `state_hash.Region` — `state_hash.zig` has a comptime assertion for it.
pub const region_names = [_][]const u8{
    "ram",   "io",  "vram", "cpu",
    "cdrom", "spu", "gpu",  "dma",
    "timer", "sio", "mdec", "interrupt",
};

pub const region_count = region_names.len;

pub const Sample = struct {
    instr: u64,
    hashes: [region_count]u64,
};

pub const Golden = struct {
    workload: []const u8,
    instructions: u64,
    interval: u64,
    samples: []Sample,
};

pub const ParseError = error{MalformedGolden} || std.mem.Allocator.Error || std.fmt.ParseIntError;

/// Line-oriented text so goldens diff readably in git and a divergence can be
/// eyeballed without tooling. 240 samples is roughly 53 KB.
pub fn serialize(allocator: std.mem.Allocator, g: Golden) ![]u8 {
    // std.ArrayList in 0.16 is unmanaged and has no `writer()`; `print` takes
    // the allocator directly.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "# ps1-golden v1\n", .{});
    try out.print(allocator, "# columns: instr", .{});
    for (region_names) |n| try out.print(allocator, " {s}", .{n});
    try out.print(allocator, "\n", .{});
    try out.print(allocator, "workload {s}\n", .{g.workload});
    try out.print(allocator, "instructions {d}\n", .{g.instructions});
    try out.print(allocator, "interval {d}\n", .{g.interval});

    for (g.samples) |s| {
        try out.print(allocator, "{d}", .{s.instr});
        for (s.hashes) |h| try out.print(allocator, " {x:0>16}", .{h});
        try out.print(allocator, "\n", .{});
    }

    return out.toOwnedSlice(allocator);
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Golden {
    var workload: []const u8 = "";
    var instructions: u64 = 0;
    var interval: u64 = 0;

    var samples = std.ArrayList(Sample).empty;
    errdefer samples.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "workload ")) {
            workload = line["workload ".len..];
            continue;
        }
        if (std.mem.startsWith(u8, line, "instructions ")) {
            instructions = try std.fmt.parseInt(u64, line["instructions ".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, line, "interval ")) {
            interval = try std.fmt.parseInt(u64, line["interval ".len..], 10);
            continue;
        }

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const instr_text = fields.next() orelse return error.MalformedGolden;
        var s = Sample{
            .instr = try std.fmt.parseInt(u64, instr_text, 10),
            .hashes = [_]u64{0} ** region_count,
        };
        var i: usize = 0;
        while (fields.next()) |tok| : (i += 1) {
            if (i >= region_count) return error.MalformedGolden;
            s.hashes[i] = try std.fmt.parseInt(u64, tok, 16);
        }
        if (i != region_count) return error.MalformedGolden;
        try samples.append(allocator, s);
    }

    return .{
        .workload = workload,
        .instructions = instructions,
        .interval = interval,
        .samples = try samples.toOwnedSlice(allocator),
    };
}
