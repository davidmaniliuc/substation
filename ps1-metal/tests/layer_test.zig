//! The pieces the render thread is made of: a runtime class whose method
//! calls Zig, a CFRunLoop source another thread signals, a standalone
//! CAMetalLayer, and a display link on a view in a window.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");

const objc = ps1_metal.objc;
const cf = ps1_metal.cf;
const layer = ps1_metal.mtl_layer;
const mtl = ps1_metal.mtl;

const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Counter = struct {
    count: std.atomic.Value(u32) = .init(0),
    thread: std.atomic.Value(u64) = .init(0),

    fn fire(self: *Counter) void {
        self.thread.store(@intCast(std.Thread.getCurrentId()), .release);
        _ = self.count.fetchAdd(1, .acq_rel);
    }
};

const Target = objc.TargetClass("Ps1LayerTestTarget", Counter, Counter.fire);

/// Waits up to a second for `c` to count at least `n`.
fn awaitCount(c: *const Counter, n: u32, what: []const u8) !void {
    const t0 = std.Io.Clock.awake.now(io);
    while (c.count.load(.acquire) < n) {
        if (t0.untilNow(io, .awake).nanoseconds > std.time.ns_per_s) {
            std.debug.print("{s}: never fired\n", .{what});
            return error.TestUnexpectedResult;
        }
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(1), .clock = .awake }, io);
    }
}

test "Layer: aRuntimeClassCallsItsZigMethodWithItsContext" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var c: Counter = .{};
    const obj = Target.instance(&c);
    defer objc.release(obj);
    objc.msg(void, obj, "fire:", .{@as(?objc.Id, null)});
    objc.msg(void, obj, "fire:", .{@as(?objc.Id, null)});
    try expectEqual(2, c.count.load(.acquire));
    // A second instance of the one registered class carries its own context.
    var d: Counter = .{};
    const other = Target.instance(&d);
    defer objc.release(other);
    objc.msg(void, other, "fire:", .{@as(?objc.Id, null)});
    try expectEqual(1, d.count.load(.acquire));
    try expectEqual(2, c.count.load(.acquire));
}

const Presented = struct {
    done: std.atomic.Value(u32) = .init(0),
    fn completed(self: *Presented, _: objc.Id) void {
        _ = self.done.fetchAdd(1, .release);
    }
};

test "Layer: aStandaloneLayerVendsADrawableAndPresentsIt" {
    const m = try harness.metal();
    defer m.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    const l = layer.MetalLayer.new();
    defer l.release();
    l.setDevice(m.device);
    l.setPixelFormat(.bgra8Unorm);
    l.setFramebufferOnly(true);
    l.setPresentsWithTransaction(false);
    l.setDrawableSize(64, 48);
    const drawable = l.nextDrawable() orelse return error.NoDrawable;
    const texture = drawable.texture();
    try expectEqual(64, texture.width());
    try expectEqual(48, texture.height());

    const cmd = m.queue.commandBuffer().?;
    const pass = mtl.RenderPassDescriptor.renderPassDescriptor();
    const a = pass.colorAttachment(0);
    a.setTexture(texture);
    a.setLoadAction(.clear);
    a.setStoreAction(.store);
    a.setClearColor(.{ .red = 1, .green = 0, .blue = 0, .alpha = 1 });
    cmd.renderCommandEncoder(pass).?.endEncoding();
    var p: Presented = .{};
    var block = objc.Block(Presented, Presented.completed).init(&p);
    cmd.addCompletedHandler(block.ptr());
    cmd.presentDrawable(drawable);
    cmd.commit();
    cmd.waitUntilCompleted();
    try harness.awaitHandler(&p.done, "present");
}

/// A thread running its own CFRunLoop with one source on it.
const LoopThread = struct {
    counter: Counter = .{},
    loop: std.atomic.Value(?cf.RunLoop) = .init(null),
    source: ?cf.RunLoopSource = null,

    fn perform(info: ?*anyopaque) callconv(.c) void {
        const self: *LoopThread = @ptrCast(@alignCast(info.?));
        self.counter.fire();
    }

    fn run(self: *LoopThread) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        var ctx: cf.RunLoopSourceContext = .{ .info = self, .perform = perform };
        const src = cf.CFRunLoopSourceCreate(null, 0, &ctx).?;
        self.source = src;
        const rl = cf.CFRunLoopGetCurrent();
        cf.CFRunLoopAddSource(rl, src, cf.kCFRunLoopDefaultMode);
        self.loop.store(rl, .release);
        cf.CFRunLoopRun();
        cf.CFRunLoopSourceInvalidate(src);
        cf.CFRelease(src);
    }

    fn awaitLoop(self: *LoopThread) cf.RunLoop {
        while (true) {
            if (self.loop.load(.acquire)) |rl| return rl;
            std.atomic.spinLoopHint();
        }
    }
};

test "Layer: aRunLoopSourceSignalledFromAnotherThreadPerformsOnTheLoopsThread" {
    var lt: LoopThread = .{};
    const t = try std.Thread.spawn(.{}, LoopThread.run, .{&lt});
    const rl = lt.awaitLoop();
    // The loop must be inside CFRunLoopRun before the signal is meaningful;
    // a signal before then is still delivered once it enters.
    cf.CFRunLoopSourceSignal(lt.source.?);
    cf.CFRunLoopWakeUp(rl);
    try awaitCount(&lt.counter, 1, "the run-loop source");
    try expect(lt.counter.thread.load(.acquire) != std.Thread.getCurrentId());
    cf.CFRunLoopStop(rl);
    t.join();
}

/// A run loop on its own thread with a display link added to it.
const LinkThread = struct {
    link: layer.DisplayLink,
    added: std.atomic.Value(bool) = .init(false),
    loop: std.atomic.Value(?cf.RunLoop) = .init(null),
    tid: std.atomic.Value(u64) = .init(0),

    fn run(self: *LinkThread) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        self.tid.store(@intCast(std.Thread.getCurrentId()), .release);
        self.link.addToCurrentRunLoop();
        self.loop.store(cf.CFRunLoopGetCurrent(), .release);
        cf.CFRunLoopRun();
    }
};

test "Layer: aDisplayLinkOnAViewInAWindowFiresOnTheThreadThatAddedIt" {
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
    // A locked session's display links never fire, the window's included.
    if (layer.screenLocked()) {
        std.debug.print("the screen is locked: display links do not fire\n", .{});
        return error.SkipZigTest;
    }
    const w = layer.Window.new(64, 48);
    defer w.close();
    w.orderFront();
    var c: Counter = .{};
    const target = Target.instance(&c);
    defer objc.release(target);
    const link = w.view().displayLink(target, "fire:");
    defer link.release();
    var lt: LinkThread = .{ .link = link };
    const t = try std.Thread.spawn(.{}, LinkThread.run, .{&lt});
    defer t.join();
    defer {
        link.invalidate();
        while (lt.loop.load(.acquire) == null) std.atomic.spinLoopHint();
        cf.CFRunLoopStop(lt.loop.load(.acquire).?);
    }
    try awaitCount(&c, 1, "the display link");
    try expectEqual(lt.tid.load(.acquire), c.thread.load(.acquire));
}
