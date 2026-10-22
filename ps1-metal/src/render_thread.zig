//! The render thread: a CFRunLoop of its own around a `FrameRenderer`. An
//! arriving frame signals a run-loop source, which executes it at once; the
//! display link (or, where there is no view, a timer) presents. Both run on
//! this one loop, so they never interleave.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const cf = @import("cf.zig");
const mtl_layer = @import("mtl_layer.zig");
const Waker = @import("waker.zig").Waker;
const FrameRenderer = @import("frame_renderer.zig").FrameRenderer;

const MetalLayer = mtl_layer.MetalLayer;
const DisplayLink = mtl_layer.DisplayLink;

/// QuartzCore's host clock in seconds: what the fades are timed against.
extern "c" fn CACurrentMediaTime() f64;

pub const RenderThread = struct {
    r: *FrameRenderer = undefined,
    layer: ?MetalLayer = null,
    link: ?DisplayLink = null,
    fallback_hz: ?f64 = null,
    thread: ?std.Thread = null,

    /// The thread's run loop, published once its source is on it. Retained:
    /// a thread's loop dies with it, and `stop` may wake it after that.
    loop: std.atomic.Value(?cf.RunLoop) = .init(null),
    source: ?cf.RunLoopSource = null,
    timer: ?cf.RunLoopTimer = null,
    /// Seen by the source's `perform`, which tears the loop down from its
    /// own thread: a display link is invalidated where it fires.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Set as the thread returns, even from a loop it never built.
    exited: std.atomic.Value(bool) = .init(false),

    /// The display link's target, carrying this thread. Owned.
    link_target: ?objc.Id = null,

    const Target = objc.TargetClass("Ps1RenderThreadTarget", RenderThread, fire);

    /// The object a display link created on the main thread calls `fire:`
    /// on. Create the link with it BEFORE `start`; it lives until `deinit`.
    pub fn target(self: *RenderThread) objc.Id {
        if (self.link_target == null) self.link_target = Target.instance(self);
        return self.link_target.?;
    }

    /// Releases the link target. After `stop`, and after whoever made the
    /// link has released it.
    pub fn deinit(self: *RenderThread) void {
        std.debug.assert(self.thread == null);
        if (self.link_target) |t| objc.release(t);
        self.link_target = null;
    }

    /// Spawns `ps1.render`. With `link` it presents on the link; else with
    /// `fallback_hz` on a timer at that rate; else it never presents and only
    /// executes. `layer` and `link` are borrowed until `stop` returns.
    pub fn start(self: *RenderThread, r: *FrameRenderer, layer: ?MetalLayer, link: ?DisplayLink, fallback_hz: ?f64) !void {
        std.debug.assert(self.thread == null);
        self.r = r;
        self.layer = layer;
        self.link = link;
        self.fallback_hz = fallback_hz;
        self.stopping.store(false, .release);
        self.exited.store(false, .release);
        self.loop.store(null, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Emulator thread: a stream or a group is in the queue. Never during or
    /// after `stop`: the emulator thread is stopped first.
    pub fn frameArrived(self: *RenderThread) void {
        // Null until the thread is up: its first pass executes whatever
        // arrived before then.
        const rl = self.loop.load(.acquire) orelse return;
        cf.CFRunLoopSourceSignal(self.source.?);
        cf.CFRunLoopWakeUp(rl);
    }

    /// `frameArrived` as the `Exchange`'s `on_published`.
    pub fn waker(self: *RenderThread) Waker {
        return .{ .ctx = self, .wake = wake };
    }

    fn wake(ctx: *anyopaque) void {
        const self: *RenderThread = @ptrCast(@alignCast(ctx));
        self.frameArrived();
    }

    /// Tears the loop down on its own thread, joins it, and answers every
    /// screenshot still queued.
    pub fn stop(self: *RenderThread) void {
        const t = self.thread orelse return;
        self.stopping.store(true, .release);
        // The thread signals its own source before it publishes the loop, so
        // a stop it has not seen yet ends its first pass. Once the loop is
        // visible, this signal does the same.
        while (self.loop.load(.acquire) == null and !self.exited.load(.acquire)) std.Thread.yield() catch {};
        self.frameArrived();
        t.join();
        self.thread = null;
        if (self.loop.swap(null, .acq_rel)) |rl| cf.CFRelease(rl);
        if (self.source) |src| cf.CFRelease(src);
        self.source = null;
        self.r.failPendingScreenshots();
    }

    fn run(self: *RenderThread) void {
        if (builtin.os.tag.isDarwin()) {
            _ = std.c.pthread_setname_np("ps1.render");
            // A late present is a visible hitch; it outranks everything but
            // the frame it shows.
            _ = std.c.pthread_set_qos_class_self_np(.USER_INTERACTIVE, 0);
        }
        defer self.exited.store(true, .release);
        const rl = cf.CFRunLoopGetCurrent();
        var ctx: cf.RunLoopSourceContext = .{ .info = self, .perform = perform };
        const src = cf.CFRunLoopSourceCreate(null, 0, &ctx) orelse {
            std.log.err("render thread: no run-loop source", .{});
            return;
        };
        // Released by `stop`, after the join: `frameArrived` may signal it
        // until then.
        self.source = src;
        cf.CFRunLoopAddSource(rl, src, cf.kCFRunLoopCommonModes);
        {
            const pool = objc.Pool.push();
            defer pool.pop();
            if (self.link) |l| {
                l.addToCurrentRunLoop();
            } else if (self.fallback_hz) |hz| {
                var tctx: cf.RunLoopTimerContext = .{ .info = self };
                const interval = 1 / hz;
                self.timer = cf.CFRunLoopTimerCreate(null, cf.CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0, timerFired, &tctx);
                if (self.timer) |tm| cf.CFRunLoopAddTimer(rl, tm, cf.kCFRunLoopCommonModes);
            }
        }
        // Whatever arrived before the loop was visible is executed on the
        // first pass; a stop requested by then ends it there.
        cf.CFRunLoopSourceSignal(src);
        _ = cf.CFRetain(rl);
        self.loop.store(rl, .release);
        cf.CFRunLoopRun();
        if (self.timer) |tm| cf.CFRelease(tm);
        self.timer = null;
    }

    fn perform(info: ?*anyopaque) callconv(.c) void {
        const self: *RenderThread = @ptrCast(@alignCast(info.?));
        const pool = objc.Pool.push();
        defer pool.pop();
        if (self.stopping.load(.acquire)) return self.tearDown();
        self.settle();
        self.r.executeArrived();
    }

    /// The display link's `fire:`.
    fn fire(self: *RenderThread) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (self.stopping.load(.acquire)) return;
        self.settle();
        self.r.executeArrived();
        self.r.present(self.layer, CACurrentMediaTime());
    }

    fn timerFired(_: cf.RunLoopTimer, info: ?*anyopaque) callconv(.c) void {
        const self: *RenderThread = @ptrCast(@alignCast(info.?));
        self.fire();
    }

    fn settle(self: *RenderThread) void {
        self.r.applySettings() catch |err| std.log.err("render settings: {t}", .{err});
    }

    fn tearDown(self: *RenderThread) void {
        if (self.link) |l| l.invalidate();
        if (self.timer) |tm| cf.CFRunLoopTimerInvalidate(tm);
        if (self.source) |s| cf.CFRunLoopSourceInvalidate(s);
        cf.CFRunLoopStop(cf.CFRunLoopGetCurrent());
    }
};
