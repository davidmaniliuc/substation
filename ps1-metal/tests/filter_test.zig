//! Texture filtering's own gates, ported from TextureFilterTests.swift.
//!
//! The primary assertion is negative, as true colour's was: VRAM is
//! byte-identical under both filters, so nothing a gate reads can move. The
//! rest pin the sidecar: what filtering adds, and the three ways it could
//! smear the wrong colour in (a hole, an atlas neighbour, a texture window).

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const objc = ps1_metal.objc;
const pi = ps1_metal.prim_instance;
const command = ps1_core.gpu.command;
const Command = command.Command;
const Metal = harness.Metal;
const DitherMode = pi.DitherMode;
const TextureFilter = pi.TextureFilter;

const alloc = std.testing.allocator;
const w = pi.native_width;
const env = harness.env;
const check = harness.check;

const fh = @import("filter_harness.zig");
const page16 = fh.page16;
const page_x = fh.page_x;
const edge_row = fh.edge_row;
const blankVram = fh.blankVram;
const vramWithRows = fh.vramWithRows;
const windowVram = fh.windowVram;
const texturedTriangle = fh.texturedTriangle;
const mappedTriangle = fh.mappedTriangle;
const texturedRectangle = fh.texturedRectangle;
const overDarkRed = fh.overDarkRed;
const shot = fh.shot;
const sidecarStats = fh.sidecarStats;
const distinctReds = fh.distinctReds;
const sameSidecar = fh.sameSidecar;
const sameVram = fh.sameVram;

// MARK: VRAM never moves

test "theCorpusRendersIdenticalVramUnderEverySetting" {
    // THE gate. Every fixture that exists, every frame, two dither modes (a
    // dithering one, since the VRAM path there carries the offset) and two
    // scales (3 because `/ s` is a shift at every power of two), and every
    // combination of the two settings against Nearest/Nearest.
    // `tr1-usa-v1-1-pgxp` is the one that carries perspective texcoords.
    const m = try harness.metal();
    defer m.deinit();
    const corpus = [_][]const u8{ "synthetic-primitives", "synthetic-movers", "silent-hill-usa", "tr1-usa-v1-1", "tr1-usa-v1-1-pgxp" };
    const settings = [_][2]TextureFilter{ .{ .nearest, .nearest }, .{ .bilinear, .nearest }, .{ .nearest, .bilinear }, .{ .bilinear, .bilinear } };
    var processed: usize = 0;
    for (corpus) |name| {
        if (!harness.fixtureExists(alloc, name)) continue;
        processed += 1;
        const parsed = try harness.loadFixture(alloc, name);
        defer parsed.deinit(alloc);
        for ([_]DitherMode{ .native, .true_color }) |dither| for ([_]u32{ 1, 3 }) |scale| {
            var rigs: [settings.len]*harness.Rig = undefined;
            var made: usize = 0;
            defer for (rigs[0..made]) |rig| rig.destroy();
            for (settings, 0..) |s, k| {
                rigs[k] = try harness.Rig.create(alloc, m, .{ .scale = scale });
                made += 1;
                rigs[k].r.dither_mode = dither;
                rigs[k].r.texture_filter = s[0];
                rigs[k].r.sprite_filter = s[1];
            }
            const pixels = rigs[0].vram.pixelCount();
            const reference = try alloc.alloc(u16, pixels);
            defer alloc.free(reference);
            const got = try alloc.alloc(u16, pixels);
            defer alloc.free(got);

            for (0..parsed.frames.len) |i| {
                const pool = objc.Pool.push();
                defer pool.pop();
                const stream = parsed.frameStream(i);
                for (rigs) |rig| rig.frame(stream.payload, stream.records);
                rigs[0].vram.readback(reference);
                for (rigs[1..], settings[1..]) |rig, s| {
                    rig.vram.readback(got);
                    try check(std.mem.eql(u16, reference, got), "{s} {t} @{d}x frame {d} ({t}, {t}): VRAM moved", .{ name, dither, scale, i, s[0], s[1] });
                }
            }
        };
    }
    if (processed == 0) {
        std.debug.print("no corpus fixture is present; run `zig build fixtures -Doptimize=ReleaseFast`\n", .{});
        return error.SkipZigTest;
    }
}

// MARK: What it adds

test "bilinearAddsLevelsAcrossAMagnifiedEdge" {
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&edge_row);
    defer alloc.destroy(vram);
    const draw = texturedTriangle(.{ .u0 = 0, .u1 = 2 });
    const near = try shot(m, 1, vram, .true_color, .nearest, null, &draw);
    defer near.deinit(alloc);
    const bil = try shot(m, 1, vram, .true_color, .bilinear, null, &draw);
    defer bil.deinit(alloc);
    try check(sidecarStats(near, 128).distinct() == 2, "the control: nearest has {d} reds, not exactly two", .{sidecarStats(near, 128).distinct()});
    try check(sidecarStats(bil, 128).distinct() > 16, "bilinear has {d} reds across a 64x-magnified edge", .{sidecarStats(bil, 128).distinct()});
    try check(sameVram(near, bil), "VRAM moved", .{});
}

test "bilinearAddsLevelsAtEveryTextureDepth" {
    // Filtered on the CLUT's OUTPUT. A 4bpp/8bpp texel is an index; the four
    // indices 1, 2, 2, 2 map through CLUT entries 1 and 2 at (0, 240) to
    // edge_row's colours (index 0 would be a hole).
    const m = try harness.metal();
    defer m.deinit();
    const vram = try blankVram();
    defer alloc.destroy(vram);
    vram[240 * w + 1] = 0x0001;
    vram[240 * w + 2] = 0x001F;
    for (0..16) |y| {
        vram[y * w + page_x] = 0x2221; // 4bpp: indices 1,2,2,2 in one word
        vram[y * w + 128] = 0x0201; // 8bpp page at x = 128: indices 1,2
        vram[y * w + 129] = 0x0202; //                          2,2
    }
    const clut: u16 = 240 << 6;
    const Depth = struct { label: []const u8, tpage: u16 };
    for ([_]Depth{ .{ .label = "4bpp", .tpage = 0x0004 }, .{ .label = "8bpp", .tpage = 0x0082 } }) |d| {
        const draw = texturedTriangle(.{ .tpage = d.tpage, .clut = clut, .u0 = 0, .u1 = 2 });
        const bil = try shot(m, 1, vram, .true_color, .bilinear, null, &draw);
        defer bil.deinit(alloc);
        try check(sidecarStats(bil, 128).distinct() > 16, "{s}: filtering did not reach the CLUT colours", .{d.label});
    }
}

test "aUniformTextureFiltersToItselfInEveryMode" {
    // T == t5 << 3 everywhere, and every per-mode formula reproduces today's
    // sidecar there bit for bit. Modulated and Gouraud-shaded with dithering
    // ON (GP0(E1) bit 9), so the dithering modes' formula is exercised too.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&[_]u16{ 0x2D6B, 0x2D6B, 0x2D6B, 0x2D6B });
    defer alloc.destroy(vram);
    const draw = [_]Command{env(0xE1, 1 << 9)} ++ texturedTriangle(.{
        .opcode = 0x34,
        .u0 = 0,
        .u1 = 3,
        .v1 = 3,
        .colors = .{ 0x0020_4060, 0x00FF_C080, 0x0010_8040 },
    });
    for (std.enums.values(DitherMode)) |dither| {
        const near = try shot(m, 2, vram, dither, .nearest, null, &draw);
        defer near.deinit(alloc);
        const bil = try shot(m, 2, vram, dither, .bilinear, null, &draw);
        defer bil.deinit(alloc);
        try check(sidecarStats(near, 128).count > 1000, "{t}: the triangle drew nothing", .{dither});
        try check(sameSidecar(near, bil), "{t}: a uniform texture filtered to something else", .{dither});
        try check(sameVram(near, bil), "{t}: VRAM moved", .{dither});
    }
}

test "perspectiveTexcoordsFilterToo" {
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&edge_row);
    defer alloc.destroy(vram);
    const draw = texturedTriangle(.{ .u0 = 0, .u1 = 2, .flags = command.flag_texture_perspective, .rw = .{ 65536, 16384, 65536 } });
    const near = try shot(m, 1, vram, .true_color, .nearest, null, &draw);
    defer near.deinit(alloc);
    const bil = try shot(m, 1, vram, .true_color, .bilinear, null, &draw);
    defer bil.deinit(alloc);
    try check(sidecarStats(bil, 128).distinct() > 16, "bilinear has {d} reds on the perspective path", .{sidecarStats(bil, 128).distinct()});
    try check(sameVram(near, bil), "VRAM moved on the perspective path", .{});
}

test "aOneToOneMappingFiltersToTheNearestTexelAtOneX" {
    // One texel per pixel at 1x: every pixel CENTRE lands on a texel centre,
    // so the filter must give back exactly the nearest texel. Sampled at the
    // pixel's corner instead, every pixel averages a 2x2 block half a texel
    // up and to the left. Every texel differs from its neighbours on both
    // axes, so any blur shows.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try blankVram();
    defer alloc.destroy(vram);
    for (0..20) |y| for (0..20) |u| {
        vram[y * w + page_x + u] = @intCast((u * 5 + y * 3) % 31 + 1);
    };
    const Case = struct { label: []const u8, draw: [2]Command };
    const cases = [_]Case{
        .{ .label = "affine", .draw = texturedTriangle(.{ .u0 = 0, .u1 = 16, .v0 = 0, .v1 = 16, .size = 16 }) },
        .{ .label = "perspective", .draw = texturedTriangle(.{ .u0 = 0, .u1 = 16, .v0 = 0, .v1 = 16, .size = 16, .flags = command.flag_texture_perspective, .rw = .{ 4096, 4096, 4096 } }) },
    };
    for (cases) |c| {
        const near = try shot(m, 1, vram, .true_color, .nearest, null, &c.draw);
        defer near.deinit(alloc);
        const bil = try shot(m, 1, vram, .true_color, .bilinear, null, &c.draw);
        defer bil.deinit(alloc);
        try check(sidecarStats(near, 16).count > 100, "{s}: the triangle drew nothing", .{c.label});
        try check(sameSidecar(near, bil), "{s}: a 1:1 mapping was blurred", .{c.label});
        try check(sameVram(near, bil), "{s}: VRAM moved", .{c.label});
    }
}

// MARK: What it must not smear in

test "aHoleNeighbourDrawsNoFringe" {
    // texel 1 a HOLE between two bright ones, mapped u 0..2 so the hole lies
    // INSIDE the UV limits and only its zero weight keeps it out. Filtering it
    // as black darkens every pixel beside a cut-out.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&[_]u16{ 0x001F, 0x0000, 0x001F });
    defer alloc.destroy(vram);
    const draw = texturedTriangle(.{ .u0 = 0, .u1 = 2 });
    const bil = try shot(m, 1, vram, .true_color, .bilinear, null, &draw);
    defer bil.deinit(alloc);
    const s = sidecarStats(bil, 128);
    try check(s.count > 1000, "the triangle drew nothing", .{});
    try check(s.min_r == 255, "a hole was filtered in: min red {d}", .{s.min_r});
}

test "uvLimitsKeepAtlasNeighboursOut" {
    // An atlas cell mapped u/v 4..8, all blue, with RED in the column and row
    // on BOTH sides of it. A centred sample at U < 4.5 reaches u = 3 unless
    // clamped, and one past U = 7.5 reaches u = 8: the PS1 never draws a
    // primitive's right/bottom texel, so the high limit is max - 1. Magnified
    // at 1x and mapped 1:1 at 4x and 8x, where the last native pixel's
    // subtexel centres lie past 7.5.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try blankVram();
    defer alloc.destroy(vram);
    for (0..12) |y| for (0..12) |u| {
        const edge = u == 3 or y == 3 or u == 8 or y == 8;
        vram[y * w + page_x + u] = if (edge) 0x001F else 0x7C00;
    };
    const Case = struct { size: i16, scale: u32 };
    for ([_]Case{ .{ .size = 128, .scale = 1 }, .{ .size = 4, .scale = 4 }, .{ .size = 4, .scale = 8 } }) |c| {
        const draw = texturedTriangle(.{ .u0 = 4, .u1 = 8, .v0 = 4, .v1 = 8, .size = c.size });
        const bil = try shot(m, c.scale, vram, .true_color, .bilinear, null, &draw);
        defer bil.deinit(alloc);
        const s = sidecarStats(bil, @intCast(c.size));
        try check(s.count > 50, "@{d}x: the triangle drew nothing", .{c.scale});
        try check(s.max_r == 0, "@{d}x: an atlas neighbour bled in: max red {d}", .{ c.scale, s.max_r });
    }
}

test "filteredNeighboursWrapInsideTheTextureWindow" {
    // GP0(E2) mask field 0x1F clears bits 3-7 of u and v, offset 0: every
    // coordinate wraps into 0..7. Inside that window texels are blue;
    // u = 8.. and v = 8.. are red and must never be reached.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try windowVram();
    defer alloc.destroy(vram);
    const draw = [_]Command{env(0xE2, 0x1F | (0x1F << 5))} ++ texturedTriangle(.{ .u0 = 0, .u1 = 20, .v0 = 0, .v1 = 20 });
    const bil = try shot(m, 1, vram, .true_color, .bilinear, null, &draw);
    defer bil.deinit(alloc);
    const s = sidecarStats(bil, 128);
    try check(s.count > 1000, "the triangle drew nothing", .{});
    try check(s.max_r == 0, "a texel outside the window bled in", .{});
}

// MARK: Dithering modes and blending

test "theDitheringModesStayFiveBitUnderBilinear" {
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&edge_row);
    defer alloc.destroy(vram);
    const draw = texturedTriangle(.{ .u0 = 0, .u1 = 2 });
    for ([_]DitherMode{ .off, .native, .scaled }) |dither| {
        const near = try shot(m, 2, vram, dither, .nearest, null, &draw);
        defer near.deinit(alloc);
        const bil = try shot(m, 2, vram, dither, .bilinear, null, &draw);
        defer bil.deinit(alloc);
        const s = sidecarStats(bil, 128);
        // `expand` of a five-bit value: the byte is (c << 3) | (c >> 2).
        try check(s.five_bit, "{t}: an eight-bit value reached a five-bit mode's sidecar", .{dither});
        try check(s.distinct() > sidecarStats(near, 128).distinct(), "{t}: filtering changed nothing", .{dither});
    }
}

test "aSemiTransparentFilteredDrawBlendsTheFilteredColourInDitheringModes" {
    // Review Focus 1. Raw + semi-transparent (opcode 0x27), STP-set texels,
    // mode 1 (add) over a dark red fill. Before the fix `out8` came from the
    // NEAREST blend in the dithering modes and showed exactly two reds.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&[_]u16{ 0x8001, 0x801F, 0x801F, 0x801F });
    defer alloc.destroy(vram);
    const draw = overDarkRed(160, texturedTriangle(.{ .opcode = 0x27, .tpage = page16 | (1 << 5), .u0 = 0, .u1 = 2, .transparent = 1 }));
    for ([_]DitherMode{ .off, .true_color }) |dither| {
        const bil = try shot(m, 2, vram, dither, .bilinear, null, &draw);
        defer bil.deinit(alloc);
        const n = sidecarStats(bil, 128).distinct();
        try check(n > 8, "{t}: the blend shows {d} reds; it used the nearest texel", .{ dither, n });
    }
}

test "texturedRectanglesFollowTheSpriteSetting" {
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&edge_row);
    defer alloc.destroy(vram);
    const draw = texturedRectangle(.{});
    const near = try shot(m, 4, vram, .true_color, .nearest, null, &draw);
    defer near.deinit(alloc);
    const texture_only = try shot(m, 4, vram, .true_color, .bilinear, .nearest, &draw);
    defer texture_only.deinit(alloc);
    const sprite_on = try shot(m, 4, vram, .true_color, .nearest, .bilinear, &draw);
    defer sprite_on.deinit(alloc);
    try check(sidecarStats(near, 4).count > 100, "the sprite drew nothing", .{});
    try check(sameSidecar(near, texture_only), "Texture Filtering reached a rectangle", .{});
    try check(sidecarStats(sprite_on, 4).distinct() > 2, "Sprite Texture Filtering did not reach a rectangle", .{});
    try check(sameVram(near, sprite_on), "VRAM moved", .{});
}

// MARK: Which setting applies

/// Distinct reds with only Texture Filtering on, then only Sprite Texture
/// Filtering: which of the two settings `draw` follows.
fn followed(m: Metal, draw: []const Command) ![2]usize {
    const vram = try vramWithRows(&edge_row);
    defer alloc.destroy(vram);
    return .{
        try distinctReds(m, draw, vram, .bilinear, .nearest),
        try distinctReds(m, draw, vram, .nearest, .bilinear),
    };
}

test "aScreenAlignedTriangleFollowsTheSpriteSetting" {
    // `texturedTriangle` maps u along x and v along y: a 2D quad's half.
    const m = try harness.metal();
    defer m.deinit();
    const n = try followed(m, &texturedTriangle(.{ .u0 = 0, .u1 = 2 }));
    try check(n[0] == 2, "Texture Filtering alone filtered a sprite: {d} reds", .{n[0]});
    try check(n[1] > 16, "Sprite Texture Filtering did not reach a sprite: {d} reds", .{n[1]});
}

test "aTextureTurnedOnItsSideFollowsTheTextureSetting" {
    // u runs DOWN the screen and v across it: du/dy != 0, so not a sprite.
    const m = try harness.metal();
    defer m.deinit();
    const n = try followed(m, &mappedTriangle(.{ .{ 300, 300 }, .{ 428, 300 }, .{ 300, 428 } }, .{ .{ 0, 0 }, .{ 0, 2 }, .{ 2, 0 } }, .{ 0, 0, 0 }));
    try check(n[0] > 16, "Texture Filtering did not reach a 3D mapping: {d} reds", .{n[0]});
    try check(n[1] == 2, "Sprite Texture Filtering filtered a 3D mapping: {d} reds", .{n[1]});
}

test "aTriangleWithDepthFollowsTheTextureSettingEvenWhenScreenAligned" {
    // Review Focus 1. Screen-aligned, but PGXP gave all three vertices a
    // depth: DuckStation's "is_3d" wins over the derivative test. No
    // perspective flag, so the texcoords stay affine and only the class moves.
    const m = try harness.metal();
    defer m.deinit();
    const n = try followed(m, &texturedTriangle(.{ .u0 = 0, .u1 = 2, .rw = .{ 65536, 65536, 65536 } }));
    try check(n[0] > 16, "a depth-carrying triangle ignored Texture Filtering: {d} reds", .{n[0]});
    try check(n[1] == 2, "a depth-carrying triangle was treated as a sprite: {d} reds", .{n[1]});
}

test "aMirroredScreenAlignedTriangleIsStillASprite" {
    // Review Focus 2. u runs right-to-left (du/dx < 0), as a sprite drawn
    // facing the other way: still du/dy == 0 and dv/dx == 0.
    const m = try harness.metal();
    defer m.deinit();
    const n = try followed(m, &mappedTriangle(.{ .{ 300, 300 }, .{ 428, 300 }, .{ 300, 428 } }, .{ .{ 2, 0 }, .{ 0, 0 }, .{ 2, 2 } }, .{ 0, 0, 0 }));
    try check(n[0] == 2, "a mirrored 2D triangle followed Texture Filtering: {d} reds", .{n[0]});
    try check(n[1] > 16, "a mirrored 2D triangle ignored Sprite Texture Filtering: {d} reds", .{n[1]});
}

// MARK: Sprites

test "aRectangleAtOneXFiltersToItself" {
    // One texel per native pixel: at 1x every subtexel centre IS a texel
    // centre, so Bilinear reproduces Nearest exactly.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&edge_row);
    defer alloc.destroy(vram);
    const draw = texturedRectangle(.{});
    const near = try shot(m, 1, vram, .true_color, .nearest, null, &draw);
    defer near.deinit(alloc);
    const bil = try shot(m, 1, vram, .true_color, .nearest, .bilinear, &draw);
    defer bil.deinit(alloc);
    try check(sidecarStats(near, 4).count == 16, "the sprite drew {d} present pixels, not 16", .{sidecarStats(near, 4).count});
    try check(sameSidecar(near, bil), "a 1:1 sprite was blurred at 1x", .{});
}

test "aUniformSpriteFiltersToItselfInEveryMode" {
    // Modulated (opcode 0x64) by a five-bit colour, as every sprite is.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&[_]u16{ 0x2D6B, 0x2D6B, 0x2D6B, 0x2D6B });
    defer alloc.destroy(vram);
    const draw = texturedRectangle(.{ .opcode = 0x64, .color = 0x0000_4210 });
    for (std.enums.values(DitherMode)) |dither| {
        const near = try shot(m, 4, vram, dither, .nearest, null, &draw);
        defer near.deinit(alloc);
        const bil = try shot(m, 4, vram, dither, .nearest, .bilinear, &draw);
        defer bil.deinit(alloc);
        try check(sidecarStats(near, 4).count > 100, "{t}: the sprite drew nothing", .{dither});
        try check(sameSidecar(near, bil), "{t}: a uniform sprite filtered to something else", .{dither});
    }
}

test "aRectangleNeverFiltersPastItsWrapSegment" {
    // Review Focus 3. u0 = 250, 12 wide: unwrapped texels 250..261, i.e.
    // segment 0 (250..255) then segment 1 (0..5) after the wrap. Segment 0 is
    // BLUE and segment 1 GREEN, so a sample that crosses the seam (255 with 0,
    // which only an unsegmented limit allows) mixes the two. RED sits at 249
    // (below the first segment), at 6 (past the last column), in row 4 (past
    // the last row of a 4-tall sprite) and on the ADJACENT page (256..263),
    // which an unwrapped read would reach.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try blankVram();
    defer alloc.destroy(vram);
    for (0..8) |y| {
        for (0..256) |u| {
            var texel: u16 = 0x001F;
            if (y < 4) {
                if (u >= 250) texel = 0x7C00 else if (u <= 5) texel = 0x03E0;
            }
            vram[y * w + page_x + u] = texel;
        }
        for (256..264) |u| vram[y * w + page_x + u] = 0x001F;
    }
    const draw = texturedRectangle(.{ .u0 = 250, .w = 12 });
    for ([_]u32{ 4, 8 }) |scale| {
        const bil = try shot(m, scale, vram, .true_color, .nearest, .bilinear, &draw);
        defer bil.deinit(alloc);
        const s = sidecarStats(bil, 12);
        try check(s.count > 100, "@{d}x: the sprite drew nothing", .{scale});
        try check(s.max_r == 0, "@{d}x: a texel outside the sprite bled in", .{scale});
        try check(!s.mixed_gb, "@{d}x: a sample crossed the wrap seam", .{scale});
    }
}

test "aSpriteHoleDrawsNoFringe" {
    // texel 1 is a HOLE between two bright texels; at 4x every filtered
    // subtexel beside it must stay at full red.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&[_]u16{ 0x001F, 0x0000, 0x001F, 0x001F });
    defer alloc.destroy(vram);
    const draw = texturedRectangle(.{});
    const bil = try shot(m, 4, vram, .true_color, .nearest, .bilinear, &draw);
    defer bil.deinit(alloc);
    const s = sidecarStats(bil, 4);
    try check(s.count > 100, "the sprite drew nothing", .{});
    try check(s.min_r == 255, "a hole was filtered in: min red {d}", .{s.min_r});
}

test "aSemiTransparentFilteredSpriteBlendsTheFilteredColour" {
    // Review Focus 4. Raw, semi-transparent (opcode 0x67), STP-set texels,
    // mode 1 (add) over a dark red fill, in a dithering mode.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try vramWithRows(&[_]u16{ 0x8001, 0x801F, 0x801F, 0x801F });
    defer alloc.destroy(vram);
    const draw = overDarkRed(32, texturedRectangle(.{ .opcode = 0x67, .tpage = page16 | (1 << 5), .transparent = 1 }));
    for ([_]DitherMode{ .off, .true_color }) |dither| {
        const bil = try shot(m, 4, vram, dither, .nearest, .bilinear, &draw);
        defer bil.deinit(alloc);
        try check(sidecarStats(bil, 4).distinct() > 2, "{t}: the blend used the nearest texel", .{dither});
    }
}

test "aWindowedSpriteFiltersInsideItsWindow" {
    // Review Focus 5. GP0(E2) mask 0x1F on both axes: every coordinate wraps
    // into 0..7. Blue inside that window, red outside it, and a 20 x 20
    // sprite tiles the window more than twice.
    const m = try harness.metal();
    defer m.deinit();
    const vram = try windowVram();
    defer alloc.destroy(vram);
    const draw = [_]Command{env(0xE2, 0x1F | (0x1F << 5))} ++ texturedRectangle(.{ .w = 20, .h = 20 });
    const bil = try shot(m, 4, vram, .true_color, .nearest, .bilinear, &draw);
    defer bil.deinit(alloc);
    const s = sidecarStats(bil, 20);
    try check(s.count > 1000, "the sprite drew nothing", .{});
    try check(s.max_r == 0, "a texel outside the window bled in", .{});
}
