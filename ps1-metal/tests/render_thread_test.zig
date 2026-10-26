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
const Readback = ps1_metal.readback_desk.Readback;
const VramRect = ps1_metal.prim_instance.VramRect;
const Command = @import("ps1_core").gpu.command.Command;

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
        b.publishRecords(seq, &.{lh.fillRect(0, 0, 16, 16, 0x001F)});
    }

    fn publishRecords(b: *Bench, seq: u64, records: []const Command) void {
        const slot = b.x.shadowBack();
        @memset(&slot.pixels, 0);
        slot.depth_valid = false;
        slot.seq = seq;
        b.x.publishShadow();
        lh.publish(b.x.queue, seq, records);
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

test "RenderThread: aStopRacingTheFirstPassWakesALoopThatIsStillAlive" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    // The first pass can see the stop, end the loop and exit the thread
    // before `stop` wakes that loop; the loop must outlive its thread.
    for (0..2000) |_| {
        try b.rt.start(b.r, null, null, null);
        b.rt.stop();
    }
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

// MARK: Readbacks

const full: VramRect = .{ .x0 = 0, .y0 = 0, .x1 = lh.native_width - 1, .y1 = 511 };

/// Three fills at three places, one frame each.
const three_fills = [_]Command{
    lh.fillRect(0, 0, 32, 16, 0x001F),
    lh.fillRect(64, 32, 48, 16, 0x03E0),
    lh.fillRect(128, 96, 16, 64, 0x7C00),
};

/// A whole-VRAM readback through `seq`, into slices the caller frees.
fn fullReadback(seq: u64) !Readback {
    return .{ .rect = full, .colour = try alloc.alloc(u16, lh.native_pixels), .depth = null, .through_seq = seq };
}

/// The native VRAM a 1x replay of `frames` (one record each) leaves.
fn replayed(m: harness.Metal, frames: []const Command) ![]u16 {
    const rig = try harness.Rig.create(alloc, m, .{});
    defer rig.destroy();
    for (frames) |c| rig.frame(&.{}, &.{c});
    return rig.readback(alloc);
}

test "RenderThread: aReadbackSeesEveryFrameQueuedBeforeIt" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.rt.start(b.r, null, null, null);
    for (three_fills, 1..) |c, seq| b.publishRecords(seq, &.{c});
    var req = try fullReadback(3);
    defer alloc.free(req.colour);
    b.rt.readback(io, &req);
    const want = try replayed(b.m, &three_fills);
    defer alloc.free(want);
    try expect(!req.served_by_backstop);
    try harness.check(std.mem.eql(u16, want, req.colour), "the readback differs from a replay of the three frames before it", .{});
}

test "RenderThread: aReadbackCompletesWhileOccluded" {
    var b: Bench = undefined;
    try b.init(.{ .occluded = true });
    defer b.deinit();
    try b.rt.start(b.r, null, null, null);
    b.publishRecords(1, &.{three_fills[1]});
    var req = try fullReadback(1);
    defer alloc.free(req.colour);
    b.rt.readback(io, &req);
    const want = try replayed(b.m, three_fills[1..2]);
    defer alloc.free(want);
    try harness.check(std.mem.eql(u16, want, req.colour), "an occluded readback differs from the frame", .{});
}

test "RenderThread: aReadbackAcrossAScaleRebuildReadsTheCarriedPixels" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.rt.start(b.r, null, null, null);
    b.publishRecords(1, &.{three_fills[0]});
    try within(1000, b.x.queue, drained, "the frame was executed");
    // The rebuild and the readback arrive in the same pass: settings apply
    // first, so the readback reads the carried texture.
    b.r.mailbox.post(.{ .scale = 3 });
    var req = try fullReadback(1);
    defer alloc.free(req.colour);
    b.rt.readback(io, &req);
    try expectEqual(3, b.r.live.vram.scale);
    const want = try replayed(b.m, three_fills[0..1]);
    defer alloc.free(want);
    try harness.check(std.mem.eql(u16, want, req.colour), "the readback across a rebuild lost the 1x picture", .{});
}

test "RenderThread: aReadbackPostedBeforeTheThreadStartsIsServed" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    b.publishRecords(1, &.{three_fills[2]});
    var req = try fullReadback(1);
    defer alloc.free(req.colour);
    req.io = io;
    b.r.desk.post(&req);
    try b.rt.start(b.r, null, null, null);
    try req.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try expect(!req.served_by_backstop);
    const want = try replayed(b.m, three_fills[2..3]);
    defer alloc.free(want);
    try harness.check(std.mem.eql(u16, want, req.colour), "the first pass answered with the wrong pixels", .{});
}

const Asker = struct {
    rt: *RenderThread,
    req: *Readback,
    returned: std.atomic.Value(bool) = .init(false),

    fn run(self: *Asker) void {
        self.rt.readback(io, self.req);
        self.returned.store(true, .release);
    }
};

fn posted(r: *FrameRenderer) bool {
    return r.desk.pendingCount() == 1;
}

test "RenderThread: stopAnswersAPendingReadbackWithTheCurrentTexture" {
    var b: Bench = undefined;
    try b.init(.{});
    defer b.deinit();
    try b.rt.start(b.r, null, null, null);
    b.publishRecords(1, &.{three_fills[1]});
    try within(1000, b.x.queue, drained, "the frame was executed");
    // Through a frame that never comes: only the backstop can answer it.
    var req = try fullReadback(99);
    defer alloc.free(req.colour);
    var asker: Asker = .{ .rt = &b.rt, .req = &req };
    const t = try std.Thread.spawn(.{}, Asker.run, .{&asker});
    try within(1000, b.r, posted, "the readback was posted");
    b.rt.stop();
    t.join();
    try expect(asker.returned.load(.acquire));
    try expect(req.served_by_backstop);
    const want = try replayed(b.m, three_fills[1..2]);
    defer alloc.free(want);
    try harness.check(std.mem.eql(u16, want, req.colour), "the backstop answered with something other than the current texture", .{});
}
