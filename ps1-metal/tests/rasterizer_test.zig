//! The rasterizer against the software one: the `synthetic-primitives` gate
//! ladder, the PeterLemon ROMs, and the hand-built cases no fixture can pin.
//! Ported from MetalRasterizerTests.swift.
//!
//! `synthetic-primitives` puts one feature group per frame; each rung replays
//! a longer prefix. VRAM is CUMULATIVE, so bounding the replay is what keeps a
//! later frame's mismatch from masking an earlier feature that already works.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const pi = ps1_metal.prim_instance;
const prim_builder = ps1_metal.prim_builder;
const command = ps1_core.gpu.command;
const Command = command.Command;
const Vertex = command.Vertex;
const DrawingEnv = ps1_core.gpu.Regs.DrawingEnv;

const alloc = std.testing.allocator;
const native_width = pi.native_width;
const native_pixels = pi.native_pixels;

/// A vertex with no sub-pixel, which is what GP0 decode produces whenever
/// PGXP has nothing to say about it: `px == x << 16`, `py == y << 16`.
fn vtx(x: i16, y: i16, u: u8, v: u8, color: u32) Vertex {
    return .{ .x = x, .y = y, .u = u, .v = v, .color = color, .px = @as(i32, x) << 16, .py = @as(i32, y) << 16 };
}

fn env(opcode: u8, value: u32) Command {
    return .{ .kind = .set_draw_env, .opcode = opcode, .value = value };
}

/// GP0(E4) = (1023, 511): with E3's default of (0, 0), the whole of VRAM.
fn fullDrawingArea() Command {
    return env(0xE4, (511 << 10) | 1023);
}

/// A flat triangle whose three vertices sit at `xs` on rows 10/50/90 with the
/// given absolute depths, carrying both depth bits.
fn depthTestedTriangle(color: u32, xs: [3]i16, izs: [3]i32) Command {
    var c: Command = .{ .kind = .draw_triangle, .value = color, .flags = command.flag_depth_test | command.flag_depth_write };
    const ys = [3]i16{ 10, 50, 90 };
    for (0..3) |i| {
        c.v[i] = vtx(xs[i], ys[i], 0, 0, 0);
        c.v[i].iz = izs[i];
    }
    return c;
}

fn expectReplay(name: []const u8, o: harness.ReplayOptions, frames: ?usize) !void {
    const m = try harness.metal();
    defer m.deinit();
    const r = try harness.replay(alloc, m, name, o);
    defer r.deinit(alloc);
    if (r.first_divergence != null) std.debug.print("{s}\n", .{r.message});
    try std.testing.expectEqual(null, r.first_divergence);
    if (frames) |n| try std.testing.expectEqual(n, r.frames_checked);
}

/// A blank 1x VRAM (or a depth-persisting one) with records drawn into it,
/// read back. Owned by the caller.
fn drawn(m: harness.Metal, o: harness.Rig.Options, records: []const Command) ![]u16 {
    const rig = try harness.Rig.create(alloc, m, o);
    defer rig.destroy();
    rig.frame(&.{}, records);
    return rig.readback(alloc);
}

/// A blank native image with `pixels` set, for an upload before drawing.
fn imageWith(comptime n: usize, at: [n]usize, values: [n]u16) ![]u16 {
    const p = try alloc.alloc(u16, native_pixels);
    @memset(p, 0);
    for (at, values) |i, v| p[i] = v;
    return p;
}

test "flatTrianglesMatchTheSoftwareRasterizer" {
    try expectReplay("synthetic-primitives", .{ .up_to = 1 }, null);
}

// The one assumption underneath every blend in the corpus. Metal orders
// framebuffer reads by primitive submission order, instances included; a
// raster order group orders accesses to DEVICE memory, which this backend
// never does. If this ever fails, add [[raster_order_group(0)]] to the
// [[color(0)]] input: do NOT reorder the encoder to work around it.
test "overlappingInstancesBlendInSubmissionOrder" {
    const m = try harness.metal();
    defer m.deinit();
    const tri = struct {
        fn f(transparent: bool, colour: u32) Command {
            return .{
                .kind = .draw_triangle,
                .transparent = @intFromBool(transparent),
                .value = colour,
                .v = .{ vtx(0, 0, 0, 0, 0), vtx(40, 0, 0, 0, 0), vtx(0, 40, 0, 0, 0) },
            };
        }
    }.f;
    // Blend mode 1 is B + F. Three identical opaque-then-additive triangles
    // over the same pixel must land at 3x, not 1x, and not in another order.
    const back = try drawn(m, .{}, &.{
        fullDrawingArea(),
        env(0xE1, 1 << 5),
        tri(false, 0x0005), // opaque red = 5
        tri(true, 0x0005), // +5
        tri(true, 0x0005), // +5
    });
    defer alloc.free(back);
    try std.testing.expectEqual(@as(u16, 0x000F), back[5 * 1024 + 5]);
}

test "gouraudTrianglesAndDitherMatchTheSoftwareRasterizer" {
    try expectReplay("synthetic-primitives", .{ .up_to = 2 }, null);
}

test "texturedTrianglesMatchTheSoftwareRasterizer" {
    try expectReplay("synthetic-primitives", .{ .up_to = 3 }, null);
}

test "rectanglesAndSpritesMatchTheSoftwareRasterizer" {
    try expectReplay("synthetic-primitives", .{ .up_to = 5 }, null);
}

test "linesMatchTheSoftwareRasterizer" {
    try expectReplay("synthetic-primitives", .{ .up_to = 6 }, null);
}

// 60 mono lines and 20 shaded ones.
test "replaysThePeterLemonLineRom" {
    try expectReplay("pl-render-line", .{}, 17);
}

test "replaysThePeterLemonRectangleRom" {
    try expectReplay("pl-render-rectangle", .{}, 17);
}

// `tu +% @truncate(xx)` on u8: a WRAP. The triangle path interpolates and
// clamps instead, so this is a genuinely separate shader path.
test "aSpriteWrapsItsTexcoordsInEightBits" {
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();

    // A 16bpp texture page at (256, 0) whose row 0 is a ramp: texel at u is
    // 0x0100 + u, so a wrapped read is visibly different from a clamped one.
    const pixels = try alloc.alloc(u16, native_pixels);
    defer alloc.free(pixels);
    @memset(pixels, 0);
    for (0..256) |u| pixels[256 + u] = @intCast(0x0100 + u);
    rig.vram.upload(pixels);

    var spr: Command = .{
        .kind = .draw_textured_rectangle,
        .opcode = 0x65, // RAW: no modulation
        .tpage = 0x0104, // page x 4 (-> 256), 16bpp
        .x = 0,
        .y = 300,
        .w = 8,
        .h = 1,
    };
    spr.v[0] = vtx(0, 0, 252, 0, 0);
    rig.frame(&.{}, &.{ fullDrawingArea(), spr });

    const back = try rig.readback(alloc);
    defer alloc.free(back);
    const row = 300 * 1024;
    try std.testing.expectEqual(@as(u16, 0x01FC), back[row + 0]); // u = 252
    try std.testing.expectEqual(@as(u16, 0x01FF), back[row + 3]); // u = 255
    try std.testing.expectEqual(@as(u16, 0x0100), back[row + 4]); // wrapped to 0: a clamp would repeat 0x01FF
    try std.testing.expectEqual(@as(u16, 0x0103), back[row + 7]);
}

// 48 textured triangles, 34 latch_texpage records and four uploads, all in
// frame 0, and the uploads are in the SAME frame as the draws that sample
// them, which is what makes the read-after-write half of the hazard rule
// load-bearing here: an upload is a write like any other.
test "replaysThePeterLemonTexturePolygonRom" {
    try expectReplay("pl-render-texture-polygon", .{}, 17);
}

// The offsets are added at 8-BIT scale and clamped to [0,255] BEFORE the >> 3
// down to 5 bits. Reading them as 5-bit units is the bug 900daa0 fixed, and
// it survives every hash in the A2 corpus because no PL ROM dithers. Channel
// 0x80 with dither cell (0,0) = -4 gives 0x7C >> 3 = 15; at 5-bit scale it
// would give (0x80>>3) - 4 = 12.
test "theDitherOffsetIsAnEightBitChannelUnit" {
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();
    // Pinned rather than inherited: this test is about the 4x4 offset table,
    // which only fires in a dithering mode, and the shipped default
    // (`.true_color`) turns dithering off entirely.
    rig.r.dither_mode = .native;

    // A flat-coloured Gouraud triangle: all three vertices 0x808080, so the
    // interpolation is exact everywhere and only the dither varies.
    const tri: Command = .{
        .kind = .draw_shaded_triangle,
        .v = .{ vtx(0, 0, 0, 0, 0x0080_8080), vtx(60, 0, 0, 0, 0x0080_8080), vtx(0, 60, 0, 0, 0x0080_8080) },
    };
    rig.frame(&.{}, &.{ fullDrawingArea(), env(0xE1, 1 << 9), tri });

    const back = try rig.readback(alloc);
    defer alloc.free(back);
    try std.testing.expectEqual(@as(u16, 15 | (15 << 5) | (15 << 10)), back[0]); // cell (0,0) = -4
    try std.testing.expectEqual(@as(u16, 16 | (16 << 5) | (16 << 10)), back[1]); // cell (1,0) =  0
}

// `TexturedShader.shade` decides the texel HOLE on the RAW texel and only
// then modulates, so a dark-but-non-zero texel scaled down to 0x0000 is drawn
// BLACK. A sampler that returned the modulated colour through the same `0` it
// uses for the hole let whatever lay behind show through: the green speckle
// over Croc's dark rock, door and crate. Nothing in the fixture corpus
// modulates a texel to zero, which is why every hash in it agreed.
test "aTexelThatModulatesToBlackIsDrawnRatherThanDiscarded" {
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();

    const row = 300 * 1024;
    // A 16bpp page at (256, 0). u = 0 is the darkest non-zero texel; u = 1 is
    // a control bright enough to survive the same modulation. The
    // destination stands in for the background the artifact showed through.
    const pixels = try imageWith(4, .{ 256, 257, row, row + 1 }, .{ 1 | (1 << 5) | (1 << 10), 4 | (4 << 5) | (4 << 10), 0x03E0, 0x03E0 });
    defer alloc.free(pixels);
    rig.vram.upload(pixels);

    const spr: Command = .{
        .kind = .draw_textured_rectangle,
        .opcode = 0x64, // modulated, not RAW
        .tpage = 0x0104, // page x 4 (-> 256), 16bpp
        .value = 15 | (15 << 5) | (15 << 10), // the modulating colour
        .x = 0,
        .y = 300,
        .w = 2,
        .h = 1,
    };
    rig.frame(&.{}, &.{ fullDrawingArea(), spr });

    const back = try rig.readback(alloc);
    defer alloc.free(back);
    // (1 * 15) >> 1 == 7, and 7 >> 3 == 0 on every channel: black, but DRAWN.
    try std.testing.expectEqual(@as(u16, 0), back[row + 0]);
    // (4 * 15) >> 1 == 30, and 30 >> 3 == 3: the control still lands.
    try std.testing.expectEqual(@as(u16, 3 | (3 << 5) | (3 << 10)), back[row + 1]);
}

// Frame 6 samples a page this very frame drew into. Without pass splitting
// the read is stale and VRAM moves. Frame 7 is the Gouraud-shaded textured
// ladder: its modulation colour is interpolated across the primitive, and a
// shader that reads one vertex's colour diverges here and nowhere else.
//
// Bounded at 8, not the fixture's full length: frame 8 is the depth rung,
// which needs a persistent depth attachment to replay correctly (a pass break
// wipes a memoryless one), and it has its own gate below.
test "theFeedbackFrameMatchesTheSoftwareRasterizer" {
    try expectReplay("synthetic-primitives", .{ .up_to = 8 }, 8);
}

// Frame 8, the depth rung: interpenetrating opaque triangles drawn in the
// "wrong" order, a transparent one under transparent_depth, a fill across
// part of it, and a clear_depth. The only frame in the ladder that can gate
// the depth test.
test "frameEightMatchesTheSoftwareRasterizerWithDepth" {
    try expectReplay("synthetic-primitives", .{ .up_to = 9, .depth_buffer = true }, 9);
}

// A hand-built triangle with one vertex nudged half a pixel must cover a
// different pixel set than the same triangle with integer vertices. The
// corpus cannot pin this: almost every fixture was captured with PGXP off,
// so every `px` in it is exactly `x << 16`.
test "aSubPixelVertexMovesCoverage" {
    const m = try harness.metal();
    defer m.deinit();
    const integer: Command = .{
        .kind = .draw_triangle,
        .value = 0x7FFF,
        .v = .{ vtx(4, 4, 0, 0, 0), vtx(20, 4, 0, 0, 0), vtx(4, 20, 0, 0, 0) },
    };
    var nudged = integer;
    nudged.v[0].px = (4 << 16) | 0x8000;
    nudged.v[0].py = (4 << 16) | 0x8000;

    const a = try drawn(m, .{}, &.{ fullDrawingArea(), integer });
    defer alloc.free(a);
    const b = try drawn(m, .{}, &.{ fullDrawingArea(), nudged });
    defer alloc.free(b);
    try std.testing.expect(!std.mem.eql(u16, a, b));
}

// MARK: The phase gate
//
// Byte-identical full 1024x512 VRAM on every frame of every generated
// fixture: strictly stronger than test-roms-pl, which compares a 320x224
// display window reduced to 5-bit against a per-test floor. The pass count
// and frame count are printed on success too: they are the measurement of
// what pass splitting costs.
test "everyFixtureIsByteIdenticalOnEveryFrame" {
    const m = try harness.metal();
    defer m.deinit();
    const names = [_][]const u8{
        "pl-hello-world",            "pl-cpu-add",          "pl-render-polygon",
        "pl-render-line",            "pl-render-rectangle", "pl-render-texture-polygon",
        "croc-legend-of-the-gobbos", "silent-hill-usa",     "tr1-usa-v1-1",
    };
    var checked: usize = 0;
    for (names) |name| {
        const r = harness.replay(alloc, m, name, .{}) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer r.deinit(alloc);
        checked += 1;
        if (r.first_divergence != null) std.debug.print("{s}\n", .{r.message});
        try std.testing.expectEqual(null, r.first_divergence);
        std.debug.print("[phase-b] {s}: {d} frames, {d} passes\n", .{ name, r.frames_checked, r.pass_count });
    }
    if (checked == 0) {
        std.debug.print("generated fixtures are absent; run `zig build fixtures -Doptimize=ReleaseFast`\n", .{});
        return error.SkipZigTest;
    }
}

// The persistent-buffer race, pinned.
//
// The payload and instance buffers are reused frame to frame, and on the
// live path `endFrame` does not wait for the GPU. Commit order orders GPU
// work against GPU work; it says nothing about the CPU overwriting a buffer
// a committed-but-unfinished command buffer is still reading. Cycling the
// buffers is what lets the CPU write frame n+1 while the GPU still reads
// frame n. A race here is nondeterministic, so this replays enough frames
// with large payloads to make one likely, and requires the asynchronous
// result to equal the synchronous one exactly.
test "asynchronousFramesDoNotOverwriteBuffersTheGpuIsStillReading" {
    const m = try harness.metal();
    defer m.deinit();

    const reference = try runUploads(m, true);
    defer alloc.free(reference);
    var painted = false;
    for (reference) |p| painted = painted or p != 0;
    try std.testing.expect(painted); // the replay painted nothing otherwise
    // Repeated: one asynchronous pass that happens to win the race proves
    // nothing, and the failure this guards is intermittent by nature.
    for (0..8) |attempt| {
        const got = try runUploads(m, false);
        defer alloc.free(got);
        if (!std.mem.eql(u16, got, reference)) {
            std.debug.print("attempt {d}\n", .{attempt});
            return error.TestExpectedEqual;
        }
    }
}

/// A CPU->VRAM upload per frame: the one record kind that reads the payload
/// buffer from the fragment shader, which is the buffer the race is about.
/// Each frame writes a different value at a different row, so a frame
/// reading a neighbour's payload lands a wrong colour.
fn runUploads(m: harness.Metal, synchronous: bool) ![]u16 {
    const rows = 48;
    const width = 256;
    const words = width * rows / 2;
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();
    rig.r.synchronous = synchronous;
    const payload = try alloc.alloc(u32, words);
    defer alloc.free(payload);
    for (0..10) |i| {
        const word: u32 = @intCast(0x0400 + i);
        @memset(payload, word | (word << 16));
        rig.frame(payload, &.{
            fullDrawingArea(),
            .{ .kind = .vram_write_setup, .x = 0, .y = @intCast(i * rows), .w = width, .h = rows },
            .{ .kind = .vram_write_data, .x = 0, .y = words },
        });
    }
    const out = try alloc.alloc(u16, native_pixels);
    rig.vram.readbackNative(out[0..native_pixels]);
    return out;
}

// The record's bits and the instance's are two namespaces, so the mapping is
// a thing that can be wrong. Pinned per bit rather than as a pair: swapping
// the two would pass a test that only checked "flags != 0".
test "theRecordsPerspectiveBitsReachTheInstance" {
    const pairs = [_][2]u32{
        .{ command.flag_texture_perspective, pi.Flag.texture_perspective },
        .{ command.flag_color_perspective, pi.Flag.color_perspective },
    };
    for (pairs) |pair| {
        const cmd: Command = .{
            .kind = .draw_shaded_triangle,
            .flags = @intCast(pair[0]),
            .v = .{ vtx(0, 0, 0, 0, 0), vtx(32, 0, 0, 0, 0), vtx(0, 32, 0, 0, 0) },
        };
        var e: DrawingEnv = .{};
        e.area_bot_right = (511 << 10) | 1023;
        const inst = prim_builder.triangle(cmd, e, pi.Kind.gouraud_tri) orelse return error.TestUnexpectedNull;
        try std.testing.expect(inst.flags & pair[1] != 0);
        try std.testing.expectEqual(pair[1], inst.flags & (pi.Flag.texture_perspective | pi.Flag.color_perspective));
    }
}

// The depth bits and the three reciprocals reach the instance. Per bit, for
// the same reason the perspective test is per bit.
test "theRecordsDepthBitsAndReciprocalsReachTheInstance" {
    const pairs = [_][2]u32{
        .{ command.flag_depth_test, pi.Flag.depth_test },
        .{ command.flag_depth_write, pi.Flag.depth_write },
    };
    for (pairs) |pair| {
        var cmd: Command = .{
            .kind = .draw_triangle,
            .flags = @intCast(pair[0]),
            .v = .{ vtx(0, 0, 0, 0, 0), vtx(32, 0, 0, 0, 0), vtx(0, 32, 0, 0, 0) },
        };
        cmd.v[0].iz = 100;
        cmd.v[1].iz = 200;
        cmd.v[2].iz = 300;
        const inst = prim_builder.triangle(cmd, .{}, pi.Kind.flat_tri) orelse return error.TestUnexpectedNull;
        try std.testing.expectEqual(pair[1], inst.flags & (pi.Flag.depth_test | pi.Flag.depth_write));
        try std.testing.expectEqual([3]i32{ 100, 200, 300 }, [3]i32{ inst.iz0, inst.iz1, inst.iz2 });
    }
}

// The interpenetrating pair, replayed through Metal with the depth plane
// persisting: either draw order must give the same VRAM, and both colours
// must survive where the software rasterizer keeps them.
//
// b's near depth is 4200 rather than a's 4000, exactly as in `gpu_test.zig`:
// the two are otherwise mirror images about x=50, so identical depths would
// tie by construction along that axis and a tie resolves to the LATER draw,
// which is draw order showing through, not a depth-test defect.
test "interpenetratingTrianglesGiveOnePictureInEitherOrderInMetal" {
    const m = try harness.metal();
    defer m.deinit();
    const a = depthTestedTriangle(0x001F, .{ 10, 90, 10 }, .{ 4000, 1000, 4000 });
    const b = depthTestedTriangle(0x7C00, .{ 90, 10, 90 }, .{ 4200, 1000, 4200 });
    const ab = try drawn(m, .{ .depth_buffer = true }, &.{ fullDrawingArea(), a, b });
    defer alloc.free(ab);
    const ba = try drawn(m, .{ .depth_buffer = true }, &.{ fullDrawingArea(), b, a });
    defer alloc.free(ba);
    try std.testing.expect(std.mem.eql(u16, ab, ba));
    try std.testing.expectEqual(@as(u16, 0x001F), ab[50 * 1024 + 20]);
    try std.testing.expectEqual(@as(u16, 0x7C00), ab[50 * 1024 + 80]);
}

// 7 classes x true colour on/off x destination read on/off. Built up front so
// the first use of a variant mid-game is not a compile hitch.
test "everyVariantIsBuiltAtInit" {
    const m = try harness.metal();
    defer m.deinit();
    var vram = try ps1_metal.metal_vram.MetalVram.init(alloc, m.device, m.queue, 1, false);
    defer vram.deinit();
    const t0 = std.Io.Clock.awake.now(std.testing.io);
    var r = try ps1_metal.rasterizer.Rasterizer.init(alloc, &vram, m.lib);
    defer r.deinit();
    const elapsed = t0.untilNow(std.testing.io, .awake);
    try std.testing.expectEqual(28, r.variantPipelineCount());
    std.debug.print("[variants] Rasterizer.init built {d} pipelines in {d} ms\n", .{ r.variantPipelineCount(), elapsed.toMilliseconds() });
}

// The one destination read no flag announces: while the depth plane
// persists, a draw that does not write its own depth writes the STORED depth
// back, so it must take the reading variant even when it is opaque, unmasked
// and untested. The corpus cannot see this, so it is pinned here: an
// untested opaque triangle between a near depth-written one and a far
// depth-tested one must leave the near depth in place, and the far triangle
// must be refused.
test "anUntestedDrawKeepsTheStoredDepthWhileThePlanePersists" {
    const m = try harness.metal();
    defer m.deinit();
    const xs = [3]i16{ 10, 90, 10 };
    const plain: Command = .{
        .kind = .draw_triangle,
        .value = 0x03E0, // green
        .v = .{ vtx(10, 10, 0, 0, 0), vtx(90, 50, 0, 0, 0), vtx(10, 90, 0, 0, 0) },
    };
    const back = try drawn(m, .{ .depth_buffer = true }, &.{
        fullDrawingArea(),
        depthTestedTriangle(0x001F, xs, .{ 1000, 1000, 1000 }), // near, red
        plain,
        depthTestedTriangle(0x7C00, xs, .{ 500, 500, 500 }), // far, blue
    });
    defer alloc.free(back);
    try std.testing.expectEqual(@as(u16, 0x03E0), back[50 * 1024 + 20]);
}

// Lines expand to one instance per pixel, so a frame of long lines passes the
// first instance buffer's 65,536. The buffer must grow, and the frame must
// still match the software rasterizer pixel for pixel.
test "aFrameOfLongLinesOutgrowsTheFirstInstanceBufferAndStillMatches" {
    const m = try harness.metal();
    defer m.deinit();
    var records: [81]Command = undefined;
    records[0] = fullDrawingArea();
    // 80 horizontal lines of 1000 px: x 0..999 inclusive is 1001 pixels.
    for (0..80) |i| {
        const y: i16 = @intCast(4 + 6 * i);
        records[i + 1] = .{
            .kind = .draw_line,
            .value = @intCast(0x0421 * (i % 31 + 1) & 0x7FFF),
            .v = .{ vtx(0, y, 0, 0, 0), vtx(1000, y, 0, 0, 0), .{} },
        };
    }

    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();
    rig.r.dither_mode = .native;
    rig.r.beginFrame(&.{});
    for (records) |c| rig.r.apply(c);
    try std.testing.expectEqual(80 * 1001, rig.r.instances.items.len);
    rig.r.endFrame();

    const got = try rig.readback(alloc);
    defer alloc.free(got);
    const want = try harness.softwareFrame(alloc, &.{}, &records);
    defer alloc.destroy(want);
    if (!std.mem.eql(u16, got, &want.data)) {
        const message = try harness.report(alloc, "long-lines", 0, got, &want.data);
        defer alloc.free(message);
        std.debug.print("{s}\n", .{message});
        return error.TestExpectedEqual;
    }
}
