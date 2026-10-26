//! One running game: the machine, the emulator thread, the render thread,
//! the audio output and the memory cards, owned together and torn down in
//! the one order that loses nothing.
//!
//! `create` builds everything and starts nothing; `start` reads the cards
//! and starts the threads. The split is what keeps the app's ordering: build
//! the new game, free the old session (which FLUSHES its cards), then start
//! the new one, which READS them.
//!
//! Every setter is an atomic store or a mailbox post followed by a pacer
//! bump; every request is queued. Only the emulator thread calls the machine.

const std = @import("std");
const capi = @import("ps1_capi");
const metal = @import("ps1_metal");
const machine = @import("machine.zig");
const cards = @import("cards.zig");
const coreaudio = @import("coreaudio.zig");
const pacing = @import("pacing.zig");
const requests = @import("requests.zig");
const AudioRing = @import("audio_ring.zig").AudioRing;
const Mixer = @import("mixer.zig").Mixer;
const RunLoop = @import("run_loop.zig").RunLoop;
const EmulatorThread = @import("emulator_thread.zig").EmulatorThread;
const VramHost = @import("vram_host.zig").VramHost;

const Allocator = std.mem.Allocator;
const HandleMachine = machine.HandleMachine;
const Exchange = metal.frame_exchange.Exchange;
const Display = metal.stream_queue.Display;
const FrameRenderer = metal.frame_renderer.FrameRenderer;
const RenderSettings = metal.frame_renderer.Settings;
const RenderThread = metal.render_thread.RenderThread;
const Metal = metal.metal_context.Metal;
const layer = metal.mtl_layer;
const pi = metal.prim_instance;
const objc = metal.objc;
const Lock = metal.lock.Lock;
const Pacer = metal.waker.Pacer;
const PacerWake = metal.waker.PacerWake;
const log = std.log.scoped(.session);

pub const DiscBytes = machine.DiscBytes;
pub const Engine = machine.Engine;
pub const Pgxp = machine.Pgxp;
pub const ScreenshotDone = metal.frame_renderer.ScreenshotDone;

pub const Error = machine.Error || error{ NoMetal, Audio, Thread };

pub const Config = struct {
    bios: []const u8,
    /// Null boots the BIOS shell.
    disc: ?DiscBytes = null,
    resume_state: ?[]const u8 = null,
    card_dir: []const u8,
    /// The NSView the picture goes on, or null for a session that presents
    /// nowhere. With a view, `create` and `destroy` run on the main thread.
    view: ?objc.Id = null,
    band: metal.display.Band = .{ .height = 0, .edge = 0, .sigma = 0 },
    engine: Engine = .interpreter,
    fast_boot: bool = false,
    audio: Audio = .core_audio,
    /// Where the machine's VRAM lives. `create` turns it to `.gpu` when
    /// `PS1_GPU_VRAM` is set; the field is the tests' way in.
    vram: capi.VramMode = .dual,
};

pub const Audio = enum {
    core_audio,
    /// Nothing drains the ring: a test pulls the mixer by hand.
    none,
    /// An output that refuses to start, as one whose device vanished
    /// between `create` and `start` does: the tests' way to reach that path.
    refusing,
};

const Output = union(Audio) {
    core_audio: coreaudio.Output,
    none,
    refusing,
};

pub const Session = struct {
    alloc: Allocator,
    /// The session's own `Io`, single-threaded as the handle's is, so no
    /// signal handlers are installed in the host app.
    io_impl: std.Io.Threaded = .init_single_threaded,
    gpu: Metal,
    m: HandleMachine,
    x: *Exchange,
    ring: AudioRing,
    mixer: Mixer,
    loop: *RunLoop(HandleMachine),
    store: cards.CardStore,
    pacer: Pacer = .{},
    pacer_wake: PacerWake = undefined,
    renderer: *FrameRenderer,
    render_thread: RenderThread = .{},
    emulator: EmulatorThread(HandleMachine) = .{},
    output: Output,
    output_started: bool = false,
    /// GPU-only's answer to the machine's reads; null under dual.
    vram_host: ?VramHost = null,
    live_stats: bool = false,

    view: ?layer.View = null,
    metal_layer: ?layer.MetalLayer = null,
    link: ?layer.DisplayLink = null,

    /// The renderer's settings as the setters last left them, posted whole.
    settings_lock: Lock = .{},
    settings: RenderSettings = .{},

    pub fn create(alloc: Allocator, cfg: Config) Error!*Session {
        const self = try alloc.create(Session);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .gpu = undefined,
            .m = undefined,
            .x = undefined,
            .ring = undefined,
            .mixer = undefined,
            .loop = undefined,
            .store = cards.CardStore.open(cfg.card_dir),
            .renderer = undefined,
            .output = switch (cfg.audio) {
                .core_audio => .{ .core_audio = .{} },
                .none => .none,
                .refusing => .refusing,
            },
        };
        const io = self.io_impl.io();

        // The machine first: a disc or a resume state it refuses is the
        // likeliest failure, and nothing else is built for it.
        const vram: capi.VramMode = if (env("PS1_GPU_VRAM")) .gpu else cfg.vram;
        if (vram == .gpu) log.info("session: GPU-only VRAM (PS1_GPU_VRAM)", .{});
        self.m = try HandleMachine.boot(cfg.bios, .{ .engine = cfg.engine, .fast_boot = cfg.fast_boot, .vram = vram });
        errdefer self.m.destroy();
        if (cfg.disc) |d| try self.m.loadDisc(d);
        if (cfg.resume_state) |state| try self.m.loadState(state);

        self.gpu = Metal.open() catch return error.NoMetal;
        errdefer self.gpu.deinit();
        self.x = try Exchange.init(alloc);
        errdefer self.x.deinit();
        self.ring = try AudioRing.init(alloc, pacing.ring_capacity);
        errdefer self.ring.deinit();
        self.mixer = Mixer.init(&self.ring);
        self.loop = try RunLoop(HandleMachine).create(alloc, io, &self.m, self.x, &self.ring, &self.store);
        errdefer self.loop.destroy();
        self.loop.current_disc = cfg.disc;
        // Already on the machine: the run loop must not switch it back to
        // the default on its first pass.
        self.loop.controls.engine.store(@backingInt(cfg.engine), .release);

        const debug: metal.frame_renderer.Debug = .{
            .live_diff = env("PS1_LIVE_DIFF"),
            .software_display = env("PS1_SOFTWARE_DISPLAY"),
            .live_stats = env("PS1_LIVE_STATS"),
        };
        self.loop.controls.shadow_every_frame = debug.live_diff or debug.software_display;
        self.live_stats = debug.live_stats;
        self.renderer = FrameRenderer.init(alloc, self.gpu, self.x, cfg.band, debug, .{}) catch return error.NoMetal;
        errdefer self.renderer.deinit();

        if (vram == .gpu) {
            self.loop.controls.gpu_vram = true;
            self.x.queue.lossless = true;
            self.vram_host = try VramHost.init(alloc, self.x.queue, &self.render_thread, &self.pacer, io, &self.loop.seq);
            self.m.setVramHost(self.vram_host.?.host());
            self.loop.captures = &self.renderer.live.captures;
        }
        errdefer if (self.vram_host) |*vh| {
            self.m.setVramHost(null);
            vh.deinit(alloc);
        };

        // Wired before either thread exists: every waker is set once.
        self.pacer_wake = .{ .pacer = &self.pacer, .io = io };
        self.mixer.drained = self.pacer_wake.waker();
        self.x.queue.on_drained = self.pacer_wake.waker();
        self.x.on_published = self.render_thread.waker();

        if (cfg.view) |v| self.installLayer(.{ .id = v });
        return self;
    }

    /// The layer on the view and the display link made with it. Main
    /// thread: AppKit's.
    fn installLayer(self: *Session, view: layer.View) void {
        std.debug.assert(layer.onMainThread());
        const pool = objc.Pool.push();
        defer pool.pop();
        const l = layer.MetalLayer.new();
        l.setDevice(self.gpu.device);
        l.setPixelFormat(.bgra8Unorm);
        l.setFramebufferOnly(true);
        l.setPresentsWithTransaction(false);
        view.setWantsLayer(true);
        view.setLayer(l);
        self.view = view;
        self.metal_layer = l;
        self.link = view.displayLink(self.render_thread.target(), "fire:");
    }

    /// Re-installs both cards from disk, then starts the output, the render
    /// thread and the emulator thread. A failure stops whatever started, in
    /// reverse, and leaves a session that can still be destroyed.
    pub fn start(self: *Session) Error!void {
        self.loop.reinstallMemoryCards();
        self.loop.publishPadStatus();
        // Before either thread: the queue starts asking for a resync and the
        // renderer drains nothing until a shadow exists, so a GPU-only
        // machine's first readback would wait forever on a texture nobody
        // has pushed. With a resume state this is the loaded VRAM.
        if (self.loop.controls.gpu_vram) self.loop.machineReplaced();
        self.startOutput() catch return error.Audio;
        errdefer self.stopOutput();
        self.render_thread.start(self.renderer, self.metal_layer, self.link, null) catch return error.Thread;
        errdefer self.render_thread.stop();
        self.emulator.start(self.loop, &self.pacer, self.io_impl.io()) catch return error.Thread;
    }

    fn startOutput(self: *Session) coreaudio.Error!void {
        switch (self.output) {
            .core_audio => |*o| {
                try o.init(&self.mixer);
                o.start() catch |err| {
                    o.stop();
                    return err;
                };
            },
            .none => {},
            .refusing => return error.OsStatus,
        }
        self.output_started = true;
    }

    fn stopOutput(self: *Session) void {
        if (!self.output_started) return;
        switch (self.output) {
            .core_audio => |*o| o.stop(),
            .none, .refusing => {},
        }
        self.output_started = false;
    }

    /// Output, emulator thread (joined, then every request answered and the
    /// cards flushed), render thread (joined, its screenshots answered), the
    /// renderer, the layer, the disc, the machine. Nothing a completion
    /// touches outlives this call, and no completion runs after it.
    ///
    /// The emulator thread is joined BEFORE the render thread stops, and a
    /// GPU-only machine relies on it: a flush or a readback inside a frame
    /// is waiting on the renderer, which keeps draining until the join.
    pub fn destroy(self: *Session) void {
        self.stopOutput();
        self.emulator.shutdown();
        // A session that never started has no thread to have answered them.
        self.loop.failPendingRequests();
        // After the join, before the renderer: the ring is the renderer's.
        if (self.loop.captures) |ring| self.loop.rewind_vram.abandon(ring);
        if (self.vram_host) |*vh| {
            if (self.live_stats) self.logVramStats();
            self.m.setVramHost(null);
            vh.deinit(self.alloc);
        }
        self.render_thread.stop();
        self.renderer.deinit();
        if (self.link) |l| {
            l.invalidate();
            l.release();
        }
        if (self.metal_layer) |l| {
            std.debug.assert(layer.onMainThread());
            if (self.view) |v| v.removeLayer();
            l.release();
        }
        self.render_thread.deinit();
        if (self.loop.current_disc) |d| d.releaseBin();
        self.m.destroy();
        self.loop.destroy();
        self.ring.deinit();
        self.x.deinit();
        self.gpu.deinit();
        self.alloc.destroy(self);
    }

    fn logVramStats(self: *Session) void {
        const st = self.m.vramStats();
        log.info("[live-stats] GPU-only VRAM: reads={d} stale={d} unserved={d} flushes={d} lost={d}", .{
            st.reads, st.stale_reads, st.unserved_reads, st.flushes, self.x.queue.lost_lossless.load(.monotonic),
        });
    }

    fn bump(self: *Session) void {
        self.pacer.bump(self.io_impl.io());
    }

    // MARK: Setters

    /// Active low, as the pad reports it.
    pub fn setButtons(self: *Session, mask: u16) void {
        self.loop.controls.buttons.store(mask, .release);
        self.bump();
    }

    pub fn setSticks(self: *Session, lx: u8, ly: u8, rx: u8, ry: u8) void {
        const packed_sticks = @as(u32, lx) | @as(u32, ly) << 8 | @as(u32, rx) << 16 | @as(u32, ry) << 24;
        self.loop.controls.sticks.store(packed_sticks, .release);
        self.bump();
    }

    pub fn pressAnalogButton(self: *Session) void {
        self.loop.controls.pressAnalogButton();
        self.bump();
    }

    /// 1 to `pacing.max_speed`, to the run loop and the mixer both.
    pub fn setSpeed(self: *Session, n: u32) void {
        const speed = std.math.clamp(n, 1, pacing.max_speed);
        self.loop.setSpeed(speed);
        self.mixer.setSpeed(speed);
        self.bump();
    }

    /// Also the renderer's, for the grey-out.
    pub fn setPaused(self: *Session, paused: bool) void {
        self.loop.controls.paused.store(paused, .release);
        const s = self.lockSettings();
        s.paused = paused;
        self.postSettings();
        self.bump();
    }

    pub fn setRewinding(self: *Session, on: bool) void {
        self.loop.controls.rewinding.store(on, .release);
        self.bump();
    }

    /// The machine's PGXP first, then the renderer's depth plane: the
    /// emulator thread must publish the depth with every shadow before the
    /// renderer rebuilds a VRAM that adopts one.
    pub fn setPgxp(self: *Session, p: Pgxp) void {
        self.loop.controls.setPgxp(p);
        const s = self.lockSettings();
        s.depth_buffer = p.enabled and p.depth_buffer;
        self.postSettings();
        self.bump();
    }

    pub fn setVertexCache(self: *Session, on: bool) void {
        self.loop.controls.vertex_cache.store(on, .release);
        self.bump();
    }

    pub fn setEngine(self: *Session, e: Engine) void {
        self.loop.controls.engine.store(@backingInt(e), .release);
        self.bump();
    }

    pub fn setRewindBudget(self: *Session, bytes: usize) void {
        self.loop.controls.rewind_budget.store(bytes, .release);
        self.bump();
    }

    pub fn setRunahead(self: *Session, frames: u32) void {
        self.loop.controls.runahead.store(frames, .release);
        self.bump();
    }

    pub fn setGain(self: *Session, g: f32) void {
        self.mixer.setGain(g);
    }

    pub fn setDither(self: *Session, d: pi.DitherMode) void {
        const s = self.lockSettings();
        s.dither = d;
        self.postSettings();
    }

    pub fn setTextureFilter(self: *Session, f: pi.TextureFilter) void {
        const s = self.lockSettings();
        s.texture_filter = f;
        self.postSettings();
    }

    pub fn setSpriteFilter(self: *Session, f: pi.TextureFilter) void {
        const s = self.lockSettings();
        s.sprite_filter = f;
        self.postSettings();
    }

    /// 1 to 8.
    pub fn setScale(self: *Session, scale: u32) void {
        const s = self.lockSettings();
        s.scale = std.math.clamp(scale, 1, 8);
        self.postSettings();
    }

    pub fn setSize(self: *Session, width_pt: f64, height_pt: f64, backing_scale: f64) void {
        const s = self.lockSettings();
        s.size_points = .{ width_pt, height_pt };
        s.backing_scale = backing_scale;
        self.postSettings();
    }

    pub fn setOccluded(self: *Session, occluded: bool) void {
        const s = self.lockSettings();
        s.occluded = occluded;
        self.postSettings();
    }

    pub fn setBandShown(self: *Session, shown: bool) void {
        const s = self.lockSettings();
        s.band_shown = shown;
        self.postSettings();
    }

    /// One field changed, the whole value posted: the mailbox keeps only the
    /// newest, so two setters racing must not each post half. Held from
    /// here until `postSettings`.
    fn lockSettings(self: *Session) *RenderSettings {
        self.settings_lock.lock();
        return &self.settings;
    }

    fn postSettings(self: *Session) void {
        self.renderer.mailbox.post(self.settings);
        self.settings_lock.unlock();
    }

    // MARK: Requests

    pub fn requestSave(self: *Session, done: requests.SaveDone, ctx: ?*anyopaque) void {
        self.loop.requests.addSave(done, ctx);
        self.bump();
    }

    /// Copies `state`.
    pub fn requestLoad(self: *Session, state: []const u8, done: requests.LoadDone, ctx: ?*anyopaque) void {
        const copy = self.alloc.dupe(u8, state) catch {
            done(ctx, capi.PS1_ERR_OOM, &[0]u8{}, 0);
            return;
        };
        self.loop.requests.addLoad(copy, self.alloc, done, ctx);
        self.bump();
    }

    pub fn requestReset(self: *Session, done: requests.Done, ctx: ?*anyopaque) void {
        self.loop.requests.addReset(done, ctx);
        self.bump();
    }

    /// `disc.bin` is borrowed until its `release` is called: when it is
    /// replaced, refused, superseded or the session ends.
    pub fn requestSwap(self: *Session, disc: DiscBytes, done: requests.Done, ctx: ?*anyopaque) void {
        self.loop.requests.setSwap(disc, done, ctx);
        self.bump();
    }

    pub fn requestScreenshot(self: *Session, done: ScreenshotDone, ctx: ?*anyopaque) void {
        self.renderer.requestScreenshot(done, ctx);
    }

    // MARK: Counters

    pub fn framesProduced(self: *const Session) u64 {
        return self.x.frames_produced.load(.acquire);
    }

    /// Analog in bit 0, the small motor in bits 8-15, the large in 16-23.
    pub fn padStatus(self: *const Session) u32 {
        return self.loop.pad_status.load(.acquire);
    }

    /// The pad's two motor bytes: small, then large.
    pub fn motor(self: *const Session) [2]u8 {
        const p = self.padStatus();
        return .{ @truncate(p >> 8), @truncate(p >> 16) };
    }

    pub fn cardWrites(self: *const Session) u64 {
        return self.loop.card_writes.load(.acquire);
    }

    /// As `RewindInfo.seconds`: the frames the history covers, at 60 Hz.
    pub fn rewindSeconds(self: *const Session) f64 {
        return @as(f64, @floatFromInt(self.loop.rewind_frames.load(.acquire))) / 60;
    }

    pub fn newestDisplay(self: *Session) Display {
        return self.x.newestDisplay();
    }
};

/// A debug switch, read once: set and not "0".
fn env(name: [:0]const u8) bool {
    const v = std.c.getenv(name) orelse return false;
    return !std.mem.eql(u8, std.mem.span(v), "0");
}
