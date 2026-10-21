//! `ps1_interp` and `ps1_interp_w` answer with a float estimate corrected by
//! an integer remainder instead of a 64-bit divide, which the GPU emulates
//! slowly. The result must still equal the divide bit for bit, or Gate 1 and
//! the PGXP-on parity gate stop being equalities; the corpus exercises only
//! the weights real fixtures happen to produce, so this checks the arithmetic
//! itself. Ported from InterpolationExactnessTests.swift.
//!
//! `ps1_interp_fuzz` (Rasterizer.metal, compiled with the pipelines' own
//! fast-math flags) builds HALF its cases on a quotient boundary: that half is
//! what makes it a gate, since random inputs essentially never land within
//! 1e-7 of an integer quotient and a random-only version passed with the
//! correction deleted.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");

const objc = ps1_metal.objc;
const mtl = ps1_metal.mtl;
const enums = ps1_metal.mtl_enums;
const check = harness.check;

/// 2^26 cases per seed, four seeds: 2^28 in all.
const cases_per_seed = 1 << 26;
const seeds = [_]u32{ 1, 0x9E37_79B9, 0xDEAD_BEEF, 0x1234_5678 };

test "interpolationMatchesTheSixtyFourBitDivideExactly" {
    const m = try harness.metal();
    defer m.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();

    const function = m.lib.newFunction("ps1_interp_fuzz") orelse return error.MissingFuzzKernel;
    defer function.release();
    const pipeline = try m.device.newComputePipelineState(function);
    defer pipeline.release();
    const mismatches = m.device.newBuffer(8, enums.resourceOptions(.shared)) orelse return error.OutOfMemory;
    defer mismatches.release();
    const counts: *[2]u32 = @ptrCast(@alignCast(mismatches.contents()));

    for (seeds) |seed| {
        counts.* = .{ 0, 0 };
        const cmd = m.queue.commandBuffer() orelse return error.NoCommandBuffer;
        const enc = cmd.computeCommandEncoder() orelse return error.NoComputeEncoder;
        enc.setComputePipelineState(pipeline);
        enc.setBuffer(mismatches, 0, 0);
        enc.setBytes(std.mem.asBytes(&seed), 1);
        enc.dispatchThreads(.{ .width = cases_per_seed, .height = 1, .depth = 1 }, .{ .width = 256, .height = 1, .depth = 1 });
        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
        // A buffer the GPU faulted on leaves the counters at zero, which
        // would read as a pass.
        try check(cmd.status() == .completed, "fuzz command buffer ended with status {d}, seed {x}: {s}", .{
            @backingInt(cmd.status()), seed, cmd.errorDescription() orelse "no NSError",
        });
        try check(counts[0] == 0, "{d} affine mismatches, seed {x}", .{ counts[0], seed });
        try check(counts[1] == 0, "{d} perspective mismatches, seed {x}", .{ counts[1], seed });
    }
}
