//! The render thread's work driven by hand: settings as messages, execute on
//! arrival, present on demand, screenshots.
//! A standalone CAMetalLayer stands in for the window.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");
const lh = @import("live_harness.zig");
const image_io = @import("image_io.zig");

const objc = ps1_metal.objc;
const layer = ps1_metal.mtl_layer;
const fr = ps1_metal.frame_renderer;
const FrameRenderer = fr.FrameRenderer;
const Exchange = ps1_metal.frame_exchange.Exchange;
const Display = ps1_metal.stream_queue.Display;
const Command = @import("ps1_core").gpu.command.Command;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const check = harness.check;

const band: ps1_metal.display.Band = .{ .height = 52, .edge = 10, .sigma = 8 };

/// A renderer over a fresh exchange whose fresh-queue resync is cleared, as
/// a running game's is.
const Bench = struct {
    m: harness.Metal,
    x: *Exchange,
    r: *FrameRenderer,

    fn init(initial: fr.Settings) !Bench {
        const m = try harness.metal();
        errdefer m.deinit();
        const x = try Exchange.init(alloc);
        errdefer x.deinit();
        x.queue.clearResync();
        const r = try FrameRenderer.init(alloc, m, x, band, .{}, initial);
        return .{ .m = m, .x = x, .r = r };
    }

    fn deinit(self: *Bench) void {
        self.r.deinit();
        self.x.deinit();
        self.m.deinit();
    }

    /// Frame `seq` the producer's way: the shadow (blank) first, then the
    /// stream, then the display.
    fn publish(self: *Bench, seq: u64, records: []const Command, d: Display) void {
        const slot = self.x.shadowBack();
        @memset(&slot.pixels, 0);
        slot.depth_valid = false;
        slot.seq = seq;
        self.x.publishShadow();
        lh.publish(self.x.queue, seq, records);
        self.x.publishDisplay(d);
    }

    fn post(self: *Bench, s: fr.Settings) !void {
        self.r.mailbox.post(s);
        try self.r.applySettings();
    }
};

const shown: Display = .{ .width = 320, .height = 240, .enabled = true };

/// A 64x48-pixel layer: the drawable a 64x48-point view at 1x would get.
fn standaloneLayer(m: harness.Metal) layer.MetalLayer {
    const l = layer.MetalLayer.new();
    l.setDevice(m.device);
    l.setPixelFormat(.bgra8Unorm);
    l.setFramebufferOnly(true);
    l.setPresentsWithTransaction(false);
    return l;
}

const sized: fr.Settings = .{ .size_points = .{ 64, 48 } };

/// Every answer a screenshot request got, and the newest PNG.
const Answers = struct {
    count: std.atomic.Value(u32) = .init(0),
    nulls: std.atomic.Value(u32) = .init(0),
    file: ?[]u8 = null,

    fn done(ctx: ?*anyopaque, file: ?[*]const u8, len: usize) callconv(.c) void {
        const self: *Answers = @ptrCast(@alignCast(ctx.?));
        if (file) |f| {
            if (self.file) |old| alloc.free(old);
            self.file = alloc.dupe(u8, f[0..len]) catch null;
        } else {
            _ = self.nulls.fetchAdd(1, .acq_rel);
        }
        _ = self.count.fetchAdd(1, .release);
    }

    fn deinit(self: *Answers) void {
        if (self.file) |f| alloc.free(f);
    }
};

test "FrameRenderer: theRendererBuildsAtTheScaleItWasGiven" {
    var b = try Bench.init(.{ .scale = 3 });
    defer b.deinit();
    try expectEqual(3, b.r.live.vram.scale);
    try expectEqual(3, b.r.current.scale);
}

/// The native view of the renderer's texture. Free with `alloc.destroy`.
fn nativeView(b: *Bench) !*[lh.native_pixels]u16 {
    return lh.readback(b.r.live);
}

test "FrameRenderer: aScaleChangeCarriesTheVramWithoutAResync" {
    var b = try Bench.init(.{});
    defer b.deinit();
    b.publish(1, &.{lh.fillRect(7, 11, 33, 17, 0x03E0)}, shown);
    b.r.executeArrived();
    const before = try nativeView(&b);
    defer alloc.destroy(before);
    try check(harness.painted(before) > 0, "the fill painted nothing", .{});

    try b.post(.{ .scale = 3 });
    try expect(!b.x.queue.needsResync());
    try expectEqual(3, b.r.live.vram.scale);
    const after = try nativeView(&b);
    defer alloc.destroy(after);
    try check(std.mem.eql(u16, before, after), "the 3x texture's native view differs from the 1x picture it replaced", .{});
}

test "FrameRenderer: aScaleChangeLeavesExactlyOneConsumer" {
    var b = try Bench.init(.{});
    defer b.deinit();
    try b.post(.{ .scale = 3 });
    b.publish(1, &.{}, shown);
    b.r.executeArrived();
    try expect(!b.x.queue.needsResync());
    // Frame 2 executes into the NEW texture: the one renderer that exists.
    const fill = lh.fillRect(7, 11, 33, 17, 0x03E0);
    b.publish(2, &.{fill}, shown);
    b.r.executeArrived();
    try expectEqual(2, b.r.live.last_executed_seq);
    try expectEqual(0, b.x.queue.pendingCount());

    const rig = try harness.Rig.create(alloc, b.m, .{ .scale = 3 });
    defer rig.destroy();
    rig.frame(&.{}, &.{fill});
    const want = try rig.readback(alloc);
    defer alloc.free(want);
    const got = try alloc.alloc(u16, b.r.live.vram.pixelCount());
    defer alloc.free(got);
    b.r.live.vram.readback(got);
    try check(std.mem.eql(u16, got, want), "the 3x texture differs from a 3x replay of the same frame", .{});
}

test "FrameRenderer: aDepthToggleRebuildsTheVramWithoutAResync" {
    var b = try Bench.init(.{});
    defer b.deinit();
    b.publish(1, &.{lh.fillRect(7, 11, 33, 17, 0x03E0)}, shown);
    b.r.executeArrived();
    const before = try nativeView(&b);
    defer alloc.destroy(before);
    try expect(!b.r.live.vram.depth_persists);
    try b.post(.{ .depth_buffer = true });
    try expect(b.r.live.vram.depth_persists);
    try expect(!b.x.queue.needsResync());
    const after = try nativeView(&b);
    defer alloc.destroy(after);
    try check(std.mem.eql(u16, before, after), "the depth toggle lost the picture", .{});
    // An unchanged scale and depth re-posted rebuilds nothing.
    try b.post(.{ .depth_buffer = true, .dither = .native });
    try expect(!b.x.queue.needsResync());
    try expectEqual(.native, b.r.live.rasterizer.dither_mode);
}

test "FrameRenderer: anOccludedRendererExecutesButDoesNotPresent" {
    var b = try Bench.init(sized);
    defer b.deinit();
    const l = standaloneLayer(b.m);
    defer l.release();
    var s = sized;
    s.occluded = true;
    try b.post(s);
    b.publish(1, &.{lh.fillRect(0, 0, 16, 16, 0x001F)}, shown);
    b.r.executeArrived();
    b.r.present(l, 0);
    try expectEqual(1, b.r.live.last_executed_seq);
    try expectEqual(0, b.r.presented.load(.monotonic));
    s.occluded = false;
    try b.post(s);
    b.r.present(l, 0);
    try expectEqual(1, b.r.presented.load(.monotonic));
}

test "FrameRenderer: aRunaheadPictureIsShownWhereItsOwnFrameDisplays" {
    const real: Display = .{ .vram_x = 0, .width = 320, .height = 240, .enabled = true };
    const ahead: Display = .{ .vram_x = 320, .width = 320, .height = 240, .enabled = true };
    try expectEqual(320, fr.chooseDisplay(real, ahead).vram_x);
    try expectEqual(0, fr.chooseDisplay(real, null).vram_x);
    var ahead24 = ahead;
    ahead24.depth24 = true;
    try expectEqual(320, fr.chooseDisplay(real, ahead24).vram_x);
    var real24 = real;
    real24.depth24 = true;
    try expectEqual(320, fr.chooseDisplay(real24, ahead).vram_x);
}

test "FrameRenderer: aRequestIsTakenOnce [validate]" {
    var b = try Bench.init(sized);
    defer b.deinit();
    const l = standaloneLayer(b.m);
    defer l.release();
    b.publish(1, &.{}, shown);
    b.r.executeArrived();
    b.r.present(l, 0);
    var a: Answers = .{};
    defer a.deinit();
    b.r.requestScreenshot(Answers.done, &a);
    b.r.present(l, 0.016);
    b.r.present(l, 0.033);
    try harness.awaitHandler(&a.count, "aRequestIsTakenOnce");
    // Every block has run once none is in flight.
    while (b.r.shots_in_flight.load(.acquire) != 0) try std.Thread.yield();
    try expectEqual(1, a.count.load(.acquire));
    try expectEqual(0, a.nulls.load(.acquire));
    const d = try image_io.decodePng(a.file.?, 0, 0);
    try expectEqual(320, d.width);
    try expectEqual(240, d.height);
}

test "FrameRenderer: aScreenshotOfADisabledDisplayIsAPlainBlackVgaFrame [validate]" {
    var b = try Bench.init(.{});
    defer b.deinit();
    b.publish(1, &.{lh.fillRect(0, 0, 1024, 512, 0x7FFF)}, .{});
    var a: Answers = .{};
    defer a.deinit();
    b.r.requestScreenshot(Answers.done, &a);
    // No layer has ever been presented to, so the execute answers it.
    b.r.executeArrived();
    try harness.awaitHandler(&a.count, "aScreenshotOfADisabledDisplay");
    const d = try image_io.decodePng(a.file.?, 320, 240);
    try expectEqual(640, d.width);
    try expectEqual(480, d.height);
    try expectEqual([3]u8{ 0, 0, 0 }, d.px);
}

test "FrameRenderer: anOccludedRendererStillAnswersAScreenshot" {
    var b = try Bench.init(sized);
    defer b.deinit();
    const l = standaloneLayer(b.m);
    defer l.release();
    b.publish(1, &.{}, shown);
    b.r.executeArrived();
    b.r.present(l, 0);
    var s = sized;
    s.occluded = true;
    try b.post(s);
    var a: Answers = .{};
    defer a.deinit();
    b.r.requestScreenshot(Answers.done, &a);
    b.r.present(l, 0.016);
    try expectEqual(0, a.count.load(.acquire));
    b.publish(2, &.{}, shown);
    b.r.executeArrived();
    try harness.awaitHandler(&a.count, "anOccludedRendererStillAnswersAScreenshot");
    try expectEqual(0, a.nulls.load(.acquire));
}

test "FrameRenderer: aRendererFreedWithAScreenshotInFlightStillAnswersIt" {
    const m = try harness.metal();
    defer m.deinit();
    const x = try Exchange.init(alloc);
    defer x.deinit();
    const r = try FrameRenderer.init(alloc, m, x, band, .{}, .{});
    var a: Answers = .{};
    defer a.deinit();
    var queued: Answers = .{};
    defer queued.deinit();
    r.requestScreenshot(Answers.done, &a);
    r.executeArrived();
    // Queued after the picture was taken: freeing answers it with null.
    r.requestScreenshot(Answers.done, &queued);
    r.deinit();
    // Both answered by the time `deinit` returned, not after.
    try expectEqual(1, a.count.load(.acquire));
    try expect(a.file != null);
    try expectEqual(1, queued.count.load(.acquire));
    try expectEqual(1, queued.nulls.load(.acquire));
}

test "FrameRenderer: aSettingPostedFromAnotherThreadIsTakenOnce" {
    var mb: fr.Mailbox = .{};
    const Poster = struct {
        fn run(box: *fr.Mailbox) void {
            box.post(.{ .scale = 2 });
            box.post(.{ .scale = 4 });
        }
    };
    const t = try std.Thread.spawn(.{}, Poster.run, .{&mb});
    t.join();
    try expectEqual(4, mb.take().?.scale);
    try expectEqual(null, mb.take());
}

// The filters are runtime uniforms, like dithering: a posted change lands on
// the live rasterizer the next frame encodes with, and rebuilds no VRAM.
test "FrameRenderer: theFiltersReachTheRasterizerWithoutARebuild" {
    var b = try Bench.init(.{});
    defer b.deinit();
    const r = &b.r.live.rasterizer;
    try expectEqual(.nearest, r.texture_filter);
    try expectEqual(.nearest, r.sprite_filter);
    const vram = r.vram;
    const texture = b.r.live.vram.texture.id;
    try b.post(.{ .texture_filter = .bilinear, .sprite_filter = .bilinear });
    try expectEqual(.bilinear, r.texture_filter);
    try expectEqual(.bilinear, r.sprite_filter);
    try expectEqual(vram, r.vram);
    try expectEqual(texture, b.r.live.vram.texture.id);
    try expect(!b.x.queue.needsResync());
}

test "FrameRenderer: presentSkipsWhileTheNewestExecutedChunkIsNonFinal" {
    var b = try Bench.init(sized);
    defer b.deinit();
    const l = standaloneLayer(b.m);
    defer l.release();
    b.x.queue.publishChunk(1, .{ .records = &.{lh.fillRect(0, 0, 16, 16, 0x001F)}, .payload = &.{}, .complete = true });
    b.r.executeArrived();
    b.r.present(l, 0);
    try expectEqual(0, b.r.presented.load(.monotonic));
    b.publish(1, &.{lh.fillRect(0, 0, 16, 16, 0x7C00)}, shown);
    b.r.executeArrived();
    b.r.present(l, 0);
    try expectEqual(1, b.r.presented.load(.monotonic));
}
