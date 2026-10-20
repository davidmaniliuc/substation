//! What the live-renderer tests share: building one, publishing hand-built
//! frames, and the shadow sources `drain` and `diff` call, which count their
//! calls so a test can assert the 1 MB copy was never built.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");
const harness = @import("harness.zig");

const pi = ps1_metal.prim_instance;
const live_renderer = ps1_metal.live_renderer;
const LiveRenderer = live_renderer.LiveRenderer;
const StreamQueue = ps1_metal.stream_queue.StreamQueue;
const Command = ps1_core.gpu.command.Command;
const Allocator = std.mem.Allocator;

pub const native_width = pi.native_width;
pub const native_pixels = pi.native_pixels;

const alloc = std.testing.allocator;

/// The shadow a test never expects to be adopted: all black.
pub const blank: [native_pixels]u16 = @splat(0);

pub fn make(m: harness.Metal, scale: u32, depth_buffer: bool) !*LiveRenderer {
    return LiveRenderer.init(alloc, .{ .device = m.device, .queue = m.queue, .lib = m.lib }, scale, depth_buffer, .{});
}

/// A queue with the fresh-queue resync already cleared: what a running game
/// looks like.
pub fn queue() !*StreamQueue {
    const q = try StreamQueue.init(alloc);
    q.clearResync();
    return q;
}

pub fn fillRect(x: i32, y: i32, w: i32, h: i32, color: u32) Command {
    return .{ .kind = .fill_rect, .x = x, .y = y, .w = w, .h = h, .value = color };
}

/// `copy_rect` reads x/y as the SOURCE and x2/y2 as the DESTINATION.
pub fn copyRect(src_x: i32, src_y: i32, dst_x: i32, dst_y: i32, w: i32, h: i32) Command {
    return .{ .kind = .copy_rect, .x = src_x, .y = src_y, .x2 = dst_x, .y2 = dst_y, .w = w, .h = h };
}

/// Publishes one frame of records with no payload.
pub fn publish(q: *StreamQueue, seq: u64, records: []const Command) void {
    q.publish(seq, .{ .records = records, .payload = &.{}, .complete = true });
}

/// A fill of the whole 16x16 box at (x, y) with `color`. One record, no
/// payload: the smallest stream that provably changes VRAM.
pub fn fill(q: *StreamQueue, seq: u64, x: i32, y: i32, color: u32) void {
    publish(q, seq, &.{fillRect(x, y, 16, 16, color)});
}

/// Frame `seq` never reaches the queue. `complete = false` is the cheapest of
/// the three ways that happens and the only one that enqueues nothing else.
pub fn lose(q: *StreamQueue, seq: u64) void {
    q.publish(seq, .{ .records = &.{fillRect(0, 0, 1, 1, 0)}, .payload = &.{}, .complete = false });
}

/// `drain`'s shadow source, counting how often it is sampled.
pub const Shadow = struct {
    pixels: *const [native_pixels]u16 = &blank,
    depth: ?*const [native_pixels]u32 = null,
    seq: u64 = 0,
    calls: usize = 0,
    /// Raises a resync from inside the sample, as a producer racing the
    /// consumer would.
    raise_on: ?*StreamQueue = null,

    pub fn sample(self: *Shadow) live_renderer.Shadow {
        self.calls += 1;
        if (self.raise_on) |q| q.requestResync();
        return .{ .pixels = self.pixels, .depth = self.depth, .seq = self.seq };
    }
};

/// `diff`'s shadow source, counting how often it is built.
pub const DiffShadow = struct {
    image: *const [native_pixels]u16,
    calls: usize = 0,

    pub fn pixels(self: *DiffShadow) *const [native_pixels]u16 {
        self.calls += 1;
        return self.image;
    }
};

/// A native image, zeroed. Free with `alloc.destroy`.
pub fn image(fill_value: u16) !*[native_pixels]u16 {
    const p = try alloc.create([native_pixels]u16);
    @memset(p, fill_value);
    return p;
}

/// The texture's native view. Free with `alloc.destroy`.
pub fn readback(live: *LiveRenderer) !*[native_pixels]u16 {
    const p = try alloc.create([native_pixels]u16);
    live.vram.readbackNative(p);
    return p;
}

/// One native pixel of the texture.
pub fn pixelAt(live: *LiveRenderer, i: usize) !u16 {
    const p = try readback(live);
    defer alloc.destroy(p);
    return p[i];
}
