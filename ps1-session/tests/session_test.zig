//! One session end to end: a zeroed BIOS, no audio device (`audio = .none`,
//! the mixer pulled by hand), no view, the renderer presenting nowhere. It
//! needs Metal, so it runs under `zig build test-metal`.

const std = @import("std");
const session = @import("ps1_session");
const metal = @import("ps1_metal");

const capi = session.capi;
const cards = session.cards;
const Session = session.session.Session;
const Config = session.session.Config;
const DiscBytes = session.session.DiscBytes;

const alloc = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const zero_bios: [512 * 1024]u8 = @splat(0);
/// Enough sectors for the single-track fallback to read as a disc.
const zero_bin: [2352 * 32]u8 = @splat(0);

/// A session, or a skip where there is no GPU.
fn make(cfg: Config) !*Session {
    return Session.create(alloc, cfg) catch |err| switch (err) {
        error.NoMetal => {
            std.debug.print("no Metal device\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn headless(card_dir: []const u8) Config {
    return .{ .bios = &zero_bios, .card_dir = card_dir, .audio = .none };
}

/// Polls `done` for up to two seconds, pulling the mixer as the output
/// callback would so the emulator thread never parks on a full ring.
fn until(s: *Session, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool, what: []const u8) !void {
    var left: [512]f32 = undefined;
    var right: [512]f32 = undefined;
    const t0 = std.Io.Clock.awake.now(io);
    while (!done(ctx)) {
        if (t0.untilNow(io, .awake).nanoseconds > 2 * std.time.ns_per_s) {
            std.debug.print("{s}: not within 2 s\n", .{what});
            return error.TestUnexpectedResult;
        }
        s.mixer.pull(&left, &right);
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(1), .clock = .awake }, io);
    }
}

fn ranFrames(s: *Session) bool {
    return s.framesProduced() > 3;
}

/// A temporary card directory, deleted afterwards.
const CardDir = struct {
    tmp: std.testing.TmpDir,
    buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init() !CardDir {
        var self: CardDir = .{ .tmp = std.testing.tmpDir(.{}) };
        self.len = (try std.fmt.bufPrint(&self.buf, ".zig-cache/tmp/{s}/cards", .{self.tmp.sub_path})).len;
        return self;
    }

    fn path(self: *const CardDir) []const u8 {
        return self.buf[0..self.len];
    }

    fn deinit(self: *CardDir) void {
        self.tmp.cleanup();
    }
};

test "Session: aSessionStartsRunsAndStops" {
    var dir = try CardDir.init();
    defer dir.deinit();
    const s = try make(headless(dir.path()));
    defer s.destroy();
    try s.start();
    try until(s, s, ranFrames, "frames produced");
    try expect(s.framesProduced() > 0);
}

/// What one completion saw, and whether it ran after `destroy` returned.
const Answer = struct {
    count: std.atomic.Value(u32) = .init(0),
    code: std.atomic.Value(i32) = .init(1),
    bytes: ?[]u8 = null,
    destroyed: *const std.atomic.Value(bool),
    late: std.atomic.Value(bool) = .init(false),

    fn record(self: *Answer, code: i32, data: ?[]const u8) void {
        if (self.destroyed.load(.acquire)) self.late.store(true, .release);
        if (data) |d| {
            if (self.bytes) |old| alloc.free(old);
            self.bytes = alloc.dupe(u8, d) catch null;
        }
        self.code.store(code, .release);
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    fn save(ctx: ?*anyopaque, code: i32, state: [*]const u8, len: usize, _: ?[*]const u8, _: usize) callconv(.c) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        self.record(code, if (len > 0) state[0..len] else null);
    }

    fn load(ctx: ?*anyopaque, code: i32, undo: [*]const u8, len: usize) callconv(.c) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        self.record(code, if (len > 0) undo[0..len] else null);
    }

    fn simple(ctx: ?*anyopaque, code: i32) callconv(.c) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        self.record(code, null);
    }

    fn screenshot(ctx: ?*anyopaque, png: ?[*]const u8, len: usize) callconv(.c) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        self.record(if (png != null) capi.PS1_OK else capi.PS1_ERR_SESSION_STOPPED, if (png) |p| p[0..len] else null);
    }

    fn answered(self: *Answer) bool {
        return self.count.load(.acquire) > 0;
    }

    fn deinit(self: *Answer) void {
        if (self.bytes) |b| alloc.free(b);
    }
};

test "Session: aSaveRequestRoundTripsThroughALoad" {
    var dir = try CardDir.init();
    defer dir.deinit();
    const s = try make(headless(dir.path()));
    defer s.destroy();
    try s.start();
    const never: std.atomic.Value(bool) = .init(false);
    var saved: Answer = .{ .destroyed = &never };
    defer saved.deinit();
    s.requestSave(Answer.save, &saved);
    try until(s, &saved, Answer.answered, "the save");
    try expectEqual(capi.PS1_OK, saved.code.load(.acquire));
    const state = saved.bytes orelse return error.NoState;

    var loaded: Answer = .{ .destroyed = &never };
    defer loaded.deinit();
    s.requestLoad(state, Answer.load, &loaded);
    try until(s, &loaded, Answer.answered, "the load");
    try expectEqual(capi.PS1_OK, loaded.code.load(.acquire));
    // The undo state: the machine the load replaced.
    try expect(loaded.bytes != null);
}

test "Session: freeingASessionAnswersEveryRequestExactlyOnce" {
    var dir = try CardDir.init();
    defer dir.deinit();
    const s = try make(headless(dir.path()));
    var destroyed: std.atomic.Value(bool) = .init(false);
    var save: Answer = .{ .destroyed = &destroyed };
    defer save.deinit();
    var load: Answer = .{ .destroyed = &destroyed };
    defer load.deinit();
    var shot: Answer = .{ .destroyed = &destroyed };
    defer shot.deinit();
    var reset: Answer = .{ .destroyed = &destroyed };
    defer reset.deinit();
    s.setPaused(true);
    try s.start();
    s.requestSave(Answer.save, &save);
    s.requestLoad(&.{ 1, 2, 3 }, Answer.load, &load);
    s.requestScreenshot(Answer.screenshot, &shot);
    s.requestReset(Answer.simple, &reset);
    s.destroy();
    destroyed.store(true, .release);
    for ([_]*Answer{ &save, &load, &shot, &reset }) |a| {
        try expectEqual(1, a.count.load(.acquire));
        try expect(!a.late.load(.acquire));
    }
}

test "Session: aFailedAudioStartLeavesNoThreadAndFreesCleanly" {
    var dir = try CardDir.init();
    defer dir.deinit();
    var cfg = headless(dir.path());
    cfg.audio = .refusing;
    const s = try make(cfg);
    defer s.destroy();
    try std.testing.expectError(error.Audio, s.start());
    try expect(s.emulator.thread == null);
    try expect(s.render_thread.thread == null);
    try expect(!s.output_started);
}

test "Session: startReadsTheCardsCreateDoesNot" {
    var dir = try CardDir.init();
    defer dir.deinit();
    const s = try make(headless(dir.path()));
    defer s.destroy();
    // Written after `create`, as the outgoing session's flush would be.
    const store = cards.CardStore.open(dir.path());
    var image: [cards.bytes]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    try expect(store.write(io, 0, &image));
    // Paused, so the machine never runs a frame that could touch the card.
    s.setPaused(true);
    try s.start();
    const installed = s.m.h.bus.sio.getMemoryCardData(0);
    try expect(std.mem.eql(u8, installed, &image));
}

const Release = struct {
    count: std.atomic.Value(u32) = .init(0),

    fn release(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Release = @ptrCast(@alignCast(ctx.?));
        _ = self.count.fetchAdd(1, .acq_rel);
    }
};

test "Session: theDiscIsReleasedOnSwapAndOnFree" {
    var dir = try CardDir.init();
    defer dir.deinit();
    var first: Release = .{};
    var second: Release = .{};
    var cfg = headless(dir.path());
    cfg.disc = .{ .bin = &zero_bin, .release = Release.release, .release_ctx = &first };
    const s = try make(cfg);
    var alive = true;
    defer if (alive) s.destroy();
    try s.start();
    const never: std.atomic.Value(bool) = .init(false);
    var swapped: Answer = .{ .destroyed = &never };
    defer swapped.deinit();
    const next: DiscBytes = .{ .bin = &zero_bin, .release = Release.release, .release_ctx = &second };
    s.requestSwap(next, Answer.simple, &swapped);
    try until(s, &swapped, Answer.answered, "the swap");
    try expectEqual(capi.PS1_OK, swapped.code.load(.acquire));
    try expectEqual(1, first.count.load(.acquire));
    try expectEqual(0, second.count.load(.acquire));
    s.destroy();
    alive = false;
    try expectEqual(1, first.count.load(.acquire));
    try expectEqual(1, second.count.load(.acquire));
}

/// Watches the renderer's mailbox; when a depth-on setting lands, records
/// what the machine's controls said at that moment. The renderer must never
/// see it first.
const DepthWatch = struct {
    s: *Session,
    stop: std.atomic.Value(bool) = .init(false),
    saw_renderer: std.atomic.Value(bool) = .init(false),
    machine_had_it: std.atomic.Value(bool) = .init(false),

    fn run(self: *DepthWatch) void {
        while (!self.stop.load(.acquire)) {
            const posted = self.s.renderer.mailbox.take() orelse continue;
            if (!posted.depth_buffer) continue;
            self.machine_had_it.store(self.s.loop.controls.depthBuffer(), .release);
            self.saw_renderer.store(true, .release);
            return;
        }
    }
};

test "Session: theDepthBufferReachesTheMachineBeforeTheRenderer" {
    var dir = try CardDir.init();
    defer dir.deinit();
    // Not started: the watcher is the mailbox's only reader.
    const s = try make(headless(dir.path()));
    defer s.destroy();
    var w: DepthWatch = .{ .s = s };
    const t = try std.Thread.spawn(.{}, DepthWatch.run, .{&w});
    s.setPgxp(.{ .enabled = true, .depth_buffer = true });
    const t0 = std.Io.Clock.awake.now(io);
    while (!w.saw_renderer.load(.acquire) and t0.untilNow(io, .awake).nanoseconds < std.time.ns_per_s) std.atomic.spinLoopHint();
    w.stop.store(true, .release);
    t.join();
    try expect(w.saw_renderer.load(.acquire));
    try expect(w.machine_had_it.load(.acquire));
}

fn gpuOnly(card_dir: []const u8) Config {
    var cfg = headless(card_dir);
    cfg.vram = .gpu;
    return cfg;
}

fn ranThirty(s: *Session) bool {
    return s.framesProduced() >= 30;
}

test "Session: aGpuOnlySessionRunsAndStops" {
    var dir = try CardDir.init();
    defer dir.deinit();
    const s = try make(gpuOnly(dir.path()));
    defer s.destroy();
    try s.start();
    try until(s, s, ranThirty, "thirty frames produced");
    const sink = &s.m.h.cpu.bus.gpu.sink;
    try expect(!sink.rasterize);
    try expect(sink.worker == null);
    try expect(sink.host != null);
}

const native_pixels = metal.prim_instance.native_pixels;

fn patternAt(i: usize) u16 {
    return @truncate((i *% 2654435761) >> 7 & 0x7FFF);
}

/// A state whose VRAM holds `patternAt`, saved on a dual handle. Owned by
/// the caller.
fn patternState() ![]u8 {
    const h = capi.ps1_create() orelse return error.OutOfMemory;
    defer capi.ps1_destroy(h);
    _ = capi.ps1_load_bios(h, &zero_bios, zero_bios.len);
    h.cpu.bus.gpu.syncRaster();
    for (&h.cpu.bus.gpu.vram.data, 0..) |*px, i| px.* = patternAt(i);
    const buf = try alloc.alloc(u8, capi.ps1_save_state_size(h));
    errdefer alloc.free(buf);
    var len: usize = 0;
    if (capi.ps1_save_state(h, buf.ptr, buf.len, &len) != capi.PS1_OK) return error.SaveFailed;
    return alloc.realloc(buf, len);
}

/// The whole native texture, through the render thread.
fn textureNow(s: *Session) ![]u16 {
    const colour = try alloc.alloc(u16, native_pixels);
    var req: metal.readback_desk.Readback = .{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 1023, .y1 = 511 },
        .colour = colour,
        .depth = null,
        .through = s.x.queue.ticket(),
    };
    s.render_thread.readback(io, &req);
    return colour;
}

test "Session: aGpuOnlySessionWithAResumeStateShowsTheLoadedVram" {
    var dir = try CardDir.init();
    defer dir.deinit();
    const state = try patternState();
    defer alloc.free(state);
    var cfg = gpuOnly(dir.path());
    cfg.resume_state = state;
    const s = try make(cfg);
    defer s.destroy();
    s.setPaused(true);
    try s.start();
    const got = try textureNow(s);
    defer alloc.free(got);
    for (got, 0..) |px, i| if (px != patternAt(i)) {
        std.debug.print("texture differs at ({d},{d}): {x} want {x}\n", .{ i % 1024, i / 1024, px, patternAt(i) });
        return error.TestUnexpectedResult;
    };
}

test "Session: aGpuOnlySaveRoundTripsThroughALoad" {
    var dir = try CardDir.init();
    defer dir.deinit();
    const s = try make(gpuOnly(dir.path()));
    defer s.destroy();
    try s.start();
    const never: std.atomic.Value(bool) = .init(false);
    var saved: Answer = .{ .destroyed = &never };
    defer saved.deinit();
    s.requestSave(Answer.save, &saved);
    try until(s, &saved, Answer.answered, "the save");
    try expectEqual(capi.PS1_OK, saved.code.load(.acquire));
    const state = saved.bytes orelse return error.NoState;

    var loaded: Answer = .{ .destroyed = &never };
    defer loaded.deinit();
    s.requestLoad(state, Answer.load, &loaded);
    try until(s, &loaded, Answer.answered, "the load");
    try expectEqual(capi.PS1_OK, loaded.code.load(.acquire));
    try expect(loaded.bytes != null);
}

test "Session: aGpuOnlyResetLeavesTheTextureZeroed" {
    var dir = try CardDir.init();
    defer dir.deinit();
    const state = try patternState();
    defer alloc.free(state);
    var cfg = gpuOnly(dir.path());
    cfg.resume_state = state;
    const s = try make(cfg);
    defer s.destroy();
    s.setPaused(true);
    try s.start();
    const never: std.atomic.Value(bool) = .init(false);
    var reset: Answer = .{ .destroyed = &never };
    defer reset.deinit();
    s.requestReset(Answer.simple, &reset);
    try until(s, &reset, Answer.answered, "the reset");
    const got = try textureNow(s);
    defer alloc.free(got);
    for (got) |px| try expectEqual(0, px);
}

test "Session: destroyingWhileASaveReadsBackAnswersTheSave" {
    var dir = try CardDir.init();
    defer dir.deinit();
    const s = try make(gpuOnly(dir.path()));
    var destroyed: std.atomic.Value(bool) = .init(false);
    var save: Answer = .{ .destroyed = &destroyed };
    defer save.deinit();
    try s.start();
    s.requestSave(Answer.save, &save);
    s.destroy();
    destroyed.store(true, .release);
    try expectEqual(1, save.count.load(.acquire));
    try expect(!save.late.load(.acquire));
    const code = save.code.load(.acquire);
    try expect(code == capi.PS1_OK or code == capi.PS1_ERR_SESSION_STOPPED);
}
