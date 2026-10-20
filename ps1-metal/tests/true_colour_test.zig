//! True colour's own gates, ported from TrueColourTests.swift.
//!
//! The primary assertion of the whole feature is negative: a rendering change
//! that moves no hash. VRAM in `.true_color` is byte-identical to VRAM in
//! `.off`, which is a mode every existing gate already covers; the difference
//! lives entirely in the sidecar, which no gate reads.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const objc = ps1_metal.objc;
const pi = ps1_metal.prim_instance;
const command = ps1_core.gpu.command;
const Command = command.Command;
const Frame = harness.Frame;
const Metal = harness.Metal;
const DitherMode = pi.DitherMode;

const alloc = std.testing.allocator;
const native_width = pi.native_width;
const vtx = harness.vtx;
const env = harness.env;
const fullDrawingArea = harness.fullDrawingArea;
const check = harness.check;

/// A shaded triangle over the left of VRAM with GP0(E1) bit 9 set, its three
/// vertex colours the only thing varying between the ramps below.
fn ramp(c0: u32, c1: u32, c2: u32) [3]Command {
    return .{ fullDrawingArea(), env(0xE1, 1 << 9), .{
        .kind = .draw_shaded_triangle,
        .v = .{ vtx(4, 4, 0, 0, c0), vtx(500, 8, 0, 0, c1), vtx(8, 300, 0, 0, c2) },
    } };
}

/// A shallow Gouraud ramp: a channel that changes by well under one 8-bit
/// step per pixel, which is where a +-4 dither offset decides the output and
/// a 5-bit truncation bands. The same geometry
/// `scaledDitheringActuallyChangesThePictureAboveOneX` uses, for the same
/// reason.
const dithered_ramp = ramp(0x0040_4040, 0x0050_5050, 0x0048_4848);

/// CONTROLLER RULING R3: the same geometry and the same GP0(E1) bit 9 as
/// `dithered_ramp`, but vertex colours spanning the WHOLE channel range.
///
/// `dithered_ramp`'s colours span 0x40..0x50 (seventeen distinct eight-bit
/// levels), so the `> 32` assertion below is arithmetically unreachable on it.
/// That assertion states the feature's whole value (256 levels per channel
/// instead of 32) and needs a ramp wide enough to carry it. `dithered_ramp`
/// stays shallow for the two tests that need it that way: the dither-offset
/// test (a +-4 offset has to cross a `>> 3` boundary) and the copy test (which
/// needs sub-five-bit detail to survive a blit).
const wide_ramp = ramp(0x0000_0000, 0x00FF_FFFF, 0x0080_8080);

fn expand5(c: u16) u8 {
    return @intCast((c << 3) | (c >> 2));
}

fn tcFrame(m: Metal, dither: DitherMode, want_sidecar: bool, records: []const Command) !Frame {
    return harness.frameOf(alloc, m, 1, .{ .dither = dither, .want_sidecar = want_sidecar }, records);
}

test "trueColourNeverAppliesADitherOffset" {
    // Mutually exclusive BY CONSTRUCTION: DuckStation asserts the same thing
    // (gpu_hw_shadergen.cpp:2479), and it is why this is a fourth case of
    // DitherMode rather than a second control beside it. Two controls that
    // cannot both be on is a control that silently no-ops.
    const m = try harness.metal();
    defer m.deinit();
    const off = try tcFrame(m, .off, false, &dithered_ramp);
    defer off.deinit(alloc);
    const tc = try tcFrame(m, .true_color, false, &dithered_ramp);
    defer tc.deinit(alloc);
    const nat = try tcFrame(m, .native, false, &dithered_ramp);
    defer nat.deinit(alloc);
    try check(std.mem.eql(u16, tc.native, off.native), "a dither offset reached VRAM in .true_color", .{});
    // The control: without this the test passes for a mode that does nothing.
    try check(!std.mem.eql(u16, nat.native, off.native), "the ramp carries no dithered primitive", .{});
}

test "theCorpusRendersIdenticalVramInTrueColourAndOff" {
    // The "moves no hash" claim, over real recorded streams rather than one
    // hand-built triangle. `.off` is a mode every existing gate already runs
    // at, so equality with it is what lets true colour ship as the default
    // without a gate exemption.
    const m = try harness.metal();
    defer m.deinit();
    for ([_][]const u8{ "synthetic-primitives", "synthetic-movers" }) |name| {
        const parsed = try harness.loadFixture(alloc, name);
        defer parsed.deinit(alloc);
        const off = try harness.Rig.create(alloc, m, .{});
        defer off.destroy();
        const tc = try harness.Rig.create(alloc, m, .{});
        defer tc.destroy();
        off.r.dither_mode = .off;
        tc.r.dither_mode = .true_color;
        for (0..parsed.frames.len) |i| {
            const pool = objc.Pool.push();
            defer pool.pop();
            const s = parsed.frameStream(i);
            off.frame(s.payload, s.records);
            tc.frame(s.payload, s.records);
            try check(off.vram.hash() == tc.vram.hash(), "{s} frame {d}: VRAM differs between .off and .true_color", .{ name, i });
        }
    }
}

test "aGouraudRampKeepsMoreThanThirtyTwoLevelsInTheSidecar" {
    // The reported defect, stated as a number. Dithering redistributes
    // quantisation error; it cannot add levels, and a 5-bit channel has 32 of
    // them at every internal resolution. This is what the sidecar buys.
    //
    // `wide_ramp`, not `dithered_ramp`: see CONTROLLER RULING R3 above.
    const m = try harness.metal();
    defer m.deinit();
    const tc = try tcFrame(m, .true_color, true, &wide_ramp);
    defer tc.deinit(alloc);
    const side = tc.sidecar.?;
    var vram_levels: std.StaticBitSet(32) = .empty;
    var side_levels: std.StaticBitSet(256) = .empty;
    for (tc.scaled, 0..) |p, i| {
        if (side[i * 4 + 3] != 255) continue;
        vram_levels.set(p & 0x1F);
        side_levels.set(side[i * 4]);
    }
    try check(vram_levels.count() <= 32, "{d} VRAM levels", .{vram_levels.count()});
    try check(side_levels.count() > 32, "the sidecar has {d} red levels: it is still five-bit data", .{side_levels.count()});
}

test "aFlatUntexturedDrawKeepsTheFiveBitCarveOut" {
    // DuckStation's ShouldTruncate32To16 (gpu_hw.cpp:167) still truncates a
    // draw that is untextured, unshaded AND undithered, with per-game traits
    // overriding it both ways. We adopt the carve-out and not the second menu
    // entry: a flat draw has no extra precision to carry, so it writes the
    // expansion of its own five-bit colour and there is nothing to choose.
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();
    rig.r.dither_mode = .true_color;
    rig.frame(&.{}, &.{ fullDrawingArea(), .{
        .kind = .draw_triangle,
        .value = 0x1555,
        .v = .{ vtx(10, 10, 0, 0, 0), vtx(200, 10, 0, 0, 0), vtx(10, 200, 0, 0, 0) },
    } });
    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    const i = (50 * native_width + 50) * 4;
    try std.testing.expectEqual(@as(u8, 255), side[i + 3]);
    // 0x1555 is r = 21, g = 10, b = 5.
    try std.testing.expectEqual(expand5(21), side[i]);
    try std.testing.expectEqual(expand5(10), side[i + 1]);
    try std.testing.expectEqual(expand5(5), side[i + 2]);
}

test "theSidecarNeverReachesTexelFetch" {
    // DuckStation samples indexed texture data out of its RGBA8 target and
    // converts back down. Ours keeps reading r16Uint, so on this axis the
    // sidecar is MORE accurate than the reference, and the way to prove it is
    // that a draw which samples a true-colour region produces the same VRAM as
    // the same draw in `.off`, where the sidecar holds nothing extra.
    const m = try harness.metal();
    defer m.deinit();
    const draw = [_]Command{
        fullDrawingArea(),
        // A ramp into the 16bpp texture page at (256, 0): the region the
        // sprite below samples. Its low three bits per channel are exactly
        // what the sidecar keeps and VRAM does not.
        .{ .kind = .draw_shaded_triangle, .v = .{ vtx(256, 0, 0, 0, 0x0011_2233), vtx(500, 4, 0, 0, 0x00AA_BBCC), vtx(260, 60, 0, 0, 0x0055_6677) } },
        .{
            .kind = .draw_textured_rectangle,
            .opcode = 0x65, // RAW: no modulation
            .tpage = 0x0104, // page x 4 (-> 256), 16bpp
            .x = 0,
            .y = 300,
            .w = 32,
            .h = 16,
            .v = .{ vtx(0, 0, 0, 0, 0), .{}, .{} },
        },
    };
    const off = try tcFrame(m, .off, false, &draw);
    defer off.deinit(alloc);
    const tc = try tcFrame(m, .true_color, false, &draw);
    defer tc.deinit(alloc);
    try check(std.mem.eql(u16, tc.native, off.native), "the sidecar leaked into a texel fetch", .{});
    // The control: the ramp really does have sub-five-bit detail to leak.
    const with_side = try tcFrame(m, .true_color, true, &draw);
    defer with_side.deinit(alloc);
    const side = with_side.sidecar.?;
    const i = 30 * native_width + 300;
    try std.testing.expectEqual(@as(u8, 255), side[i * 4 + 3]);
    try check(side[i * 4] != expand5(tc.native[i] & 0x1F), "the ramp carries no sub-five-bit detail at this pixel", .{});
}

test "aCopiedGradientKeepsItsPrecision" {
    // GP0(80) carries the sidecar in the same pass as VRAM, so an eight-bit
    // gradient survives a VRAM->VRAM blit, which is how a game's own
    // double-buffering or scroll does not silently re-quantise the picture.
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();
    rig.r.dither_mode = .true_color;
    // Source inside the ramp, destination blank.
    const copy: Command = .{ .kind = .copy_rect, .x = 4, .y = 4, .x2 = 600, .y2 = 400, .w = 64, .h = 64 };
    rig.frame(&.{}, &(dithered_ramp ++ [_]Command{copy}));

    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    const pixels = try rig.readback(alloc);
    defer alloc.free(pixels);
    var compared: usize = 0;
    var extra: usize = 0;
    for (0..64) |dy| for (0..64) |dx| {
        const s = ((4 + dy) * native_width + 4 + dx) * 4;
        const d = ((400 + dy) * native_width + 600 + dx) * 4;
        if (side[s + 3] != 255) continue;
        compared += 1;
        try check(std.mem.eql(u8, side[d .. d + 3], side[s .. s + 3]) and side[d + 3] == 255, "the copy re-quantised ({d}, {d})", .{ dx, dy });
        if (side[d] != expand5(pixels[(400 + dy) * native_width + 600 + dx] & 0x1F)) extra += 1;
    };
    try check(compared > 1000, "only {d} source pixels present", .{compared});
    try check(extra > 0, "the copied region carries no sub-five-bit detail to keep", .{});
}

/// A wide untextured ramp, then a semi-transparent layer composited over it:
/// the shape Silent Hill's fog is made of. Of that game's 86,285 recorded
/// draws, 47.9% are semi-transparent (38,724 textured triangles plus 2,550
/// shaded ones against 44,921 opaque), so roughly half its picture is a
/// composite and every layer of it used to re-quantise to five bits.
const blended_ramp = [_]Command{
    fullDrawingArea(),
    .{ .kind = .draw_shaded_triangle, .v = .{ vtx(4, 4, 0, 0, 0x0000_0000), vtx(500, 8, 0, 0, 0x00FF_FFFF), vtx(8, 300, 0, 0, 0x0080_8080) } },
    .{ .kind = .draw_shaded_triangle, .transparent = 1, .v = .{ vtx(4, 4, 0, 0, 0x0044_4444), vtx(500, 8, 0, 0, 0x0047_4747), vtx(8, 300, 0, 0, 0x0045_4545) } },
};

test "aBlendedDrawCompositesAtEightBitsInTrueColour" {
    // MILESTONE 2. This replaces `aBlendedDrawStillFallsBackToFiveBitsInMilestoneOne`,
    // which pinned the fallback precisely so that building the eight-bit path
    // would have a test to CHANGE rather than a silent gap to fill.
    //
    // The gate the spec set on building it was finding one scene that bands
    // because of layered blending, on the grounds that most PS1 "fog" is GTE
    // depth cueing baked into vertex colour: a single Gouraud draw. Silent
    // Hill is the counter-example and half its draws are composites.
    const m = try harness.metal();
    defer m.deinit();
    const tc = try tcFrame(m, .true_color, true, &blended_ramp);
    defer tc.deinit(alloc);
    const side = tc.sidecar.?;
    var levels: std.StaticBitSet(256) = .empty;
    var extra: usize = 0;
    var compared: usize = 0;
    for (20..280) |y| for (20..460) |x| {
        const i = y * native_width + x;
        if (side[i * 4 + 3] != 255) continue;
        compared += 1;
        levels.set(side[i * 4]);
        if (side[i * 4] != expand5(tc.scaled[i] & 0x1F)) extra += 1;
    };
    try check(compared > 1000, "only {d} pixels present", .{compared});
    try check(extra > 0, "a composited pixel still holds only the expansion of its five-bit result", .{});
    try check(levels.count() > 32, "the composite has {d} red levels; the blend is still re-quantising", .{levels.count()});
}

test "aBlendedDrawStillFallsBackToFiveBitsOutsideTrueColour" {
    // The other half of the milestone, and the reason the eight-bit blend is
    // gated on the mode rather than applied unconditionally. In `.off`,
    // `.native` and `.scaled` the sidecar's whole job is to hold exactly what
    // the display would have expanded from VRAM anyway: that identity is what
    // makes an invalidated rect invisible instead of a seam. An eight-bit
    // composite there would quietly smooth a picture the player asked to be
    // dithered and five-bit.
    const m = try harness.metal();
    defer m.deinit();
    for ([_]DitherMode{ .off, .native, .scaled }) |mode| {
        const f = try tcFrame(m, mode, true, &blended_ramp);
        defer f.deinit(alloc);
        const side = f.sidecar.?;
        var checked: usize = 0;
        var mismatches: usize = 0;
        for (20..280) |y| for (20..460) |x| {
            const i = y * native_width + x;
            if (side[i * 4 + 3] != 255) continue;
            checked += 1;
            const p = f.scaled[i];
            for (0..3) |ch| {
                const c: u16 = (p >> @intCast(5 * ch)) & 0x1F;
                if (side[i * 4 + ch] != expand5(c)) mismatches += 1;
            }
        };
        try check(checked > 1000, "{t}: only {d} pixels present", .{ mode, checked });
        try check(mismatches == 0, "{t}: {d} sidecar channels diverge from the expansion of VRAM; the eight-bit blend is not gated on the mode", .{ mode, mismatches });
    }
}

test "gateOneRunsAtADitheringModeRatherThanThePlayersDefault" {
    // Gate 1 compares against the fixture's own Zig hash, and `renderer.zig`
    // dithers whenever GP0(E1) bit 9 is set. The mode the harness runs at is
    // therefore part of the gate, not a preference, and it had been inherited
    // from DitherSetting.defaultMode, which is about to stop dithering.
    //
    // The divergence below is not a bug. It is the evidence that the pin is
    // load-bearing: without it, flipping the default turns every fixture hash
    // red and reads as a rendering regression.
    const m = try harness.metal();
    defer m.deinit();
    const tc = try harness.replay(alloc, m, "synthetic-primitives", .{ .up_to = 2, .dither = .true_color });
    defer tc.deinit(alloc);
    try check(tc.first_divergence != null, "frame 1 carries no dithered primitive; pin the gate with a frame that does", .{});

    const nat = try harness.replay(alloc, m, "synthetic-primitives", .{ .up_to = 2, .dither = .native });
    defer nat.deinit(alloc);
    try check(nat.first_divergence == null, "{s}", .{nat.message});
    // And the default is the pinned mode, never the player's.
    const default_options: harness.ReplayOptions = .{};
    try std.testing.expectEqual(DitherMode.native, default_options.dither);
}

/// The same wide shade ramp as `wide_ramp`, but MODULATING a texel instead of
/// painting the shade directly, which is what 77.5% of the draws in a real
/// Crash Bandicoot frame are (`crash-bandicoot-warped.p1fx`: 28,036 textured
/// triangles against 8,116 untextured shaded ones, and no textured rectangle
/// at all).
///
/// The texture page at (256, 0) is filled with 0x7FFF (every channel at 31),
/// so the only thing varying across the primitive is the shade, and the levels
/// counted below are the levels of the modulation.
const textured_wide_ramp = [_]Command{
    fullDrawingArea(),
    .{ .kind = .fill_rect, .value = 0x7FFF, .x = 256, .y = 0, .w = 256, .h = 256 },
    .{
        .kind = .draw_textured_triangle,
        .opcode = 0x34, // Gouraud + textured, MODULATED (bit 0 clear)
        .tpage = 0x0104, // page x 4 (-> 256), 16bpp
        .v = .{ vtx(4, 300, 0, 0, 0x0000_0000), vtx(500, 304, 64, 0, 0x00FF_FFFF), vtx(8, 500, 0, 64, 0x0080_8080) },
    },
};

test "aModulatedTexelKeepsMoreThanThirtyTwoLevelsInTheSidecar" {
    // The half of the reported defect that the sidecar did NOT fix on arrival.
    // `ps1_modulate` truncates the shade to five bits before multiplying, so a
    // textured surface's lighting ramp reached the sidecar with 32 levels at
    // best and 18 at a full-brightness texel: steps of 16 in an eight-bit
    // buffer, which is COARSER than the five-bit banding the sidecar exists to
    // remove. Only untextured Gouraud draws ever saw 256.
    const m = try harness.metal();
    defer m.deinit();
    const tc = try tcFrame(m, .true_color, true, &textured_wide_ramp);
    defer tc.deinit(alloc);
    const side = tc.sidecar.?;
    var vram_levels: std.StaticBitSet(32) = .empty;
    var side_levels: std.StaticBitSet(256) = .empty;
    // The triangle's own rows only: the fill above is a flat five-bit draw and
    // contributes exactly one level to both counts.
    for (310..490) |y| for (10..480) |x| {
        const i = y * native_width + x;
        if (side[i * 4 + 3] != 255) continue;
        vram_levels.set(tc.scaled[i] & 0x1F);
        side_levels.set(side[i * 4]);
    };
    // The control: without it a guard that returned early, or a box that
    // caught none of the triangle, would pass this test vacuously.
    try check(vram_levels.count() > 1, "the sampled region carries no modulated ramp; {d} VRAM levels, {d} sidecar levels", .{ vram_levels.count(), side_levels.count() });
    try check(vram_levels.count() <= 32, "{d} VRAM levels", .{vram_levels.count()});
    try check(side_levels.count() > 32, "the sidecar has {d} red levels across a modulated ramp; the shade is still cropped to five bits", .{side_levels.count()});
}
