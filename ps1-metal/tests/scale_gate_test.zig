//! The two opt-in scaled-path gates, ported from MetalScaleTests.swift:
//! Gate 3 writes images for what a machine cannot judge, and Gate 4 times
//! the replay at each scale. Both skip unless their variable is set, and the
//! skip names it:
//!
//!     PS1_DUMP_SCALED=4 zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=dumpsScaled
//!     PS1_SCALE_TIMING=1 zig build test-metal -Doptimize=ReleaseFast -Dmetal-filter=Timing

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");

const pi = ps1_metal.prim_instance;

const alloc = std.testing.allocator;
const io = std.testing.io;
const native_pixels = pi.native_pixels;

/// The variable's value, or a skip that says how to turn the gate on.
fn requireSwitch(name: []const u8, how: []const u8) ![]const u8 {
    return harness.gateSwitch(name) orelse {
        std.debug.print("{s} is unset; {s}\n", .{ name, how });
        return error.SkipZigTest;
    };
}

// MARK: Gate 3: images
//
// Seams along quad diagonals, texture bleeding and gaps between adjacent
// primitives are visible in an image and move no hash. Opt-in, because it
// writes ~50 MB of PNG and nothing asserts on it.

/// The densest frame of each geometry fixture by draw-record count, measured
/// 2026-08-29 over `zig-out/fixtures/`: Silent Hill frame 74 carries 1,694
/// draws and Tomb Raider frame 58 carries 281.
///
/// The two `ff7-mako-*` entries are an ad-hoc capture of a FIELD scene with a
/// character model in it: the shape neither geometry fixture has, and the one
/// a scale defect shows up in first, since a distant model's facets are about a
/// pixel across. They are captured by `stream-capture --cue=... --memcard=...
/// --input=...`, PGXP on and off, and are absent on any machine that has not
/// run it; `fixtureExists` skips them there.
const Gate3Frame = struct { name: []const u8, frame: usize };
const gate3_frames = [_]Gate3Frame{
    .{ .name = "silent-hill-usa", .frame = 74 }, .{ .name = "tr1-usa-v1-1", .frame = 58 },
    .{ .name = "ff7-mako-pgxp", .frame = 6 },    .{ .name = "ff7-mako-off", .frame = 6 },
};

test "dumpsScaledImagesForEyeballing" {
    const raw = try requireSwitch("PS1_DUMP_SCALED", "set it to <N> (1...8) to write the comparison PNGs");
    const n = std.fmt.parseInt(u32, raw, 10) catch 0;
    if (n < 1 or n > 8) {
        std.debug.print("PS1_DUMP_SCALED must hold 1...8, not \"{s}\"\n", .{raw});
        return error.TestUnexpectedResult;
    }
    const m = try harness.metal();
    defer m.deinit();

    const scales: []const u32 = if (n == 1) &.{1} else &.{ 1, n };
    var written: usize = 0;
    for (gate3_frames) |g| {
        if (!harness.fixtureExists(alloc, g.name)) continue;
        written += 1;
        for (scales) |scale| {
            // Two modes on the same frame, which is the comparison this phase
            // exists to make: `.scaled` is the smoothest of the dithering modes
            // and `.true_color` is the mode that has levels rather than a
            // pattern. `.off` is what the banding report describes and is one
            // edit away if it is wanted.
            for ([_]pi.DitherMode{ .scaled, .true_color }) |dither| {
                const f = try harness.replayTo(alloc, m, g.name, g.frame, scale, dither, dither == .true_color);
                defer f.deinit(alloc);
                const label = try std.fmt.allocPrint(alloc, "{s}-{s}", .{ g.name, @tagName(dither) });
                defer alloc.free(label);

                const path = try harness.pngPath(alloc, label, g.frame, scale, false);
                defer alloc.free(path);
                try harness.writeVramPng(path, f.scaled, f.width, f.height);

                if (f.sidecar) |side| {
                    const side_path = try harness.pngPath(alloc, label, g.frame, scale, true);
                    defer alloc.free(side_path);
                    try harness.writeSidecarPng(side_path, side, f.width, f.height);
                    var present: usize = 0;
                    var i: usize = 3;
                    while (i < side.len) : (i += 4) present += @intFromBool(side[i] != 0);
                    std.debug.print("[gate-3] {s} {s} @{d}x -> {s} ({d} of {d} subtexels present)\n", .{ g.name, @tagName(dither), scale, side_path, present, f.width * f.height });
                }
                // Neither geometry fixture uploads a texture; their windows
                // start from a blank VRAM, so their textured draws sample
                // whatever the fills and copies left behind and a texel of 0 is
                // a discarded HOLE. This number is how much picture there
                // actually is to read.
                std.debug.print("[gate-3] {s} {s} @{d}x -> {s} ({d} of {d} native px painted)\n", .{ g.name, @tagName(dither), scale, path, harness.painted(f.native), native_pixels });
            }
        }
    }
    // Every fixture absent is a gate that wrote nothing, which must not read
    // as one that wrote everything.
    if (written == 0) {
        std.debug.print("Gate 3 wrote no images: none of", .{});
        for (gate3_frames) |g| std.debug.print(" {s}", .{g.name});
        std.debug.print(" is generated; run `zig build fixtures -Doptimize=ReleaseFast`\n", .{});
        return error.SkipZigTest;
    }
}

// MARK: Gate 4: cost
//
// The bounding-box overdraw Phase B accepted deliberately costs s^2 more
// fragments, and it had never been measured at any scale. Opt-in: it is a
// measurement, not an assertion, and it replays the whole corpus at four
// scales under three filter settings. The value is ignored; set means on.

test "measuresReplayCostAtEachScale: Gate 4 Timing" {
    _ = try requireSwitch("PS1_SCALE_TIMING", "set it (to anything) to measure per-scale replay cost");
    const m = try harness.metal();
    defer m.deinit();

    const corpus = [_][]const u8{ "synthetic-primitives", "synthetic-movers" } ++
        harness.untextured_pl_fixtures ++ harness.mover_fixtures ++ [_][]const u8{ "silent-hill-usa", "tr1-usa-v1-1" };
    const Setting = struct { filter: pi.TextureFilter, sprite: pi.TextureFilter };
    const settings = [_]Setting{
        .{ .filter = .nearest, .sprite = .nearest },
        .{ .filter = .bilinear, .sprite = .nearest },
        .{ .filter = .bilinear, .sprite = .bilinear },
    };
    for (corpus) |name| {
        // `fixtureExists` covers the committed synthetics too: `fixturePath`
        // resolves those out of ps1-core/tests/goldens/fixtures before falling
        // back to zig-out.
        if (!harness.fixtureExists(alloc, name)) continue;
        for ([_]u32{ 1, 2, 4, 8 }) |scale| for (settings) |s| {
            const t0 = std.Io.Clock.awake.now(io);
            const frames = try harness.replayForTiming(alloc, m, name, scale, s.filter, s.sprite);
            const elapsed = t0.untilNow(io, .awake);
            const ms = @as(f64, @floatFromInt(elapsed.nanoseconds)) / 1e6;
            std.debug.print("[gate-4] {s:<30} @{d}x {s}/{s}  {d:>8.1} ms  ({d} frames)\n", .{ name, scale, @tagName(s.filter), @tagName(s.sprite), ms, frames });
        };
    }
}
