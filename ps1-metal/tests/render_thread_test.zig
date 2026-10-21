//! The render thread around a real `FrameRenderer`: executed on arrival,
//! presented by a timer or a display link, a parked producer woken by the
//! drain, and a stop that answers what is still queued.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const lh = @import("live_harness.zig");

const objc = ps1_metal.objc;
const layer = ps1_metal.mtl_layer;
const fr = ps1_metal.frame_renderer;
const waker = ps1_metal.waker;
const FrameRenderer = fr.FrameRenderer;
const RenderThread = ps1_metal.render_thread.RenderThread;
const Exchange = ps1_metal.frame_exchange.Exchange;
const StreamQueue = ps1_metal.stream_queue.StreamQueue;

const alloc = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const band: ps1_metal.display.Band = .{ .height = 52, .edge = 10, .sigma = 8 };
const sized: fr.Settings = .{ .size_points = .{ 64, 48 } };

/// A renderer and its thread over a fresh exchange, the thread its
/// `on_published`.
const Bench = struct {
    m: harness.Metal,
    x: *Exchange,
    r: *FrameRenderer,
    rt: RenderThread = .{},

    fn init(b: *Bench, initial: fr.Settings) !void {
        b.m = try harness.metal();
        errdefer b.m.deinit();
        b.x = try Exchange.init(alloc);
        errdefer b.x.deinit();
        b.x.queue.clearResync();
        b.r = try FrameRenderer.init(alloc, b.m, b.x, band, .{}, initial);
        b.rt = .{};
        b.x.on_published = b.rt.waker();
    }

    fn deinit(b: *Bench) void {
        b.rt.stop();
        b.rt.deinit();
        b.r.deinit();
        b.x.deinit();
        b.m.deinit();
    }

    /// Frame `seq` the producer's way: shadow, stream, display, wake.
    fn publish(b: *Bench, seq: u64) void {
        const slot = b.x.shadowBack();
        @memset(&slot.pixels, 0);
        slot.depth_valid = false;
        slot.seq = seq;
        b.x.publishShadow();
        lh.fill(b.x.queue, seq, 0, 0, 0x001F);
        b.x.publishDisplay(.{ .width = 320, .height = 240, .enabled = true });
        b.x.notifyPublished();
    }
};

/// Polls `done` for up to `limit_ms`.
fn within(limit_ms: i64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool, what: []const u8) !void {
    const t0 = std.Io.Clock.awake.now(io);
    while (!done(ctx)) {
        if (t0.untilNow(io, .awake).nanoseconds > limit_ms * std.time.ns_per_ms) {
            std.debug.print("{s}: not within {d} ms\n", .{ what, limit_ms });
            return error.TestUnexpectedResult;
        }
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(1), .clock = .awake }, io);
    }
}

fn drained(q: *StreamQueue) bool {
    return q.pendingCount() == 0;
}

fn presentedTen(r: *FrameRenderer) bool {
    return r.presented.load(.monotonic) >= 10;
}

fn presentedThree(r: *FrameRenderer) bool {
    return r.presented.load(.monotonic) >= 3;
}

fn standaloneLayer(m: harness.Metal) layer.MetalLayer {
    const l = layer.MetalLayer.new();
    l.setDevice(m.device);
    l.setPixelFormat(.bgra8Unorm);
    l.setFramebufferOnly(true);
    l.setPresentsWithTransaction(false);
    return l;
}

test "RenderThread: aPublishedFrameIsExecutedWithoutWaitingForAPresent" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    // No link and no timer: nothing ever presents.
    try b.rt.start(b.r, null, null, null);
    b.publish(1);
    try within(1000, b.x.queue, drained, "the frame was executed");
    b.publish(2);
    try within(1000, b.x.queue, drained, "the second frame was executed");
    b.rt.stop();
    try expectEqual(2, b.r.live.last_executed_seq);
    try expectEqual(0, b.r.presented.load(.monotonic));
}

test "RenderThread: theTimerPresentsTheNewestExecutedFrame" {
    var b: Bench = undefined;
    try b.init(sized);
    defer b.deinit();
    const l = standaloneLayer(b.m);
    defer l.release();
    try b.rt.start(b.r, l, null, 120);
    b.publish(1);
    try within(2000, b.r, presentedTen, "ten presents");
    b.publish(2);
    try within(1000, b.x.queue, drained, "the newest frame was executed");
    b.rt.stop();
    try expectEqual(2, b.r.live.last_executed_seq);
}

/// A producer parked on a full ring, the way the emulator thread parks.
const Producer = struct {
    x: *Exchange,
    pacer: *waker.Pacer,
    resumed: std.atomic.Value(bool) = .init(false),

    fn run(self: *Producer) void {
        while (self.x.queue.isFull()) {
            const seen = self.pacer.generation();
            if (!self.x.queue.isFull()) break;
            self.pacer.wait(io, seen, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
        }
        self.resumed.store(true, .release);
    }
};

fn resumed(p: *Producer) bool {
    return p.resumed.load(.acquire);
}

test "RenderThread: aDrainWakesAProducerParkedOnAFullQueue" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    var pacer: waker.Pacer = .{};
    var pw: waker.PacerWake = .{ .pacer = &pacer, .io = io };
    b.x.queue.on_drained = pw.waker();
    // Filled before the thread runs, so nothing drains it yet.
    const saved = b.x.on_published;
    b.x.on_published = null;
    for (1..StreamQueue.capacity + 1) |seq| b.publish(seq);
    b.x.on_published = saved;
    try expect(b.x.queue.isFull());

    var p: Producer = .{ .x = b.x, .pacer = &pacer };
    const t = try std.Thread.spawn(.{}, Producer.run, .{&p});
    defer t.join();
    try b.rt.start(b.r, null, null, null);
    try within(1000, &p, resumed, "the producer resumed");
    try expect(!b.x.queue.isFull());
}

test "RenderThread: stopJoinsAndAnswersPendingScreenshots" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    const Answer = struct {
        count: std.atomic.Value(u32) = .init(0),
        fn done(ctx: ?*anyopaque, _: ?[*]const u8, _: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = self.count.fetchAdd(1, .acq_rel);
        }
    };
    var a: Answer = .{};
    try b.rt.start(b.r, null, null, null);
    b.r.requestScreenshot(Answer.done, &a);
    b.rt.stop();
    // Answered by a picture if a pass ran after the request, by null if
    // not: exactly once either way, and before `stop` returned.
    try expectEqual(1, a.count.load(.acquire));
    try expectEqual(0, b.r.pendingRequests());
}

test "RenderThread: theDisplayLinkDrivesPresentsOnAViewInAWindow" {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (!layer.onMainThread()) {
        std.debug.print("not on the main thread: AppKit windows need it\n", .{});
        return error.SkipZigTest;
    }
    layer.sharedApplication();
    if (!layer.hasScreen()) {
        std.debug.print("no screen\n", .{});
        return error.SkipZigTest;
    }
    if (layer.screenLocked()) {
        std.debug.print("the screen is locked: display links do not fire\n", .{});
        return error.SkipZigTest;
    }
    var b: Bench = undefined;
    try b.init(sized);
    defer b.deinit();
    const w = layer.Window.new(64, 48);
    defer w.close();
    const l = standaloneLayer(b.m);
    defer l.release();
    const view = w.view();
    view.setWantsLayer(true);
    view.setLayer(l);
    w.orderFront();
    const link = view.displayLink(b.rt.target(), "fire:");
    defer link.release();
    try b.rt.start(b.r, l, link, null);
    b.publish(1);
    try within(2000, b.r, presentedThree, "three presents on the link");
    b.rt.stop();
    try expectEqual(1, b.r.live.last_executed_seq);
}
