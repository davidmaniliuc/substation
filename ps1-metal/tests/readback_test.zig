//! `LiveRenderer.readNative`: a native rect of the scaled texture (and the
//! depth plane) gathered on the GPU, by `readbackNative`'s top-left-subtexel
//! rule, and always of the REAL timeline.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const lh = @import("live_harness.zig");

const objc = ps1_metal.objc;
const Command = @import("ps1_core").gpu.command.Command;
const pi = ps1_metal.prim_instance;
const LiveRenderer = ps1_metal.live_renderer.LiveRenderer;
const VramRect = pi.VramRect;
const native_width = pi.native_width;
const native_pixels = pi.native_pixels;

const alloc = std.testing.allocator;
const check = harness.check;

const full: VramRect = .{ .x0 = 0, .y0 = 0, .x1 = native_width - 1, .y1 = pi.native_height - 1 };

/// Every pixel differs from its neighbours, so a gather off by a row, a
/// column or a subtexel reads a different value.
fn lcgImage() !*[native_pixels]u16 {
    const out = try alloc.create([native_pixels]u16);
    var s: u32 = 0x2545F491;
    for (out) |*w| {
        s = s *% 1664525 +% 1013904223;
        w.* = @truncate((s >> 15) & 0x7FFF);
    }
    return out;
}

fn pixelsOf(r: VramRect) usize {
    return @intCast((r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1));
}

/// `r` cut row by row out of a full native view.
fn cut(view: *const [native_pixels]u16, r: VramRect) ![]u16 {
    const out = try alloc.alloc(u16, pixelsOf(r));
    const w: usize = @intCast(r.x1 - r.x0 + 1);
    var o: usize = 0;
    var y = r.y0;
    while (y <= r.y1) : (y += 1) {
        const start: usize = @as(usize, @intCast(y)) * native_width + @as(usize, @intCast(r.x0));
        @memcpy(out[o..][0..w], view[start..][0..w]);
        o += w;
    }
    return out;
}

/// `readNative` over `r` equals the same rect cut from `readbackNative`.
fn expectRectMatchesNativeView(live: *LiveRenderer, r: VramRect, scale: u32) !void {
    const view = try lh.readback(live);
    defer alloc.destroy(view);
    const want = try cut(view, r);
    defer alloc.free(want);
    const got = try alloc.alloc(u16, pixelsOf(r));
    defer alloc.free(got);
    live.readNative(r, got, null);
    try check(std.mem.eql(u16, want, got), "readNative ({d},{d})-({d},{d}) at {d}x differs from the native view", .{ r.x0, r.y0, r.x1, r.y1, scale });
}

test "readNative: aRectReadsTheNativeViewAtEveryScale" {
    const m = try harness.metal();
    defer m.deinit();
    const image = try lcgImage();
    defer alloc.destroy(image);
    for ([_]u32{ 1, 3, 8 }) |s| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const live = try lh.make(m, s, false);
        defer live.deinit();
        const q = try lh.queue();
        defer q.deinit();
        live.vram.uploadNative(image);
        lh.publish(q, 1, &.{lh.fillRect(160, 96, 64, 48, 0x03E0)});
        var shadow: lh.Shadow = .{};
        live.drain(q, &shadow);
        try expectRectMatchesNativeView(live, .{ .x0 = 100, .y0 = 50, .x1 = 419, .y1 = 289 }, s);
    }
}

test "readNative: aRectAtTheFarCornerReadsTheLastBlock" {
    const m = try harness.metal();
    defer m.deinit();
    const image = try lcgImage();
    defer alloc.destroy(image);
    for ([_]u32{ 3, 8 }) |s| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const live = try lh.make(m, s, false);
        defer live.deinit();
        live.vram.uploadNative(image);
        try expectRectMatchesNativeView(live, .{ .x0 = 1000, .y0 = 500, .x1 = 1023, .y1 = 511 }, s);
    }
}

test "readNative: aDepthReadReturnsThePlane" {
    const m = try harness.metal();
    defer m.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    const live = try lh.make(m, 3, true);
    defer live.deinit();
    const plane = try alloc.create([native_pixels]u32);
    defer alloc.destroy(plane);
    for (plane, 0..) |*d, i| d.* = @as(u32, @intCast(i)) *% 2654435761;
    live.vram.uploadNativeDepth(plane);

    const colour = try alloc.alloc(u16, native_pixels);
    defer alloc.free(colour);
    const depth = try alloc.alloc(u32, native_pixels);
    defer alloc.free(depth);
    live.readNative(full, colour, depth);
    try check(std.mem.eql(u32, plane, depth), "the depth read differs from the uploaded plane", .{});
}

test "readNative: aDepthReadWhileThePlaneIsMemorylessIsFar" {
    const m = try harness.metal();
    defer m.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    const live = try lh.make(m, 3, false);
    defer live.deinit();
    const colour = try alloc.alloc(u16, native_pixels);
    defer alloc.free(colour);
    const depth = try alloc.alloc(u32, native_pixels);
    defer alloc.free(depth);
    @memset(depth, 0xFFFF_FFFF);
    live.readNative(full, colour, depth);
    for (depth) |d| try check(d == 0, "a memoryless plane read {x}, not far", .{d});
}

test "readNative: aReadbackWhileASpeculativePictureIsUpReadsTheRealTimeline" {
    const m = try harness.metal();
    defer m.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    const live = try lh.make(m, 1, false);
    defer live.deinit();
    const q = try lh.queue();
    defer q.deinit();

    const red = [_]Command{lh.fillRect(32, 32, 16, 16, 0x001F)};
    const green = [_]Command{lh.fillRect(32, 32, 16, 16, 0x03E0)};
    _ = q.stage(1, .{ .records = &red, .payload = &.{}, .complete = true });
    q.beginSpeculativeGroup(1);
    q.appendSpeculative(.{ .records = &green, .payload = &.{}, .complete = true });
    q.commitSpeculativeGroup(.{});
    q.commitStaged();
    var shadow: lh.Shadow = .{};
    live.drain(q, &shadow);
    try check(live.pending_restore != null, "the group did not leave a speculative picture up", .{});

    const r: VramRect = .{ .x0 = 32, .y0 = 32, .x1 = 47, .y1 = 47 };
    var got: [256]u16 = undefined;
    live.readNative(r, &got, null);
    for (got) |p| try check(p == 0x001F, "read {x:0>4}, not the real frame's red", .{p});
}
