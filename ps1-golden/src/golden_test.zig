const std = @import("std");
const golden = @import("golden.zig");

test "serialize then parse round-trips" {
    const a = std.testing.allocator;

    var samples = [_]golden.Sample{
        .{ .instr = 2_500_000, .hashes = [_]u64{1} ** 12 },
        .{ .instr = 5_000_000, .hashes = [_]u64{0xDEADBEEFCAFEF00D} ** 12 },
    };
    const g = golden.Golden{
        .workload = "croc",
        .instructions = 600_000_000,
        .interval = 2_500_000,
        .samples = &samples,
    };

    const text = try golden.serialize(a, g);
    defer a.free(text);

    const back = try golden.parse(a, text);
    defer a.free(back.samples);

    try std.testing.expectEqualStrings("croc", back.workload);
    try std.testing.expectEqual(@as(u64, 600_000_000), back.instructions);
    try std.testing.expectEqual(@as(u64, 2_500_000), back.interval);
    try std.testing.expectEqual(@as(usize, 2), back.samples.len);
    try std.testing.expectEqual(@as(u64, 5_000_000), back.samples[1].instr);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEFCAFEF00D), back.samples[1].hashes[11]);
}

test "parse rejects a row with the wrong column count" {
    const a = std.testing.allocator;
    const text =
        \\# ps1-golden v1
        \\workload croc
        \\instructions 600000000
        \\interval 2500000
        \\2500000 1 2 3
        \\
    ;
    try std.testing.expectError(error.MalformedGolden, golden.parse(a, text));
}

test "parse rejects a golden missing a header line" {
    const a = std.testing.allocator;
    const text =
        \\# ps1-golden v1
        \\workload croc
        \\instructions 600000000
        \\2500000 1 1 1 1 1 1 1 1 1 1 1 1
        \\
    ;
    try std.testing.expectError(error.MalformedGolden, golden.parse(a, text));
}

test "sanitiseKey turns a rip directory name into a stable slug" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "Crash Bandicoot (Europe) (EDC)", .want = "crash-bandicoot-europe-edc" },
        .{ .in = "TR1 (USA) (v1.1)", .want = "tr1-usa-v1-1" },
        .{ .in = "Croc - Legend of the Gobbos", .want = "croc-legend-of-the-gobbos" },
        .{ .in = "Silent Hill (USA)", .want = "silent-hill-usa" },
    };
    for (cases) |c| {
        const got = try golden.sanitiseKey(a, c.in);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "biosForKey picks a region-matching BIOS" {
    try std.testing.expectEqualStrings(
        "SCPH-7502_BIOS_1997_EU.bin",
        golden.biosForKey("crash-bandicoot-europe-edc"),
    );
    try std.testing.expectEqualStrings(
        "SCPH-1001_BIOS_1995_US.bin",
        golden.biosForKey("silent-hill-usa"),
    );
    try std.testing.expectEqualStrings(
        "SCPH-1001_BIOS_1995_US.bin",
        golden.biosForKey("croc-legend-of-the-gobbos"),
    );
}

test "countCueFiles counts FILE directives" {
    const single = "FILE \"a.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n";
    const multi = "FILE \"a.bin\" BINARY\n  TRACK 01 MODE2/2352\nFILE \"b.bin\" BINARY\n  TRACK 02 AUDIO\n";
    try std.testing.expectEqual(@as(usize, 1), golden.countCueFiles(single));
    try std.testing.expectEqual(@as(usize, 2), golden.countCueFiles(multi));
}
