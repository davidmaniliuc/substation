//! The GPU-only VRAM host over a real queue and render thread: chunks go in
//! under the frame being built, readbacks see them, and a stopped renderer
//! never strands the emulator thread. Needs Metal: `zig build test-metal`.

const std = @import("std");
const session = @import("ps1_session");
const metal = @import("ps1_metal");
const ps1_core = @import("ps1_core");

const VramHost = session.vram_host.VramHost;
const Exchange = metal.frame_exchange.Exchange;
const FrameRenderer = metal.frame_renderer.FrameRenderer;
const RenderThread = metal.render_thread.RenderThread;
const Metal = metal.metal_context.Metal;
const Pacer = metal.waker.Pacer;
const PacerWake = metal.waker.PacerWake;
const Gpu = ps1_core.gpu.Gpu;
const Command = ps1_core.gpu.command.Command;

const alloc = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const fill: Command = .{ .kind = .fill_rect, .x = 0, .y = 0, .w = 16, .h = 16, .value = 0x001F };

/// A renderer and its thread over a fresh exchange, a recording `Gpu`
/// whose sink the host takes chunks from, and the host itself.
const Bench = struct {
    m: Metal,
    x: *Exchange,
    r: *FrameRenderer,
    rt: RenderThread = .{},
    pacer: Pacer = .{},
    wake: PacerWake = undefined,
    gpu: *Gpu,
    seq: u64 = 4,
    host: VramHost = undefined,

    fn init(b: *Bench) !void {
        b.m = Metal.open() catch return error.SkipZigTest;
        errdefer b.m.deinit();
        b.x = try Exchange.init(alloc);
        errdefer b.x.deinit();
        b.x.queue.clearResync();
        b.x.queue.lossless = true;
        b.r = try FrameRenderer.init(alloc, b.m, b.x, .{ .height = 0, .edge = 0, .sigma = 0 }, .{}, .{});
        b.rt = .{};
        b.pacer = .{};
        b.wake = .{ .pacer = &b.pacer, .io = io };
        b.x.queue.on_drained = b.wake.waker();
        b.gpu = try alloc.create(Gpu);
        b.gpu.* = Gpu.init();
        b.gpu.sink.rec.arm();
        b.seq = 4;
        b.host = try VramHost.init(alloc, b.x.queue, &b.rt, &b.pacer, io, &b.seq);
    }

    fn deinit(b: *Bench) void {
        b.rt.stop();
        b.rt.deinit();
        b.host.deinit(alloc);
        alloc.destroy(b.gpu);
        b.r.deinit();
        b.x.deinit();
        b.m.deinit();
    }
};

test "VramHost: aFlushPublishesANonFinalChunkUnderTheNextSeq" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    b.gpu.sink.rec.push(fill);
    const h = b.host.host();
    h.flush(h.ctx, &b.gpu.sink);
    try expectEqual(1, b.x.queue.pendingCount());
    const slot = &b.x.queue.slots[0];
    try expectEqual(5, slot.seq);
    try expect(!slot.final);
    try expectEqual(1, slot.record_count);
    try expectEqual(0, b.gpu.sink.rec.count);
}

test "VramHost: aReadbackBetweenFramesPublishesUnderTheNextSeq" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.rt.start(b.r, null, null, null);
    b.gpu.sink.rec.push(fill);
    const h = b.host.host();
    h.read(h.ctx, &b.gpu.sink, &b.gpu.vram, .{ .x = 0, .y = 0, .w = 32, .h = 4 }, false);
    try expectEqual(5, b.x.queue.slots[0].seq);
    try expect(!b.x.queue.slots[0].final);
    for (0..4) |y| {
        const row = b.gpu.vram.data[y * 1024 ..][0..32];
        for (row[0..16]) |px| try expectEqual(0x001F, px);
        for (row[16..]) |px| try expectEqual(0, px);
    }
}

test "VramHost: aFlushWaitingOnAStoppedRendererReturns" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.rt.start(b.r, null, null, null);
    b.rt.stop();
    for (1..metal.stream_queue.StreamQueue.capacity + 1) |seq|
        b.x.queue.publish(seq, .{ .records = &.{fill}, .payload = &.{}, .complete = true });
    try expectEqual(0, b.x.queue.freeSlots());
    b.gpu.sink.rec.push(fill);
    const h = b.host.host();
    h.flush(h.ctx, &b.gpu.sink);
    try expectEqual(1, b.x.queue.dropped_count.load(.monotonic));
}

test "VramHost: aFlushNeverTakesTheSlotTheFramesFinalStreamNeeds" {
    var b: Bench = undefined;
    try b.init();
    defer b.deinit();
    try b.rt.start(b.r, null, null, null);
    b.rt.stop();
    // `iterate` runs a frame with one slot free; a chunk taking it would
    // leave the frame's own final slot nowhere to go.
    for (1..metal.stream_queue.StreamQueue.capacity) |seq|
        b.x.queue.publish(seq, .{ .records = &.{fill}, .payload = &.{}, .complete = true });
    try expectEqual(1, b.x.queue.freeSlots());
    b.gpu.sink.rec.push(fill);
    const h = b.host.host();
    h.flush(h.ctx, &b.gpu.sink);
    try expectEqual(1, b.x.queue.freeSlots());
}
