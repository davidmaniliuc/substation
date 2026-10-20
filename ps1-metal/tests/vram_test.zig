//! MetalVram: the texture, its sidecar and depth plane, and every way
//! pixels cross the bus. Ported from MetalVramTests.swift and
//! MetalScaleTests.swift; the dump and PNG writers are tested with the
//! harness.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const fixture = ps1_metal.fixture;
const harness = @import("harness.zig");

const objc = ps1_metal.objc;
const mtl = ps1_metal.mtl;
const enums = ps1_metal.mtl_enums;
const prim = ps1_metal.prim_instance;
const MetalVram = ps1_metal.metal_vram.MetalVram;

const alloc = std.heap.page_allocator;
const native_pixels = prim.native_pixels;

/// The hash of an all-zero image of `count` pixels.
fn blankHash(count: usize) u64 {
    const zeros = alloc.alloc(u16, count) catch @panic("out of memory");
    defer alloc.free(zeros);
    @memset(zeros, 0);
    return fixture.fnv1a(std.mem.sliceAsBytes(zeros));
}

fn hashOf(pixels: []const u16) u64 {
    return fixture.fnv1a(std.mem.sliceAsBytes(pixels));
}

/// A deterministic native image with distinct values in the places a
/// replication or a downsample bug lands: the four corners and a diagonal.
fn nativePattern() ![]u16 {
    const p = try alloc.alloc(u16, native_pixels);
    for (p, 0..) |*v, i| v.* = @truncate(i *% 2654435761);
    p[0] = 0x8001;
    p[prim.native_width - 1] = 0x7FFE;
    p[(prim.native_height - 1) * prim.native_width] = 0x1234;
    p[native_pixels - 1] = 0xABCD;
    return p;
}

fn expectAll(comptime T: type, items: []const T, want: T) !void {
    for (items, 0..) |v, i| {
        if (v != want) {
            std.debug.print("element {d}: got {x}, want {x}\n", .{ i, v, want });
            return error.TestExpectedEqual;
        }
    }
}

test "theRenderTextureStartsBlank" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var vram = try MetalVram.init(alloc, env.device, env.queue, 1, false);
    defer vram.deinit();
    // A .private texture's initial contents are NOT specified by Metal, so
    // MetalVram clears at init. Without that, every fixture's frame 0 hash is
    // a coin flip on whatever the allocator handed back.
    try std.testing.expectEqual(blankHash(native_pixels), vram.hash());
}

test "aTextureRoundTripsThroughUploadReadbackAndHash" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var vram = try MetalVram.init(alloc, env.device, env.queue, 1, false);
    defer vram.deinit();

    const pixels = try alloc.alloc(u16, native_pixels);
    defer alloc.free(pixels);
    for (pixels, 0..) |*v, i| v.* = @truncate(i *% 2654435761);
    // The four corners specifically: a bytesPerRow or origin mistake in the
    // blit shows up there and can average out anywhere else.
    pixels[0] = 0x8001;
    pixels[1023] = 0x7FFE;
    pixels[511 * 1024] = 0x1234;
    pixels[511 * 1024 + 1023] = 0xABCD;

    vram.upload(pixels);
    const back = try alloc.alloc(u16, vram.pixelCount());
    defer alloc.free(back);
    vram.readback(back);

    try std.testing.expectEqualSlices(u16, pixels, back);
    try std.testing.expectEqual(hashOf(pixels), vram.hash());
}

test "clearReturnsTheTextureToZero" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var vram = try MetalVram.init(alloc, env.device, env.queue, 1, false);
    defer vram.deinit();

    const ones = try alloc.alloc(u16, native_pixels);
    defer alloc.free(ones);
    @memset(ones, 0xFFFF);
    vram.upload(ones);
    try std.testing.expect(vram.hash() != blankHash(native_pixels));
    vram.clear();
    try std.testing.expectEqual(blankHash(native_pixels), vram.hash());
}

test "theRasterizerVertexFunctionAndFillPipelineBuild" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();

    const vertex = env.lib.newFunction("ps1_vertex") orelse return error.NoVertexFunction;
    defer vertex.release();
    const fill = env.lib.newFunction("ps1_fill_fragment") orelse return error.NoFillFunction;
    defer fill.release();
    // The display shader must still be in the SAME library after the merge.
    const display = env.lib.newFunction("display_vertex") orelse return error.NoDisplayFunction;
    display.release();

    const desc = mtl.RenderPipelineDescriptor.new();
    defer desc.release();
    desc.setVertexFunction(vertex);
    desc.setFragmentFunction(fill);
    desc.colorAttachment(0).setPixelFormat(.r16Uint);
    // ps1_fill_fragment returns Ps1FragOut, so a descriptor with only
    // attachment 0 does not build: the pipeline-side half of the "every
    // fragment writes both" rule.
    desc.colorAttachment(1).setPixelFormat(.rgba8Uint);
    const state = try env.device.newRenderPipelineState(desc);
    state.release();
}

test "theInstanceRecordLayoutIsWhatTheShaderAsserts" {
    // Rasterizer.metal carries static_assert(sizeof(Ps1PrimInstance) == 4 * 54).
    // A field added on one side only is otherwise a silent shear of every
    // instance in the buffer. The field offsets pin the order, not just the
    // total: swapping two fields keeps the size.
    try std.testing.expectEqual(4 * 54, @sizeOf(prim.PrimInstance));
    try std.testing.expectEqual(4, @alignOf(prim.PrimInstance));
    try std.testing.expectEqual(0, @offsetOf(prim.PrimInstance, "kind"));
    try std.testing.expectEqual(4 * 11, @offsetOf(prim.PrimInstance, "qx0"));
    try std.testing.expectEqual(4 * 48, @offsetOf(prim.PrimInstance, "rw0"));
    try std.testing.expectEqual(4 * 53, @offsetOf(prim.PrimInstance, "iz2"));
}

test "theRasterUniformIsSixteenBytesOnBothSides" {
    // Rasterizer.metal: static_assert(sizeof(Ps1RasterUniforms) == 16). A field
    // added on one side only shears scale, dither_mode, texture_filter and
    // sprite_filter against each other, and the symptom would be "scale 1
    // renders at scale 0", i.e. nothing drawn at all.
    try std.testing.expectEqual(16, @sizeOf(prim.Uniforms));
    try std.testing.expectEqual(0, @offsetOf(prim.Uniforms, "scale"));
    try std.testing.expectEqual(4, @offsetOf(prim.Uniforms, "dither_mode"));
    try std.testing.expectEqual(8, @offsetOf(prim.Uniforms, "texture_filter"));
    try std.testing.expectEqual(12, @offsetOf(prim.Uniforms, "sprite_filter"));
}

test "theConstantsAreTheHeadersValues" {
    try std.testing.expectEqual(@as(i32, 0), prim.Kind.flat_tri);
    try std.testing.expectEqual(@as(i32, 7), prim.Kind.fill);
    try std.testing.expectEqual(@as(i32, 10), prim.Kind.depth_clear);
    try std.testing.expectEqual(@as(u32, 1), prim.Flag.transparent);
    try std.testing.expectEqual(@as(u32, 1 << 7), prim.Flag.depth_test);
    try std.testing.expectEqual(@as(u32, 1 << 8), prim.Flag.depth_write);
    try std.testing.expectEqual(@as(u32, 3), @backingInt(prim.DitherMode.true_color));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(prim.TextureFilter.bilinear));
    try std.testing.expectEqual(prim.DitherMode.true_color, prim.default_dither);
}

test "theNativeConstantsDoNotFollowTheScale" {
    // Every instance field, every VramRect and every .vram dump is in these
    // units at EVERY internal resolution. If a scale ever leaks into them,
    // the encoder starts clamping in the wrong space and the oversized
    // refusal changes meaning.
    try std.testing.expectEqual(1024, prim.native_width);
    try std.testing.expectEqual(512, prim.native_height);
    try std.testing.expectEqual(1024 * 512, prim.native_pixels);

    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var v = try MetalVram.init(alloc, env.device, env.queue, 3, false);
    defer v.deinit();
    try std.testing.expectEqual(3, v.scale);
    try std.testing.expectEqual(3072, v.width());
    try std.testing.expectEqual(1536, v.height());
    try std.testing.expectEqual(3072 * 1536, v.pixelCount());
}

test "atOneXTheNativeViewIsTheWholeTexture" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var v = try MetalVram.init(alloc, env.device, env.queue, 1, false);
    defer v.deinit();
    const pattern = try nativePattern();
    defer alloc.free(pattern);
    v.uploadNative(pattern[0..native_pixels]);

    const native = try alloc.alloc(u16, native_pixels);
    defer alloc.free(native);
    v.readbackNative(native[0..native_pixels]);
    try std.testing.expectEqualSlices(u16, pattern, native);
    const full = try alloc.alloc(u16, v.pixelCount());
    defer alloc.free(full);
    v.readback(full);
    try std.testing.expectEqualSlices(u16, pattern, full);
    try std.testing.expectEqual(hashOf(pattern), v.nativeHash());
    try std.testing.expectEqual(v.hash(), v.nativeHash());
}

test "uploadNativeReplicatesEveryPixelIntoAnNbyNBlock" {
    // scale 3, not 2 or 4: `px / s` and `px % s` are shifts and masks at every
    // power of two, so an odd scale is the only one that catches a bug written
    // as `>> log2(s)` or an assumption that s divides some extent.
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var v = try MetalVram.init(alloc, env.device, env.queue, 3, false);
    defer v.deinit();
    const pattern = try nativePattern();
    defer alloc.free(pattern);
    v.uploadNative(pattern[0..native_pixels]);

    const full = try alloc.alloc(u16, v.pixelCount());
    defer alloc.free(full);
    v.readback(full);
    const points = [_][2]usize{ .{ 0, 0 }, .{ 1023, 0 }, .{ 0, 511 }, .{ 1023, 511 }, .{ 17, 43 } };
    for (points) |p| {
        const want = pattern[p[1] * prim.native_width + p[0]];
        for (0..3) |sy| {
            for (0..3) |sx| {
                const i = (p[1] * 3 + sy) * v.width() + (p[0] * 3 + sx);
                try std.testing.expectEqual(want, full[i]);
            }
        }
    }
}

test "readbackNativeRecoversTheImageUploadNativeReplicated" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    const pattern = try nativePattern();
    defer alloc.free(pattern);
    const native = try alloc.alloc(u16, native_pixels);
    defer alloc.free(native);
    for ([_]u32{ 2, 3, 4, 8 }) |scale| {
        var v = try MetalVram.init(alloc, env.device, env.queue, scale, false);
        defer v.deinit();
        v.uploadNative(pattern[0..native_pixels]);
        v.readbackNative(native[0..native_pixels]);
        std.testing.expectEqualSlices(u16, pattern, native) catch |e| {
            std.debug.print("scale {d}\n", .{scale});
            return e;
        };
        try std.testing.expectEqual(hashOf(pattern), v.nativeHash());
    }
}

test "readbackNativeTakesTheTopLeftSubtexelOfEachBlock" {
    // The downsample rule is "top-left subtexel", NOT an average and not the
    // last write to land in the block: at scale, subpixels other than the
    // top-left legitimately differ from their block's native value, and
    // discarding them is exactly what makes the exactness property a property.
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var v = try MetalVram.init(alloc, env.device, env.queue, 2, false);
    defer v.deinit();
    const full = try alloc.alloc(u16, v.pixelCount());
    defer alloc.free(full);
    for (0..v.height()) |y| {
        for (0..v.width()) |x| {
            // Top-left subpixels get 0x0101, every other subpixel 0xFFFF.
            full[y * v.width() + x] = if (x % 2 == 0 and y % 2 == 0) 0x0101 else 0xFFFF;
        }
    }
    v.upload(full);
    const native = try alloc.alloc(u16, native_pixels);
    defer alloc.free(native);
    v.readbackNative(native[0..native_pixels]);
    try expectAll(u16, native, 0x0101);
}

test "aScaledTextureStartsBlankJustLikeAOneXOne" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var v = try MetalVram.init(alloc, env.device, env.queue, 4, false);
    defer v.deinit();
    try std.testing.expectEqual(blankHash(native_pixels), v.nativeHash());
    const full = try alloc.alloc(u16, v.pixelCount());
    defer alloc.free(full);
    v.readback(full);
    try expectAll(u16, full, 0);
}

test "theSidecarStartsAbsentAndIsScaledLikeTheRenderTexture" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var vram = try MetalVram.init(alloc, env.device, env.queue, 3, false);
    defer vram.deinit();

    // The sidecar is a SECOND attachment on the same passes, so it must match
    // the render texture pixel for pixel at every internal resolution: a
    // mismatched size is a render-pass validation failure, not a wrong pixel.
    try std.testing.expectEqual(vram.width(), vram.sidecar.width());
    try std.testing.expectEqual(vram.height(), vram.sidecar.height());
    try std.testing.expectEqual(enums.PixelFormat.rgba8Uint, vram.sidecar.pixelFormat());

    // Alpha is PRESENCE. A .private texture's initial contents are
    // unspecified, so a blank VRAM must come with a blank sidecar or the very
    // first frame displays whatever the allocator handed back.
    const side = try alloc.alloc(u8, vram.pixelCount() * 4);
    defer alloc.free(side);
    vram.readbackSidecar(side);
    try expectAll(u8, side, 0);

    const native = try alloc.alloc(u8, native_pixels * 4);
    defer alloc.free(native);
    vram.readbackSidecarNative(native[0 .. native_pixels * 4]);
    try expectAll(u8, native, 0);
}

test "clearSidecarLeavesTheRenderTextureAlone" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var vram = try MetalVram.init(alloc, env.device, env.queue, 1, false);
    defer vram.deinit();
    const pixels = try alloc.alloc(u16, native_pixels);
    defer alloc.free(pixels);
    @memset(pixels, 0);
    pixels[7] = 0x1234;
    vram.upload(pixels);

    // The invalidation path: the sidecar is cleared through a pass that LOADS
    // and STORES attachment 0. Clearing both would silently wipe VRAM on every
    // resync, which at 1x is every dropped frame.
    vram.clearSidecar();
    const back = try alloc.alloc(u16, native_pixels);
    defer alloc.free(back);
    vram.readback(back);
    try std.testing.expectEqual(@as(u16, 0x1234), back[7]);
    const side = try alloc.alloc(u8, native_pixels * 4);
    defer alloc.free(side);
    vram.readbackSidecar(side);
    try expectAll(u8, side, 0);
}

test "aRegionSavedAsideComesBackWithTheRestOfVramUntouched" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    // Scale 3 and a region off the origin, so a scale factor missing from the
    // origin or the size lands the copy somewhere else.
    var v = try MetalVram.init(alloc, env.device, env.queue, 3, true);
    defer v.deinit();
    const a = try nativePattern();
    defer alloc.free(a);
    v.uploadNative(a[0..native_pixels]);

    const rect: prim.VramRect = .{ .x0 = 10, .y0 = 20, .x1 = 41, .y1 = 51 };
    v.saveRegion(rect);

    const b = try alloc.alloc(u16, native_pixels);
    defer alloc.free(b);
    @memset(b, 0x5555);
    v.uploadNative(b[0..native_pixels]);
    v.restoreRegion(rect);

    const native = try alloc.alloc(u16, native_pixels);
    defer alloc.free(native);
    v.readbackNative(native[0..native_pixels]);
    for (0..prim.native_height) |y| {
        for (0..prim.native_width) |x| {
            const inside = x >= 10 and x <= 41 and y >= 20 and y <= 51;
            const want = if (inside) a[y * prim.native_width + x] else 0x5555;
            if (native[y * prim.native_width + x] != want) {
                std.debug.print("({d},{d}): got {x}, want {x}\n", .{ x, y, native[y * prim.native_width + x], want });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "theDepthPlanePersistsOnlyWhenTheDepthBufferIsOn" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    const plane = try alloc.alloc(u32, native_pixels);
    defer alloc.free(plane);
    @memset(plane, 0xABCD);

    var on = try MetalVram.init(alloc, env.device, env.queue, 2, true);
    defer on.deinit();
    try std.testing.expect(on.depth_persists);
    try std.testing.expectEqual(on.width(), on.depth.width());
    try std.testing.expectEqual(enums.PixelFormat.r32Uint, on.depth.pixelFormat());
    on.uploadNativeDepth(plane[0..native_pixels]);

    var off = try MetalVram.init(alloc, env.device, env.queue, 2, false);
    defer off.deinit();
    try std.testing.expect(!off.depth_persists);
    // Memoryless: nothing to persist, so nothing to upload.
    off.uploadNativeDepth(plane[0..native_pixels]);
}

test "aScaleEightVramBuiltAndFreedTwentyTimesReturnsTheDevicesAllocation" {
    // Each cycle is ~270 MB at scale 8 (texture, sidecar, depth, staging). A
    // leaked texture shows up as hundreds of MB; autorelease debris from the
    // clears does not, because every cycle drains its own pool.
    const env = try harness.metal();
    defer env.deinit();
    const before = env.device.currentAllocatedSize();
    for (0..20) |_| {
        const pool = objc.Pool.push();
        defer pool.pop();
        var v = try MetalVram.init(alloc, env.device, env.queue, 8, true);
        v.deinit();
    }
    const after = env.device.currentAllocatedSize();
    std.testing.expect(after < before + (1 << 20)) catch |e| {
        std.debug.print("allocated {d} before, {d} after\n", .{ before, after });
        return e;
    };
}

test "aVramRectKnowsWhatItTouchesAndWhatItCovers" {
    const a: prim.VramRect = .{ .x0 = 0, .y0 = 0, .x1 = 9, .y1 = 9 };
    const b: prim.VramRect = .{ .x0 = 9, .y0 = 9, .x1 = 20, .y1 = 20 };
    const c: prim.VramRect = .{ .x0 = 10, .y0 = 0, .x1 = 20, .y1 = 9 };
    // Inclusive: sharing one pixel is an intersection, sharing an edge is not.
    try std.testing.expect(a.intersects(b));
    try std.testing.expect(b.intersects(a));
    try std.testing.expect(!a.intersects(c));
    const u = a.unionWith(b);
    try std.testing.expectEqual(prim.VramRect{ .x0 = 0, .y0 = 0, .x1 = 20, .y1 = 20 }, u);
}

// MARK: Sidecar coherence under the rasterizer

const command = @import("ps1_core").gpu.command;
const Command = command.Command;

fn vtx(x: i16, y: i16, color: u32) command.Vertex {
    return .{ .x = x, .y = y, .color = color, .px = @as(i32, x) << 16, .py = @as(i32, y) << 16 };
}

fn fillRecord(x: i32, y: i32, w: i32, h: i32, value: u32) Command {
    return .{ .kind = .fill_rect, .x = x, .y = y, .w = w, .h = h, .value = value };
}

fn alphaAt(side: []const u8, x: usize, y: usize) u8 {
    return side[(y * 1024 + x) * 4 + 3];
}

test "theSidecarMirrorsVramWhereverItIsPresent" {
    const env = try harness.metal();
    defer env.deinit();
    const rig = try harness.Rig.create(alloc, env, .{});
    defer rig.destroy();
    // Pinned rather than inherited from the shipped default: this invariant
    // is "the sidecar is the 8-bit expansion of 5-bit VRAM", which
    // `.true_color` deliberately breaks by keeping genuine 8-bit precision
    // the expansion can't reproduce.
    rig.r.dither_mode = .native;

    const tri: Command = .{
        .kind = .draw_shaded_triangle,
        .v = .{ vtx(100, 100, 0x0020_4060), vtx(300, 110, 0x00C0_8040), vtx(110, 260, 0x0040_C080) },
    };
    rig.frame(&.{}, &.{
        .{ .kind = .set_draw_env, .opcode = 0xE4, .value = (511 << 10) | 1023 },
        fillRecord(8, 8, 32, 32, 0x2955), // low bits set in all three channels
        tri,
    });

    const pixels = try rig.readback(alloc);
    defer alloc.free(pixels);
    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    var present: usize = 0;
    for (pixels, 0..) |p, i| {
        const a = side[i * 4 + 3];
        if (a == 0) {
            // Absent means nothing has drawn here, so VRAM is still blank.
            if (p != 0) {
                std.debug.print("pixel {d} is drawn but absent from the sidecar\n", .{i});
                return error.TestExpectedEqual;
            }
            continue;
        }
        // Alpha is presence: only 0 or 255 are legal.
        try std.testing.expectEqual(@as(u8, 255), a);
        present += 1;
        const channels = [3]u16{ p & 0x1F, (p >> 5) & 0x1F, (p >> 10) & 0x1F };
        for (channels, 0..) |c, k| {
            const want: u8 = @intCast((c << 3) | (c >> 2));
            if (side[i * 4 + k] != want) {
                std.debug.print("pixel {d} sidecar disagrees with the expansion of VRAM\n", .{i});
                return error.TestExpectedEqual;
            }
        }
    }
    // Guards the loop against passing vacuously. This geometry paints ~16,974
    // native pixels (the triangle's 15,950 plus the fill's 1,024); 10,000
    // still catches a blank frame, which is all this guard is for.
    try std.testing.expect(present > 10_000);
}

// GP0(A0). The payload is genuine 5551 from the game and no extra precision
// exists, so the destination rect goes ABSENT: exactly the rect, which is
// what per-pixel presence buys over a dirty rectangle.
test "theSidecarIsAbsentWhereVramWasUploaded" {
    const env = try harness.metal();
    defer env.deinit();
    const rig = try harness.Rig.create(alloc, env, .{});
    defer rig.destroy();

    const payload: [16]u32 = @splat(0x1234_1234);
    rig.frame(&payload, &.{
        fillRecord(0, 0, 64, 64, 0x7FFF),
        .{ .kind = .vram_write_setup, .x = 16, .y = 16, .w = 8, .h = 4 },
        // Payload word offset 0; 8 * 4 pixels / 2 per word.
        .{ .kind = .vram_write_data, .x = 0, .y = 16 },
    });

    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    // Inside the destination rect: absent.
    try std.testing.expectEqual(@as(u8, 0), alphaAt(side, 16, 16));
    try std.testing.expectEqual(@as(u8, 0), alphaAt(side, 23, 19));
    // One pixel outside it on each axis: still present from the fill.
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 15, 16));
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 24, 16));
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 16, 15));
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 16, 20));
}

// GP0(80). The sidecar is copied alongside VRAM, alpha included, in the SAME
// shader pass, so an absent source yields an absent destination and the
// invariant carries itself with no extra rule.
test "aCopyCarriesPresenceWithThePixels" {
    const env = try harness.metal();
    defer env.deinit();
    const rig = try harness.Rig.create(alloc, env, .{});
    defer rig.destroy();

    rig.frame(&.{}, &.{
        fillRecord(0, 0, 32, 32, 0x7FFF),
        // Present -> absent region: the fill copied somewhere never drawn.
        .{ .kind = .copy_rect, .x = 0, .y = 0, .x2 = 200, .y2 = 200, .w = 16, .h = 16 },
        // Absent -> present region: somewhere never drawn copied onto the fill.
        .{ .kind = .copy_rect, .x = 500, .y = 400, .x2 = 0, .y2 = 0, .w = 8, .h = 8 },
    });

    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 205, 205)); // carried presence into a blank region
    try std.testing.expectEqual(@as(u8, 0), alphaAt(side, 4, 4)); // carried absence over a drawn one
    try std.testing.expectEqual(@as(u8, 255), alphaAt(side, 20, 20)); // the rest of the fill is untouched
}

// A resync from a software frame is 5551 with no extra precision in it, so
// both upload paths invalidate the WHOLE sidecar. Keeping presence across one
// would display last frame's eight-bit colour under this frame's picture.
test "bothUploadPathsInvalidateTheWholeSidecar" {
    const env = try harness.metal();
    defer env.deinit();
    const rig = try harness.Rig.create(alloc, env, .{ .scale = 2 });
    defer rig.destroy();
    const fill = [_]Command{fillRecord(0, 0, 64, 64, 0x7FFF)};

    rig.frame(&.{}, &fill);
    try expectSidecar(rig, true);

    const native = try alloc.alloc(u16, native_pixels);
    defer alloc.free(native);
    @memset(native, 0x1234);
    rig.vram.uploadNative(native[0..native_pixels]);
    try expectSidecar(rig, false);

    rig.frame(&.{}, &fill);
    try expectSidecar(rig, true);

    const scaled = try alloc.alloc(u16, rig.vram.pixelCount());
    defer alloc.free(scaled);
    @memset(scaled, 0x1234);
    rig.vram.upload(scaled);
    try expectSidecar(rig, false);
}

/// `present`: some byte of the sidecar is 255. Otherwise: every byte is 0.
fn expectSidecar(rig: *harness.Rig, present: bool) !void {
    const side = try rig.readbackSidecar(alloc);
    defer alloc.free(side);
    if (present) {
        try std.testing.expect(std.mem.indexOfScalar(u8, side, 255) != null);
    } else {
        try std.testing.expect(std.mem.allEqual(u8, side, 0));
    }
}
