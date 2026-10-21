//! The memory movers on the GPU: the attachment-as-source assumption the
//! whole backend rests on, the upload payload guard, the committed mover
//! fixture, and uploads under the hazard rule. Ported from
//! MetalMoverTests.swift; its `VramTransfer` cases live with `WriteCursor`
//! in ps1-core.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const objc = ps1_metal.objc;
const pi = ps1_metal.prim_instance;
const Command = ps1_core.gpu.command.Command;

const alloc = std.testing.allocator;
const native_width = pi.native_width;
const native_pixels = pi.native_pixels;

// MARK: The foundational risk
//
// Everything downstream assumes a texture bound as [[color(0)]] can be read()
// at a DIFFERENT coordinate by the same draw, and that such a read sees the
// PRE-PASS contents. That is what a tile-based GPU gives: the tile being
// rendered lives in tile memory and the rest of the attachment stays in
// device memory until the store action runs. If this test ever fails, the
// named fallback is a second .private texture holding the last committed
// VRAM, refreshed by a blit at each pass boundary and sampled instead of the
// attachment: a substitution behind the rasterizer's interface, not a
// redesign.
test "aTextureBoundAsAttachmentCanBeReadAtAnotherCoordinate" {
    const m = try harness.metal();
    defer m.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    var vram = try ps1_metal.metal_vram.MetalVram.init(alloc, m.device, m.queue, 1, false);
    defer vram.deinit();

    const pixels = try alloc.alloc(u16, native_pixels);
    defer alloc.free(pixels);
    @memset(pixels, 0);
    for (0..64) |i| pixels[500 * 1024 + 100 + i] = @intCast(0x1000 + i);
    vram.upload(pixels);

    const vertex = m.lib.newFunction("ps1_vertex") orelse return error.MissingFunction;
    defer vertex.release();
    const fragment = m.lib.newFunction("ps1_copy_fragment") orelse return error.MissingFunction;
    defer fragment.release();
    const desc = ps1_metal.mtl.RenderPipelineDescriptor.new();
    defer desc.release();
    desc.setVertexFunction(vertex);
    desc.setFragmentFunction(fragment);
    desc.colorAttachment(0).setPixelFormat(.r16Uint);
    const pipeline = try m.device.newRenderPipelineState(desc);
    defer pipeline.release();

    // Copy (100,500)-(163,500) to (0,0)-(63,0), reading THE ATTACHMENT ITSELF
    // rather than a scratch snapshot. The source row was written by an
    // earlier command buffer, so the invariant holds and the read must be
    // exact.
    var inst = std.mem.zeroes(pi.PrimInstance);
    inst.kind = pi.Kind.copy;
    inst.box_x1 = 63;
    inst.src_x = 100;
    inst.src_y = 500;
    inst.w = 64;
    inst.h = 1;
    const buffer = m.device.newBuffer(@sizeOf(pi.PrimInstance), ps1_metal.mtl_enums.resourceOptions(.shared)) orelse
        return error.NoBuffer;
    defer buffer.release();
    @as(*pi.PrimInstance, @ptrCast(@alignCast(buffer.contents()))).* = inst;

    const pass = ps1_metal.mtl.RenderPassDescriptor.renderPassDescriptor();
    const colour = pass.colorAttachment(0);
    colour.setTexture(vram.texture);
    colour.setLoadAction(.load);
    colour.setStoreAction(.store);

    const cmd = m.queue.commandBuffer() orelse return error.NoCommandBuffer;
    const enc = cmd.renderCommandEncoder(pass) orelse return error.NoEncoder;
    enc.setRenderPipelineState(pipeline);
    enc.setVertexBuffer(buffer, 0, 0);
    enc.setFragmentBuffer(buffer, 0, 0);
    enc.setFragmentTexture(vram.texture, 0);
    // ps1_vertex reads the raster uniforms; this encoder is hand-rolled and
    // does not go through the rasterizer's pass, so it binds them itself. An
    // unbound buffer argument is undefined, not zero.
    const uni: pi.Uniforms = .{
        .scale = 1,
        .dither_mode = @backingInt(pi.DitherMode.off),
        .texture_filter = @backingInt(pi.TextureFilter.nearest),
        .sprite_filter = @backingInt(pi.TextureFilter.nearest),
    };
    enc.setVertexBytes(std.mem.asBytes(&uni), 2);
    enc.setFragmentBytes(std.mem.asBytes(&uni), 2);
    enc.drawPrimitives(.triangleStrip, 0, 4, 1, 0);
    enc.endEncoding();
    cmd.commit();
    cmd.waitUntilCompleted();

    vram.readback(pixels);
    for (0..64) |i| try std.testing.expectEqual(@as(u16, @intCast(0x1000 + i)), pixels[i]);
}

// MARK: encodeUpload's payload-overrun guard
//
// A record's off/len pair comes straight off the wire and the fixture format
// never validates it, so a malformed pair reaching `word_base + (pix >> 1)`
// in ps1_upload_fragment would read past the payload buffer's real
// allocation: an out-of-bounds device-buffer read, not merely a wrong pixel.

fn setupRecord(x: i32, y: i32, w: i32, h: i32) Command {
    return .{ .kind = .vram_write_setup, .x = x, .y = y, .w = w, .h = h };
}

/// `off` is the payload offset in words, `len` the length in words.
fn dataRecord(off: i32, len: i32) Command {
    return .{ .kind = .vram_write_data, .x = off, .y = len };
}

test "aVramWriteDataRecordThatOverrunsThePayloadUploadsNoInstanceAndMovesNoPixel" {
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();
    // MetalVram starts cleared; this is the "nothing happened" baseline.
    const before = rig.vram.hash();

    // The payload holds 1 word (2 pixels). off=0, len=2 claims a SECOND word
    // that was never uploaded: off + len (2) > payload_count (1).
    const words = [_]u32{0x2222_1111};
    rig.frame(&words, &.{ setupRecord(0, 0, 2, 1), dataRecord(0, 2) });

    try std.testing.expectEqual(before, rig.vram.hash());
}

// The boundary the guard must NOT reject: off + len == payload_count is a
// legitimate, fully-backed transfer. Pinned so the guard above can never be
// tightened by one word without this test going red.
test "aVramWriteDataRecordLandingExactlyOnThePayloadEdgeStillUploads" {
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();

    // 2 words = 4 pixels, exactly payload_count.
    const words = [_]u32{ 0xBBBB_AAAA, 0xDDDD_CCCC };
    rig.frame(&words, &.{ setupRecord(0, 0, 2, 2), dataRecord(0, 2) });

    const back = try rig.readback(alloc);
    defer alloc.free(back);
    try std.testing.expectEqual(@as(u16, 0xAAAA), back[0]);
    try std.testing.expectEqual(@as(u16, 0xBBBB), back[1]);
    try std.testing.expectEqual(@as(u16, 0xCCCC), back[native_width]);
    try std.testing.expectEqual(@as(u16, 0xDDDD), back[native_width + 1]);
}

// MARK: The mover gate
//
// synthetic-movers is committed, so this runs on a fresh clone. Croc is the
// one real-game fixture at real payload sizes (200 frames, 1,014 transfers,
// 50 fills), and it is generated from games/, so it skips, naming itself,
// when absent.
test "replaysTheSyntheticMoverFixtureOnTheGpu" {
    const m = try harness.metal();
    defer m.deinit();
    const r = try harness.replay(alloc, m, "synthetic-movers", .{});
    defer r.deinit(alloc);
    try std.testing.expectEqual(6, r.frames_checked);
    if (r.first_divergence != null) std.debug.print("{s}\n", .{r.message});
    try std.testing.expectEqual(null, r.first_divergence);
}

test "replaysTheCrocMoverFixtureOnTheGpu" {
    const m = try harness.metal();
    defer m.deinit();
    const r = try harness.replay(alloc, m, "croc-legend-of-the-gobbos", .{});
    defer r.deinit(alloc);
    try std.testing.expectEqual(200, r.frames_checked);
    if (r.first_divergence != null) std.debug.print("{s}\n", .{r.message});
    try std.testing.expectEqual(null, r.first_divergence);
}

// MARK: Uploads under the hazard rule
//
// An upload WRITES its box and samples nothing, so it is ordered like any
// other write: it starts a new pass only when it overwrites what this pass
// already sampled, and a later draw sampling it breaks as usual. FF8 streams
// each movie frame as ~200 strip uploads; one pass apiece saturated the GPU
// at every scale and starved the audio.

/// A 2x1 16bpp sprite at (0, 300) that samples u = 0..1 of the page at (256, 0).
fn spriteSamplingPageAt256() [2]Command {
    return .{
        .{ .kind = .set_draw_env, .opcode = 0xE4, .value = (511 << 10) | 1023 },
        .{
            .kind = .draw_textured_rectangle,
            .opcode = 0x65, // RAW: no modulation
            .tpage = 0x0104, // page x 4 (-> 256), 16bpp
            .x = 0,
            .y = 300,
            .w = 2,
            .h = 1,
        },
    };
}

test "backToBackUploadsShareOneRenderPass" {
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();

    // Sixteen 2x1 strips side by side, the shape of a movie frame's upload.
    const strips = 16;
    var words: [strips]u32 = undefined;
    var records: [2 * strips]Command = undefined;
    for (0..strips) |i| {
        words[i] = @as(u32, @intCast(0x1000 + 2 * i)) | (@as(u32, @intCast(0x1001 + 2 * i)) << 16);
        records[2 * i] = setupRecord(@intCast(2 * i), 10, 2, 1);
        records[2 * i + 1] = dataRecord(@intCast(i), 1);
    }
    const before = rig.r.pass_count;
    rig.frame(&words, &records);

    try std.testing.expectEqual(1, rig.r.pass_count - before);
    const back = try rig.readback(alloc);
    defer alloc.free(back);
    for (0..2 * strips) |px| try std.testing.expectEqual(@as(u16, @intCast(0x1000 + px)), back[10 * native_width + px]);
}

// The write-after-read half of the hazard rule: without the split the
// sprite's read races the upload's tile store, so the sprite must still see
// the texel the page held before the upload.
test "anUploadOverWhatThisPassSampledStartsANewPass" {
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();
    const pixels = try alloc.alloc(u16, native_pixels);
    defer alloc.free(pixels);
    @memset(pixels, 0);
    pixels[256] = 0x1234;
    pixels[257] = 0x1235;
    rig.vram.upload(pixels);

    const words = [_]u32{0x5679_5678};
    const sprite = spriteSamplingPageAt256();
    const before = rig.r.pass_count;
    rig.frame(&words, &(sprite ++ [_]Command{ setupRecord(256, 0, 2, 1), dataRecord(0, 1) }));

    try std.testing.expectEqual(2, rig.r.pass_count - before);
    const back = try rig.readback(alloc);
    defer alloc.free(back);
    try std.testing.expectEqual(@as(u16, 0x1234), back[300 * native_width]);
    try std.testing.expectEqual(@as(u16, 0x1235), back[300 * native_width + 1]);
    try std.testing.expectEqual(@as(u16, 0x5678), back[256]);
    try std.testing.expectEqual(@as(u16, 0x5679), back[257]);
}

// The read-after-write half: the upload's texels must be in device memory
// before the sprite samples them, so the sprite starts a new pass.
test "aSpriteSamplesWhatAnUploadEarlierInTheFrameWrote" {
    const m = try harness.metal();
    defer m.deinit();
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();

    const words = [_]u32{0x5679_5678};
    const before = rig.r.pass_count;
    rig.frame(&words, &([_]Command{ setupRecord(256, 0, 2, 1), dataRecord(0, 1) } ++ spriteSamplingPageAt256()));

    try std.testing.expectEqual(2, rig.r.pass_count - before);
    const back = try rig.readback(alloc);
    defer alloc.free(back);
    try std.testing.expectEqual(@as(u16, 0x5678), back[300 * native_width]);
    try std.testing.expectEqual(@as(u16, 0x5679), back[300 * native_width + 1]);
}
