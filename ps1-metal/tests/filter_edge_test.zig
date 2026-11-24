//! What every filter shares at a cut-out's edge: how much of the filtered
//! colour a pixel shows (`ps1_filter_cover`), and a hole the filter still
//! covers, which paints the sidecar and leaves VRAM and depth as they were.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");
const fh = @import("filter_harness.zig");

const pi = ps1_metal.prim_instance;
const command = ps1_core.gpu.command;
const Command = command.Command;
const TextureFilter = pi.TextureFilter;

const alloc = std.testing.allocator;
const check = harness.check;
const vtx = harness.vtx;
const fullDrawingArea = harness.fullDrawingArea;

const red: u16 = 0x001F;
const green: u16 = 0x03E0;
const blue: u16 = 0x7C00;

/// A hole between two red texels, magnified to 128 / 3 px a texel so that
/// some pixel's corner lands in the hole while its centre lands past it,
/// over a green fill. Opaque, unmasked and untested: the draw the encoder
/// would otherwise give the variant that reads no destination.
fn holeScene(tri: Command) [3]Command {
    return .{
        fullDrawingArea(),
        .{ .kind = .fill_rect, .value = green, .x = 288, .y = 288, .w = 160, .h = 160 },
        tri,
    };
}

fn holeTriangle() Command {
    return fh.texturedTriangle(.{ .u0 = 0, .u1 = 3 })[1];
}

const Pixel = struct { vram: u16, rgb: [3]u8, present: bool };

fn pixelAt(f: harness.Frame, x: usize, y: usize) Pixel {
    const i = y * f.width + x;
    const side = f.sidecar.?[i * 4 ..][0..4];
    return .{ .vram = f.scaled[i], .rgb = side[0..3].*, .present = side[3] == 255 };
}

/// Every subtexel of the triangle's box.
fn eachInBox(f: harness.Frame, ctx: anytype, comptime body: fn (@TypeOf(ctx), usize, usize, Pixel) anyerror!void) !void {
    const k = f.scale;
    for (300 * k..428 * k) |y| for (300 * k..428 * k) |x| try body(ctx, x, y, pixelAt(f, x, y));
}

test "aCoveredHoleKeepsItsVramAndDepth" {
    const m = try harness.metal();
    defer m.deinit();
    const vram = try fh.vramWithRows(&[_]u16{ red, 0, red });
    defer alloc.destroy(vram);

    var tested = holeTriangle();
    tested.flags = command.flag_depth_test | command.flag_depth_write;
    for (&tested.v) |*v| v.iz = 1000;
    var far_blue: Command = .{
        .kind = .draw_triangle,
        .value = blue,
        .flags = command.flag_depth_test,
        .v = .{ vtx(300, 300, 0, 0, 0), vtx(428, 300, 0, 0, 0), vtx(300, 428, 0, 0, 0) },
    };
    for (&far_blue.v) |*v| v.iz = 500;

    for ([_]TextureFilter{ .bilinear, .bilinear_no_edge }) |filter| for ([_]u32{ 1, 4 }) |scale| {
        const plain = try fh.shot(m, scale, vram, .true_color, filter, filter, &holeScene(holeTriangle()));
        defer plain.deinit(alloc);

        // A near draw of the same triangle, then a far one over it: blue
        // lands exactly where the textured draw left the depth alone.
        const rig = try harness.Rig.create(alloc, m, .{ .scale = scale, .depth_buffer = true });
        defer rig.destroy();
        rig.vram.uploadNative(vram);
        rig.r.texture_filter = filter;
        rig.r.sprite_filter = filter;
        rig.frame(&.{}, &(holeScene(tested) ++ [_]Command{far_blue}));
        const after = try rig.readback(alloc);
        defer alloc.free(after);

        const Count = struct {
            filter: TextureFilter,
            scale: u32,
            after: []const u16,
            width: usize,
            painted: usize = 0,
            fn visit(c: *@This(), x: usize, y: usize, p: Pixel) !void {
                try check(p.vram == green or p.vram == red, "{t} @{d}x ({d}, {d}): VRAM {x:0>4} is neither the fill nor the texel", .{ c.filter, c.scale, x, y, p.vram });
                if (p.vram != green or !p.present or p.rgb[0] == 0) return;
                c.painted += 1;
                try check(c.after[y * c.width + x] == blue, "{t} @{d}x ({d}, {d}): a covered hole wrote depth", .{ c.filter, c.scale, x, y });
            }
        };
        var count: Count = .{ .filter = filter, .scale = scale, .after = after, .width = plain.width };
        try eachInBox(plain, &count, Count.visit);
        try check(count.painted > 0, "{t} @{d}x: no hole was covered", .{ filter, scale });
    };
}

test "edgeBlendingMixesTheBackgroundInAndNoEdgeNeverDoes" {
    const m = try harness.metal();
    defer m.deinit();
    const vram = try fh.vramWithRows(&[_]u16{ red, 0, red });
    defer alloc.destroy(vram);

    const Mixed = struct {
        mixed: usize = 0,
        fn visit(c: *@This(), _: usize, _: usize, p: Pixel) !void {
            if (p.present and p.rgb[0] != 0 and p.rgb[1] != 0) c.mixed += 1;
        }
    };
    for ([_]TextureFilter{ .nearest, .bilinear, .bilinear_no_edge }) |filter| {
        const f = try fh.shot(m, 4, vram, .true_color, filter, filter, &holeScene(holeTriangle()));
        defer f.deinit(alloc);
        var c: Mixed = .{};
        try eachInBox(f, &c, Mixed.visit);
        if (filter == .bilinear) {
            try check(c.mixed > 0, "{t}: no edge blended into the fill", .{filter});
        } else {
            try check(c.mixed == 0, "{t}: {d} subtexels mix the fill into the texel", .{ filter, c.mixed });
        }
    }
}
