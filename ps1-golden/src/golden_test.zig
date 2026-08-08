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
