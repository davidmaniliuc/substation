//! Gate 2 (downsample-invariance) over the paths that READ VRAM: texel fetch at all three depths, the memory
//! movers, the dither modes and the real-game fixtures. The untextured rungs
//! and Gate 2b are in scale_test.zig.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const pi = ps1_metal.prim_instance;
const command = ps1_core.gpu.command;
const Command = command.Command;

const alloc = std.testing.allocator;
const native_width = pi.native_width;
const native_pixels = pi.native_pixels;
const scale_ladder = harness.scale_ladder;
const painted = harness.painted;
const vtx = harness.vtx;
const env = harness.env;
const fullDrawingArea = harness.fullDrawingArea;
const check = harness.check;

// MARK: Gate 2: the sampling paths

/// A native VRAM holding one texture page at each depth plus a CLUT, laid out
/// the way `synthetic_prims.zig` lays its own out: 4bpp at (0,0), 8bpp at
/// (128,0), 16bpp at (256,0), CLUT row at (0,240). Entry 0 of the CLUT is
/// deliberately 0: a texel of 0 is a HOLE, discarded rather than drawn.
fn texturedVram(v: *[native_pixels]u16) void {
    @memset(v, 0);
    for (0..256) |i| v[240 * native_width + i] = if (i == 0) 0 else @truncate(i *% 0x0123);
    for (0..64) |y| for (0..64) |x| {
        const row = y * native_width;
        v[row + x] = @truncate((x +% y) *% 0x1111 +% 0x1234);
        v[row + 128 + x] = @truncate((x *% 7 +% y) *% 0x0303 +% 0x0A1B);
        // 16bpp texels must not be zero anywhere, or the hole discard
        // hides the comparison instead of making it.
        v[row + 256 + x] = @truncate((x +% y *% 64) | 0x0421);
    };
}

test "texturedTrianglesAreDownsampleInvariantAtAllThreeDepths" {
    // tpage bits: low 4 are the page X in 64-pixel units, bit 4 the page Y,
    // bits 7-8 the depth. Pages at x = 0 / 128 / 256 are units 0 / 2 / 4.
    const m = try harness.metal();
    defer m.deinit();
    const Page = struct { label: []const u8, tpage: u16 };
    const pages = [_]Page{ .{ .label = "4bpp", .tpage = 0x0000 }, .{ .label = "8bpp", .tpage = 0x0082 }, .{ .label = "16bpp", .tpage = 0x0104 } };
    const clut: u16 = 0 | (240 << 6); // clut_x = 0, clut_y = 240

    const vram = try alloc.create([native_pixels]u16);
    defer alloc.destroy(vram);
    texturedVram(vram);

    for (pages) |page| {
        const records = [_]Command{
            fullDrawingArea(),
            .{
                .kind = .draw_textured_triangle,
                .opcode = 0x25, // bit 0 SET: raw, no modulation
                .tpage = page.tpage,
                .clut = clut,
                // Destination well clear of the pages this samples, so the
                // draw cannot feed itself.
                .v = .{ vtx(400, 300, 0, 0, 0), vtx(460, 305, 60, 4, 0), vtx(405, 360, 2, 58, 0) },
            },
        };
        const one = try harness.frameOf(alloc, m, 1, .{ .preload = vram }, &records);
        defer one.deinit(alloc);
        // The draw must actually paint, or "invariant" is a statement about
        // two blank images.
        try check(painted(one.native) > 500, "{s} drew nothing", .{page.label});

        for (scale_ladder) |scale| {
            const many = try harness.frameOf(alloc, m, scale, .{ .preload = vram }, &records);
            defer many.deinit(alloc);
            var label: [32]u8 = undefined;
            try harness.expectSameNative(one, many, try std.fmt.bufPrint(&label, "{s} @{d}x", .{ page.label, scale }));
        }
    }
}

test "aSpriteWrapsItsTexcoordsInEightBitsAtEveryScale" {
    // `tu +% @truncate(xx)` on u8 is a WRAP, and it is in TEXEL units: it must
    // be computed from the native pixel, never from the subpixel. Computed
    // from px, an 8x sprite would wrap every 32 output pixels instead of every
    // 256 texels.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try alloc.create([native_pixels]u16);
    defer alloc.destroy(vram);
    @memset(vram, 0);
    for (0..256) |u| vram[256 + u] = @intCast(0x0100 + u);

    const records = [_]Command{
        fullDrawingArea(),
        .{
            .kind = .draw_textured_rectangle,
            .opcode = 0x65, // RAW: no modulation
            .tpage = 0x0104, // page x 4 (-> 256), 16bpp
            .x = 0,
            .y = 300,
            .w = 8,
            .h = 1,
            .v = .{ vtx(0, 0, 252, 0, 0), .{}, .{} },
        },
    };

    const scale = 3;
    const one = try harness.frameOf(alloc, m, 1, .{ .preload = vram }, &records);
    defer one.deinit(alloc);
    const many = try harness.frameOf(alloc, m, scale, .{ .preload = vram }, &records);
    defer many.deinit(alloc);

    const row = 300 * native_width;
    try std.testing.expectEqual(@as(u16, 0x01FF), one.native[row + 3]); // u = 255
    try std.testing.expectEqual(@as(u16, 0x0100), one.native[row + 4]); // u wrapped to 0: a clamp would repeat 0x01FF
    try harness.expectSameNative(one, many, "scale 3");

    // And texture data is NEVER upscaled: each native output pixel is a solid
    // s x s block of one texel, not a window into a finer texture.
    for (0..8) |x| {
        const want = one.native[row + x];
        for (0..scale) |sy| for (0..scale) |sx| {
            const i = (300 * scale + sy) * many.width + (x * scale + sx);
            if (many.scaled[i] != want) std.debug.print("sprite texel {d} subpixel ({d},{d})\n", .{ x, sx, sy });
            try std.testing.expectEqual(want, many.scaled[i]);
        };
    }
}

test "aClutIndexPastTheRowEndReadsIntoTheNextRowAtEveryScale" {
    // `Vram.index(x, y)` is `y * 1024 + x` with NO masking, so a CLUT whose
    // clut_x + index runs past 1023 reads into the NEXT ROW. That linearize
    // must happen in NATIVE space and only then be scaled: linearizing at
    // scale (`y*1024*s + x*s`) invents a different wrap, and no fixture in the
    // corpus exercises the case.
    //
    // 8bpp page at (256, 0) whose texel 0 is index 20, CLUT at x = 1008:
    // 1008 + 20 = 1028, past the row end, so the read lands at
    // (1028 - 1024, 100 + 1) = (4, 101).
    const m = try harness.metal();
    defer m.deinit();
    const vram = try alloc.create([native_pixels]u16);
    defer alloc.destroy(vram);
    @memset(vram, 0);
    vram[0 * native_width + 256] = 0x0014; // idx 20 in the low byte
    vram[100 * native_width + 4] = 0x5678; // the SAME-ROW answer
    vram[101 * native_width + 4] = 0x1234; // the correct one

    const records = [_]Command{
        fullDrawingArea(),
        .{
            .kind = .draw_textured_rectangle,
            .opcode = 0x65, // RAW
            .tpage = 0x0084, // page x 4 (-> 256), 8bpp
            .clut = 63 | (100 << 6), // clut_x = 1008, clut_y = 100
            .x = 10,
            .y = 300,
            .w = 1,
            .h = 1,
            .v = .{ vtx(0, 0, 0, 0, 0), .{}, .{} },
        },
    };

    for ([_]u32{1} ++ scale_ladder) |scale| {
        const f = try harness.frameOf(alloc, m, scale, .{ .preload = vram }, &records);
        defer f.deinit(alloc);
        if (f.native[300 * native_width + 10] != 0x1234) std.debug.print("scale {d}\n", .{scale});
        try std.testing.expectEqual(@as(u16, 0x1234), f.native[300 * native_width + 10]);
    }
}

test "theTombRaiderFixtureIsDownsampleInvariant" {
    // 12,440 textured triangles, 979 textured rectangles and 50 fills over 100
    // frames of real gameplay, and, measured, zero uploads and zero copies.
    const m = try harness.metal();
    defer m.deinit();
    try harness.expectInvariant(m, "tr1-usa-v1-1", .{});
}

// MARK: Gate 2: the memory movers

test "anUploadReplicatesEachPayloadPixelIntoAnNbyNBlock" {
    // Every subpixel of a block resolves to the same payload word, because
    // `pix` is computed from the NATIVE pixel. There is no replication code
    // and there must not be any: a second path would be a second thing to get
    // wrong at the one place where the CPU's bytes enter VRAM.
    const m = try harness.metal();
    defer m.deinit();
    const words = [_]u32{ 0xBBBB_AAAA, 0xDDDD_CCCC }; // 4 pixels, 2x2
    const records = [_]Command{
        .{ .kind = .vram_write_setup, .x = 40, .y = 50, .w = 2, .h = 2 },
        .{ .kind = .vram_write_data, .x = 0, .y = 2 }, // off, len: in WORDS
    };

    const scale = 3;
    const one = try harness.frameOf(alloc, m, 1, .{ .payload = &words }, &records);
    defer one.deinit(alloc);
    const many = try harness.frameOf(alloc, m, scale, .{ .payload = &words }, &records);
    defer many.deinit(alloc);

    const w = native_width;
    try std.testing.expectEqual(@as(u16, 0xAAAA), one.native[50 * w + 40]);
    try std.testing.expectEqual(@as(u16, 0xBBBB), one.native[50 * w + 41]);
    try std.testing.expectEqual(@as(u16, 0xCCCC), one.native[51 * w + 40]);
    try std.testing.expectEqual(@as(u16, 0xDDDD), one.native[51 * w + 41]);
    try harness.expectSameNative(one, many, "scale 3");

    const Block = struct { nx: usize, ny: usize, want: u16 };
    const blocks = [_]Block{ .{ .nx = 40, .ny = 50, .want = 0xAAAA }, .{ .nx = 41, .ny = 50, .want = 0xBBBB }, .{ .nx = 40, .ny = 51, .want = 0xCCCC }, .{ .nx = 41, .ny = 51, .want = 0xDDDD } };
    for (blocks) |b| for (0..scale) |sy| for (0..scale) |sx| {
        const i = (b.ny * scale + sy) * many.width + (b.nx * scale + sx);
        if (many.scaled[i] != b.want) std.debug.print("block ({d},{d}) subpixel ({d},{d})\n", .{ b.nx, b.ny, sx, sy });
        try std.testing.expectEqual(b.want, many.scaled[i]);
    };
}

test "aCopyPreservesScaledDetailRatherThanReplicatingTheNativePixel" {
    // The ONE mover that reads the scaled source. Its destination wrap is
    // native (the encoder has already split the rect into up to four boxes on
    // that basis), but the source read carries sub_x/sub_y, so content a game
    // moves around VRAM stays sharp instead of being flattened to its blocks'
    // top-left subtexels. Dropping those two terms still passes Gate 2, since
    // they are zero at every top-left subtexel; this is what catches it.
    const m = try harness.metal();
    defer m.deinit();
    const scale = 2;
    const rig = try harness.Rig.create(alloc, m, .{ .scale = scale });
    defer rig.destroy();
    const width = rig.vram.width();

    // A scaled source with a DIFFERENT value in every subpixel of every block.
    const scaled = try alloc.alloc(u16, rig.vram.pixelCount());
    defer alloc.free(scaled);
    @memset(scaled, 0);
    for (0..4 * scale) |y| for (0..4 * scale) |x| {
        scaled[y * width + x] = @intCast(0x0100 + y * 16 + x);
    };
    rig.vram.upload(scaled);

    // Source origin (0, 0), destination origin (100, 200).
    rig.frame(&.{}, &.{.{ .kind = .copy_rect, .x = 0, .y = 0, .x2 = 100, .y2 = 200, .w = 4, .h = 4 }});

    const out = try rig.readback(alloc);
    defer alloc.free(out);
    for (0..4 * scale) |y| for (0..4 * scale) |x| {
        const want = scaled[y * width + x];
        const got = out[(200 * scale + y) * width + (100 * scale + x)];
        if (got != want) std.debug.print("subpixel ({d},{d}): a replicating copy gives the block's top-left\n", .{ x, y });
        try std.testing.expectEqual(want, got);
    };
}

test "theWholeSyntheticPrimitivesFixtureIsDownsampleInvariant [validate]" {
    // Every frame, including 2 and 4 (uploads feeding textured draws in the
    // same frame) and 6 (the feedback loop: a draw sampling a page this very
    // frame drew into, which is what makes pass splitting load-bearing).
    const m = try harness.metal();
    defer m.deinit();
    try harness.expectInvariant(m, "synthetic-primitives", .{});
}

test "aNativeDitheredReplayIsStillDownsampleInvariant" {
    // Dithering used to be OFF above 1x, and the reason was that it was the
    // single exception to downsample-invariance. That was only ever true of a
    // pattern indexed by the SUBTEXEL. `.native` indexes by the native pixel,
    // so every subtexel of a pixel carries that pixel's own 1x offset and the
    // top-left subtexel (the only one `readbackNative` reads) gets exactly
    // the 1x answer. The exception is not inherent to dithering; it belongs to
    // `.scaled` alone, which is the property it trades for the smoother
    // picture.
    //
    // Run on the synthetic ladder rather than a hand-built triangle because
    // the dither flag has to reach Gouraud triangles, shaded lines and
    // modulated texels, and those are three separate code paths in the
    // fragment shader.
    const m = try harness.metal();
    defer m.deinit();
    try harness.expectInvariant(m, "synthetic-primitives", .{ .dither = .native });
}

test "scaledDitheringActuallyChangesThePictureAboveOneX" {
    // The other half: a mode that costs the invariance property had better be
    // buying something with it. Without this, indexing `.scaled` by the native
    // pixel by mistake would leave every other test here green: the 1x gates
    // cannot see it, because at s == 1 the two modes ARE the same expression,
    // and `aNativeDitheredReplay…` above would simply pass twice.
    const m = try harness.metal();
    defer m.deinit();
    const records = [_]Command{
        fullDrawingArea(),
        // GP0(E1) bit 9 is the dither enable, and the encoder clears the flag
        // on anything unshaded, so a SHADED triangle is the only primitive
        // that can carry it here.
        env(0xE1, 1 << 9),
        // A shallow ramp over a wide span: the interpolated channel changes by
        // well under one 8-bit step per pixel, which is exactly where a ±4
        // dither offset decides the output and a 5-bit truncation bands.
        .{ .kind = .draw_shaded_triangle, .v = .{
            vtx(4, 4, 0, 0, 0x0040_4040),
            vtx(500, 8, 0, 0, 0x0050_5050),
            vtx(8, 300, 0, 0, 0x0048_4848),
        } },
    };

    const one = try harness.frameOf(alloc, m, 1, .{ .dither = .native }, &records);
    defer one.deinit(alloc);
    const one_scaled = try harness.frameOf(alloc, m, 1, .{ .dither = .scaled }, &records);
    defer one_scaled.deinit(alloc);
    // At s == 1 the two index expressions ARE the same, which is what lets the
    // shipped default be `.scaled` without moving a single Gate 1 hash.
    try harness.expectSameNative(one, one_scaled, "the modes differ at 1x");

    for (scale_ladder) |scale| {
        const native = try harness.frameOf(alloc, m, scale, .{ .dither = .native }, &records);
        defer native.deinit(alloc);
        const scaled = try harness.frameOf(alloc, m, scale, .{ .dither = .scaled }, &records);
        defer scaled.deinit(alloc);
        // `.native` hands every subtexel its native pixel's own offset, so the
        // lattice carries the 1x answer unchanged. This is the fixture gate's
        // property, asserted here on geometry chosen to exercise it.
        var label: [48]u8 = undefined;
        try harness.expectSameNative(one, native, try std.fmt.bufPrint(&label, "@{d}x: .native moved the lattice", .{scale}));
        // `.scaled` indexes by the subtexel, so it lands on a different cell of
        // the table at the lattice too; `px == nx * s`, and that is congruent
        // to `nx` mod 4 only at s == 1. Diverging HERE is not a bug in the
        // mode; it is precisely the invariance it trades away, and the reason
        // the fixture gate cannot be run at `.scaled`.
        try check(!std.mem.eql(u16, scaled.native, one.native), "@{d}x: .scaled sampled the native pixel", .{scale});
    }
}

test "theCommittedMoverFixtureIsDownsampleInvariant" {
    const m = try harness.metal();
    defer m.deinit();
    try harness.expectInvariant(m, "synthetic-movers", .{});
}

test "theMoverFixturesAreDownsampleInvariant" {
    const m = try harness.metal();
    defer m.deinit();
    try harness.expectInvariantWherePresent(m, &harness.mover_fixtures);
}

test "theSilentHillFixtureIsDownsampleInvariant" {
    // 100 frames of real gameplay: 55,793 textured triangles, 28,120 Gouraud
    // triangles, 132 sprites, 100 copies and 50 fills.
    const m = try harness.metal();
    defer m.deinit();
    try harness.expectInvariant(m, "silent-hill-usa", .{});
}
