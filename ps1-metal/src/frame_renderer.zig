//! The render thread's work, without the thread, split into its two
//! triggers. A frame ARRIVING is executed into the texture at once, whatever
//! the window is doing; a PRESENT (the display link) only shows the newest
//! picture. Settings arrive as values through `Mailbox`.

const std = @import("std");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const pi = @import("prim_instance.zig");
const display = @import("display.zig");
const screenshot = @import("screenshot.zig");
const png = @import("png.zig");
const pipelines = @import("pipelines.zig");
const live_renderer = @import("live_renderer.zig");
const mtl_layer = @import("mtl_layer.zig");
const Exchange = @import("frame_exchange.zig").Exchange;
const Display = @import("stream_queue.zig").Display;
const Lock = @import("lock.zig").Lock;

const Allocator = std.mem.Allocator;
const LiveRenderer = live_renderer.LiveRenderer;
const native_pixels = pi.native_pixels;

pub const Metal = @import("metal_context.zig").Metal;

/// Everything the frontend decides about the picture. Posted whole: the app
/// re-applies every setting every frame, and the renderer acts only on what
/// changed.
pub const Settings = struct {
    /// Internal resolution, 1...8.
    scale: u32 = 1,
    /// The EFFECTIVE PGXP depth buffer: whether `MetalVram`'s depth texture
    /// persists or is memoryless, so like `scale` it rebuilds the VRAM.
    depth_buffer: bool = false,
    dither: pi.DitherMode = pi.default_dither,
    texture_filter: pi.TextureFilter = .nearest,
    sprite_filter: pi.TextureFilter = .nearest,
    /// The view's size in points and its backing scale: the drawable is
    /// their product, in pixels.
    size_points: [2]f64 = .{ 0, 0 },
    backing_scale: f64 = 1,
    /// A hidden window still executes every frame, so the texture stays
    /// faithful and showing it again needs no resync; it only stops
    /// presenting.
    occluded: bool = false,
    /// Drives the grey-out fade.
    paused: bool = false,
    /// Whether the toolbar band shows: with the HUD.
    band_shown: bool = false,
};

/// The newest `Settings`, posted from any thread and taken on the render
/// thread. Only the newest matters, so a post overwrites an untaken one.
pub const Mailbox = struct {
    lock: Lock = .{},
    settings: Settings = .{},
    changed: bool = false,

    pub fn post(self: *Mailbox, s: Settings) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.settings = s;
        self.changed = true;
    }

    pub fn take(self: *Mailbox) ?Settings {
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.changed) return null;
        self.changed = false;
        return self.settings;
    }
};

/// The debug switches, read once by whoever builds the renderer.
pub const Debug = struct {
    /// `PS1_LIVE_DIFF`: compare the texture with the shadow every frame.
    live_diff: bool = false,
    /// `PS1_SOFTWARE_DISPLAY`: show 15bpp from the 1x shadow.
    software_display: bool = false,
    /// `PS1_LIVE_STATS`: the drain-frequency probe.
    live_stats: bool = false,
};

/// Called exactly once per request, on a Metal or render thread, with the
/// PNG valid only during the call; null when no picture could be taken.
pub const ScreenshotDone = *const fn (ctx: ?*anyopaque, png: ?[*]const u8, len: usize) callconv(.c) void;

const Request = struct { done: ScreenshotDone, ctx: ?*anyopaque };

/// More requests than this between two pictures are answered with null at
/// once: a player cannot press the key that fast.
const max_requests = 8;

/// A runahead picture is shown where its own frame displays, unless either
/// is 24-bit: that is read from the shadow, and a speculative frame
/// publishes none.
pub fn chooseDisplay(real: Display, ahead: ?Display) Display {
    const a = ahead orelse return real;
    return if (!a.depth24 and !real.depth24) a else real;
}

pub const FrameRenderer = struct {
    alloc: Allocator,
    x: *Exchange,
    /// Borrowed from the `Metal` the renderer was built with, shared with the
    /// rasterizer: commit order orders its writes before the display pass.
    cmd_queue: mtl.CommandQueue,
    band: display.Band,
    debug: Debug,
    set: pipelines.Set,
    pass: display.DisplayPass,
    live: *LiveRenderer,
    /// What `drain` adopts when no shadow was ever published: a blank VRAM,
    /// which is what the machine powers on with.
    blank: *[native_pixels]u16,

    mailbox: Mailbox = .{},
    /// The settings in force. Render thread only.
    current: Settings,
    pause_fade: display.PauseFade = .{},
    band_fade: display.DrawFade = .{ .duration = band_fade_duration },
    /// The size last given to the layer, in pixels.
    drawable_px: [2]f64 = .{ 0, 0 },
    /// Whether presents reach a layer: until one does, and while occluded,
    /// a screenshot is answered from the execute instead.
    presenting: bool = false,
    /// The last command buffer this renderer committed, retained: the queue
    /// completes in order, so waiting on it waits for every one before it.
    last_cmd: ?mtl.CommandBuffer = null,

    requests_lock: Lock = .{},
    requests: [max_requests]Request = undefined,
    request_count: usize = 0,
    /// Screenshot completion blocks not yet finished. The one piece of the
    /// renderer a block touches, and its LAST touch, so `deinit` can wait.
    shots_in_flight: std.atomic.Value(u32) = .init(0),

    /// Frames shown. For the tests, which read it from another thread.
    presented: std.atomic.Value(u64) = .init(0),

    /// The HUD's own fade (`ToolbarBand.duration`).
    const band_fade_duration = 0.25;

    /// Builds the pipelines and the display pass once, and the live renderer
    /// at `initial`'s scale and depth buffer.
    pub fn init(alloc: Allocator, m: Metal, x: *Exchange, band: display.Band, debug: Debug, initial: Settings) !*FrameRenderer {
        const self = try alloc.create(FrameRenderer);
        errdefer alloc.destroy(self);
        const blank = try alloc.create([native_pixels]u16);
        errdefer alloc.destroy(blank);
        @memset(blank, 0);
        self.* = .{
            .alloc = alloc,
            .x = x,
            .cmd_queue = m.queue,
            .band = band,
            .debug = debug,
            .set = try m.buildPipelines(),
            .pass = undefined,
            .live = undefined,
            .blank = blank,
            .current = initial,
        };
        errdefer self.set.deinit();
        self.pass = try display.DisplayPass.init(m.device, m.lib);
        errdefer self.pass.deinit();
        self.live = try LiveRenderer.init(alloc, m, &self.set, initial.scale, initial.depth_buffer, .{
            .diff = debug.live_diff,
            .stats = debug.live_stats,
        });
        self.applyFilters(initial);
        return self;
    }

    /// Waits for every command buffer and screenshot block in flight, then
    /// frees. A request still queued is answered with null.
    pub fn deinit(self: *FrameRenderer) void {
        self.failPendingScreenshots();
        if (self.last_cmd) |c| {
            c.waitUntilCompleted();
            c.release();
        }
        // A completed handler can still be running after the wait.
        while (self.shots_in_flight.load(.acquire) != 0) std.Thread.yield() catch {};
        self.live.deinit();
        self.pass.deinit();
        self.set.deinit();
        self.alloc.destroy(self.blank);
        self.alloc.destroy(self);
    }

    /// Takes the mailbox. A scale or depth change rebuilds the VRAM and
    /// raises the resync from HERE, the queue's only consumer: a blank
    /// texture under an incremental stream is the bug behind Crash 1's level
    /// vanishing. On a failed rebuild the old scale and depth stay in force.
    pub fn applySettings(self: *FrameRenderer) !void {
        var s = self.mailbox.take() orelse return;
        self.applyFilters(s);
        if (s.scale != self.current.scale or s.depth_buffer != self.current.depth_buffer) {
            self.live.rebuildVram(s.scale, s.depth_buffer) catch |err| {
                s.scale = self.current.scale;
                s.depth_buffer = self.current.depth_buffer;
                self.current = s;
                return err;
            };
            self.x.queue.requestResync();
        }
        self.current = s;
    }

    fn applyFilters(self: *FrameRenderer, s: Settings) void {
        const r = &self.live.rasterizer;
        r.dither_mode = s.dither;
        r.texture_filter = s.texture_filter;
        r.sprite_filter = s.sprite_filter;
    }

    /// Executes every queued frame, in order, occluded or not. Answers the
    /// screenshots when no present will.
    pub fn executeArrived(self: *FrameRenderer) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const q = self.x.queue;
        // The producer publishes a shadow ahead of any stream while a resync
        // or a drop is pending, so with none yet there is nothing to adopt,
        // and clearing the request now would let the first frame execute
        // onto a blank texture.
        const adoptable = self.x.acquireShadow() != null or !(q.needsResync() or q.hasDroppedFrames());
        if (adoptable) {
            var source: ShadowSource = .{ .x = self.x, .blank = self.blank };
            self.live.drain(q, &source);
            if (self.debug.live_diff) self.diffAgainstShadow();
        }
        if (!self.presenting or self.current.occluded) self.takeScreenshots();
    }

    /// Shows the newest picture: nothing when occluded or without a layer.
    pub fn present(self: *FrameRenderer, layer: ?mtl_layer.MetalLayer, now_s: f64) void {
        if (self.current.occluded) return;
        const l = layer orelse {
            self.presenting = false;
            return;
        };
        self.presenting = true;
        const pool = objc.Pool.push();
        defer pool.pop();

        const s = self.current;
        const size_px: [2]f64 = .{ s.size_points[0] * s.backing_scale, s.size_points[1] * s.backing_scale };
        if (size_px[0] > 0 and size_px[1] > 0 and !std.meta.eql(size_px, self.drawable_px)) {
            l.setContentsScale(s.backing_scale);
            l.setDrawableSize(size_px[0], size_px[1]);
            self.drawable_px = size_px;
        }
        const drawable = l.nextDrawable() orelse return;
        const cmd = self.cmd_queue.commandBuffer() orelse return;

        var p = self.pictureParams();
        p.saturation = self.pause_fade.saturation(s.paused, now_s);
        const box = display.letterboxScale(self.drawable_px[0], self.drawable_px[1]);
        p.scale_x = box.x;
        p.scale_y = box.y;
        display.applyBand(&p, self.band, self.band_fade.eased(s.band_shown, now_s), self.drawable_px, s.size_points);

        if (!self.pass.encode(cmd, drawable.texture(), self.live.vram.texture, self.live.vram.sidecar, p)) return;
        self.encodeScreenshots(cmd, p);
        cmd.presentDrawable(drawable);
        self.commit(cmd);
        _ = self.presented.fetchAdd(1, .monotonic);
    }

    /// Any thread. Answered by the next picture taken.
    pub fn requestScreenshot(self: *FrameRenderer, done: ScreenshotDone, ctx: ?*anyopaque) void {
        self.requests_lock.lock();
        if (self.request_count == max_requests) {
            self.requests_lock.unlock();
            done(ctx, null, 0);
            return;
        }
        self.requests[self.request_count] = .{ .done = done, .ctx = ctx };
        self.request_count += 1;
        self.requests_lock.unlock();
    }

    /// Answers every queued request with null.
    pub fn failPendingScreenshots(self: *FrameRenderer) void {
        var taken: [max_requests]Request = undefined;
        for (self.takeRequests(&taken)) |r| r.done(r.ctx, null, 0);
    }

    fn takeRequests(self: *FrameRenderer, out: *[max_requests]Request) []Request {
        self.requests_lock.lock();
        defer self.requests_lock.unlock();
        const n = self.request_count;
        @memcpy(out[0..n], self.requests[0..n]);
        self.request_count = 0;
        return out[0..n];
    }

    /// The display the picture is drawn from, with the shadow uploaded where
    /// it is read: per-draw values (letterbox, fades, band) at their defaults.
    fn pictureParams(self: *FrameRenderer) display.Params {
        const d = chooseDisplay(self.x.newestDisplay(), self.live.present_display);
        var p = display.paramsFor(d);
        p.software_display = @intFromBool(self.debug.software_display);
        // Read off the renderer, not a second stored copy: the uniform and
        // the texture it addresses cannot drift apart.
        p.scale = self.live.vram.scale;
        // Only the two paths that READ it pay the 1 MB upload.
        if (d.depth24 or self.debug.software_display) {
            if (self.x.acquireShadow()) |shadow| self.pass.uploadShadow(shadow.pixels);
        }
        return p;
    }

    /// A screenshot without a present: its own command buffer.
    fn takeScreenshots(self: *FrameRenderer) void {
        if (self.pendingRequests() == 0) return;
        const cmd = self.cmd_queue.commandBuffer() orelse return self.failPendingScreenshots();
        self.encodeScreenshots(cmd, self.pictureParams());
        self.commit(cmd);
    }

    /// Requests no picture has answered yet.
    pub fn pendingRequests(self: *FrameRenderer) usize {
        self.requests_lock.lock();
        defer self.requests_lock.unlock();
        return self.request_count;
    }

    /// Draws the picture once more, unletterboxed at the internal
    /// resolution, for every request queued, answered when the GPU is done.
    fn encodeScreenshots(self: *FrameRenderer, cmd: mtl.CommandBuffer, p: display.Params) void {
        var taken: [max_requests]Request = undefined;
        const requests = self.takeRequests(&taken);
        if (requests.len == 0) return;
        const shot = self.alloc.create(Shot) catch return answerAll(requests, null);
        const s = screenshot.size(p.height, p.scale, p.enabled != 0);
        const target = screenshot.encode(cmd, &self.pass, self.live.vram.texture, self.live.vram.sidecar, p, s) orelse {
            self.alloc.destroy(shot);
            return answerAll(requests, null);
        };
        shot.* = .{ .alloc = self.alloc, .target = target, .in_flight = &self.shots_in_flight };
        @memcpy(shot.requests[0..requests.len], requests);
        shot.count = requests.len;
        _ = self.shots_in_flight.fetchAdd(1, .acq_rel);
        // The literal lives for this call only; the command buffer copies it.
        var block = objc.Block(Shot, Shot.completed).init(shot);
        cmd.addCompletedHandler(block.ptr());
    }

    fn commit(self: *FrameRenderer, cmd: mtl.CommandBuffer) void {
        cmd.commit();
        if (self.last_cmd) |c| c.release();
        self.last_cmd = cmd.retain();
    }

    /// `PS1_LIVE_DIFF`: the texture against the shadow it last executed to.
    fn diffAgainstShadow(self: *FrameRenderer) void {
        const shadow = self.x.heldShadow() orelse return;
        var src: DiffSource = .{ .pixels_ = shadow.pixels };
        if (self.live.diff(shadow.seq, &src)) |report| std.debug.print("{f}\n", .{report});
    }
};

fn answerAll(requests: []const Request, file: ?[]const u8) void {
    for (requests) |r| {
        if (file) |f| r.done(r.ctx, f.ptr, f.len) else r.done(r.ctx, null, 0);
    }
}

/// `drain`'s shadow source: the newest the producer published.
const ShadowSource = struct {
    x: *Exchange,
    blank: *const [native_pixels]u16,

    pub fn sample(self: *ShadowSource) live_renderer.Shadow {
        return self.x.acquireShadow() orelse .{ .pixels = self.blank, .depth = null, .seq = 0 };
    }
};

const DiffSource = struct {
    pixels_: *const [native_pixels]u16,

    pub fn pixels(self: *DiffSource) *const [native_pixels]u16 {
        return self.pixels_;
    }
};

/// What a screenshot's completion block owns: its target texture and its
/// requests. Nothing in it points into the renderer but the in-flight
/// count, which it touches last.
const Shot = struct {
    alloc: Allocator,
    target: mtl.Texture,
    requests: [max_requests]Request = undefined,
    count: usize = 0,
    in_flight: *std.atomic.Value(u32),

    fn completed(self: *Shot, _: objc.Id) void {
        const requests = self.requests[0..self.count];
        const file = self.encode();
        answerAll(requests, file);
        if (file) |f| self.alloc.free(f);
        self.target.release();
        const in_flight = self.in_flight;
        self.alloc.destroy(self);
        _ = in_flight.fetchSub(1, .acq_rel);
    }

    fn encode(self: *Shot) ?[]u8 {
        const w = self.target.width();
        const h = self.target.height();
        const bgra = self.alloc.alloc(u8, w * h * 4) catch return null;
        defer self.alloc.free(bgra);
        screenshot.bytes(self.target, bgra);
        return png.encode(self.alloc, bgra, @intCast(w), @intCast(h), @intCast(w * 4)) catch null;
    }
};
