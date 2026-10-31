const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Ratio = @import("ps1_core").overclock.Ratio;

fn randomRatio(rng: std.Random) Ratio {
    return Ratio.fromPercent(rng.intRangeAtMost(u32, 10, 1000));
}

test "fromPercent reduces and clamps" {
    try expectEqual(Ratio{ .num = 1, .den = 1 }, Ratio.fromPercent(100));
    try expectEqual(Ratio{ .num = 3, .den = 2 }, Ratio.fromPercent(150));
    try expectEqual(Ratio{ .num = 5, .den = 2 }, Ratio.fromPercent(250));
    try expectEqual(Ratio{ .num = 19, .den = 20 }, Ratio.fromPercent(95));
    try expectEqual(Ratio{ .num = 99, .den = 100 }, Ratio.fromPercent(99));
    try expectEqual(Ratio{ .num = 999, .den = 100 }, Ratio.fromPercent(999));
    try expectEqual(Ratio{ .num = 1, .den = 10 }, Ratio.fromPercent(5));
    try expectEqual(Ratio{ .num = 10, .den = 1 }, Ratio.fromPercent(5000));
    try expectEqual(Ratio{ .num = 1, .den = 10 }, Ratio.fromPercent(0));
    for (10..1001) |p| try expectEqual(@as(u32, @intCast(p)), Ratio.fromPercent(@intCast(p)).percent());
}

test "the unit ratio is the identity and never moves the carry" {
    const r = Ratio.fromPercent(100);
    var prng = std.Random.DefaultPrng.init(0x0C);
    const rng = prng.random();
    var frac: u32 = 0;
    for (0..10_000) |_| {
        const c = rng.int(u32);
        try expectEqual(c, r.toReal(c, &frac));
        try expectEqual(@as(u32, 0), frac);
        const v = rng.int(u16);
        try expectEqual(@as(u32, v), r.drawCost(v));
        const d = rng.intRangeAtMost(i32, 0, 1 << 24);
        try expectEqual(@as(u32, @intCast(@divTrunc(d * 7, 11))), r.stallCycles(d));
    }
    var real: i64 = -5;
    while (real <= 1_000_000) : (real += 1) try expectEqual(real, r.cpuCyclesFor(real, 0));
}

test "toReal over chunks equals toReal over the sum" {
    var prng = std.Random.DefaultPrng.init(0x5C);
    const rng = prng.random();
    for (0..2_000) |_| {
        const r = randomRatio(rng);
        var frac_chunks: u32 = 0;
        var frac_whole: u32 = 0;
        var sum_out: u64 = 0;
        var total: u32 = 0;
        for (0..rng.intRangeAtMost(usize, 1, 40)) |_| {
            const c = rng.intRangeAtMost(u32, 0, 100_000);
            total += c;
            sum_out += r.toReal(c, &frac_chunks);
            try expect(frac_chunks < r.num);
        }
        try expectEqual(sum_out, r.toReal(total, &frac_whole));
        try expectEqual(frac_whole, frac_chunks);
    }
}

test "cpuCyclesFor names exactly the cycle the device fires on" {
    var prng = std.Random.DefaultPrng.init(0xF1);
    const rng = prng.random();
    for (0..20_000) |_| {
        const r = randomRatio(rng);
        const frac = rng.uintLessThan(u32, r.num);
        const real = rng.intRangeAtMost(i64, 1, 2_000_000);
        const c = r.cpuCyclesFor(real, frac);
        var f = frac;
        try expect(r.toReal(@intCast(c), &f) >= real);
        if (c >= 1) {
            f = frac;
            try expect(r.toReal(@intCast(c - 1), &f) < real);
        }
    }
}

test "drawCost never charges zero for a non-zero draw" {
    const r = Ratio.fromPercent(1000);
    try expect(r.drawCost(1) >= 1);
    try expectEqual(@as(u32, 0), r.drawCost(0));
}
