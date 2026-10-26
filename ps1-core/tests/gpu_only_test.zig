//! GPU-only VRAM: the core records without rasterizing, and every pixel it
//! reads comes back through the host. `FakeHost` stands in for Metal by
//! replaying every chunk it takes into its own `Vram`; each test drives a
//! rasterizing `want` and a recording `got` with the same words and requires
//! what the CPU sees to be identical.

const std = @import("std");
const ps1_core = @import("ps1_core");
const expectVramEqual = @import("vram_compare.zig").expectVramEqual;

const Gpu = ps1_core.gpu.Gpu;
const Vram = ps1_core.gpu.Vram;
const Sink = ps1_core.gpu.Sink;
const Host = ps1_core.gpu.Host;
const HostRect = ps1_core.gpu.HostRect;
const DrawingEnv = ps1_core.gpu.Regs.DrawingEnv;
const command = ps1_core.gpu.command;
const Value = ps1_core.pgxp.Value;

fn xy(x: u16, y: u16) u32 {
    return @as(u32, x & 0x7FF) | (@as(u32, y & 0x7FF) << 16);
}

const FakeHost = struct {
    vram: *Vram,
    env: DrawingEnv = .{},
    reads: usize = 0,
    flushes: usize = 0,
    last_rect: ?HostRect = null,

    fn host(self: *FakeHost) Host {
        return .{ .ctx = self, .read = read, .flush = flush };
    }

    fn take(self: *FakeHost, sink: *Sink) void {
        std.debug.assert(!sink.speculating);
        const s = sink.rec.takeChunk();
        std.debug.assert(s.complete);
        command.replay(s, self.vram, &self.env);
    }

    fn read(ctx: *anyopaque, sink: *Sink, vram: *Vram, rect: HostRect, depth: bool) void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        self.take(sink);
        self.reads += 1;
        self.last_rect = rect;
        for (rect.y..@as(usize, rect.y) + rect.h) |y| {
            const lo = Vram.index(rect.x, y);
            const hi = lo + rect.w;
            @memcpy(vram.data[lo..hi], self.vram.data[lo..hi]);
            if (depth) @memcpy(vram.depth[lo..hi], self.vram.depth[lo..hi]);
        }
    }

    fn flush(ctx: *anyopaque, sink: *Sink) void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        self.take(sink);
        self.flushes += 1;
    }
};

/// One temporary per frame: a `Gpu` is ~10 MB, and two in one frame overrun
/// the test runner's stack.
fn newGpu() !*Gpu {
    const gpu = try std.testing.allocator.create(Gpu);
    gpu.* = Gpu.init();
    gpu.sink.rec.arm();
    return gpu;
}

fn newVram() !*Vram {
    const vram = try std.testing.allocator.create(Vram);
    vram.* = .{};
    return vram;
}

/// `want` rasterizes as `.software` does; `got` records only, with the fake
/// host behind it.
const Pair = struct {
    want: *Gpu,
    got: *Gpu,
    fake: *FakeHost,

    fn init() !Pair {
        const want = try newGpu();
        const got = try newGpu();
        const fake = try std.testing.allocator.create(FakeHost);
        fake.* = .{ .vram = try newVram() };
        got.sink.setRasterize(false);
        got.sink.host = fake.host();
        var p = Pair{ .want = want, .got = got, .fake = fake };
        p.gp0(0xE3000000);
        p.gp0(0xE407FFFF);
        p.gp0(0xE5000000);
        return p;
    }

    fn deinit(self: *Pair) void {
        const a = std.testing.allocator;
        a.destroy(self.want);
        a.destroy(self.got);
        a.destroy(self.fake.vram);
        a.destroy(self.fake);
    }

    fn gp0(self: *Pair, word: u32) void {
        _ = self.want.writeGp0(word, Value.none);
        _ = self.got.writeGp0(word, Value.none);
    }

    /// Retires every queued GP0 word; see `gpu_stream_test`'s `drain`.
    fn drain(self: *Pair) void {
        _ = self.want.step(50_000_000);
        _ = self.got.step(50_000_000);
    }

    fn fill(self: *Pair, x: u16, y: u16, w: u16, h: u16, bgr: u24) void {
        self.gp0(0x02000000 | @as(u32, bgr));
        self.gp0(xy(x, y));
        self.gp0(xy(w, h));
    }

    fn triangle(self: *Pair, bgr: u24) void {
        self.gp0(0x20000000 | @as(u32, bgr));
        self.gp0(xy(4, 4));
        self.gp0(xy(60, 10));
        self.gp0(xy(20, 50));
    }

    fn readSetup(self: *Pair, x: u16, y: u16, w: u16, h: u16) void {
        self.gp0(0xC0000000);
        self.gp0(xy(x, y));
        self.gp0(@as(u32, w) | (@as(u32, h) << 16));
        self.drain();
    }

    /// Reads `n` GPUREAD words from both and requires them equal.
    fn expectWords(self: *Pair, n: usize) ![]u32 {
        const words = try std.testing.allocator.alloc(u32, n);
        for (words) |*w| {
            w.* = self.want.readData();
            try std.testing.expectEqual(w.*, self.got.readData());
        }
        return words;
    }
};

const red: u24 = 0x0000FF;
const blue: u24 = 0xFF0000;

test "GPU-only: aGpuReadReturnsTheSettledRect" {
    var p = try Pair.init();
    defer p.deinit();
    p.fill(0, 0, 64, 64, red);
    p.triangle(0x00FF00);
    p.readSetup(8, 8, 16, 4);
    const words = try p.expectWords(32);
    defer std.testing.allocator.free(words);
    try std.testing.expectEqual(@as(usize, 1), p.fake.reads);
}

test "GPU-only: aPixelRecordPushedMidReadMarksTheReadStale" {
    var p = try Pair.init();
    defer p.deinit();
    p.fill(0, 0, 16, 1, red);
    p.readSetup(0, 0, 8, 1);
    const head = try p.expectWords(2);
    defer std.testing.allocator.free(head);
    p.fill(0, 0, 16, 1, blue);
    p.drain();
    const tail = try p.expectWords(2);
    defer std.testing.allocator.free(tail);
    try std.testing.expect(head[0] != tail[0]);
    try std.testing.expectEqual(@as(u64, 1), p.got.sink.stats.stale_reads);
}

test "GPU-only: aReadAfterAFlushSeesTheFlushedRecords" {
    var p = try Pair.init();
    defer p.deinit();
    p.drain();
    p.got.sink.rec.limit_records = 8;
    for (0..20) |i| p.fill(@intCast(i * 16), 0, 16, 16, @intCast(0x081020 * (i + 1)));
    p.readSetup(0, 0, 320, 16);
    const words = try p.expectWords(320 * 16 / 2);
    defer std.testing.allocator.free(words);
    try std.testing.expect(p.fake.flushes >= 2);
    try std.testing.expect(!p.got.sink.rec.overflow);
}

test "GPU-only: aReadCrossingTheEdgeSettlesOnlyTheInBoundsPart" {
    var p = try Pair.init();
    defer p.deinit();
    p.fill(1008, 0, 16, 1, red);
    p.readSetup(1016, 0, 16, 1);
    const words = try p.expectWords(8);
    defer std.testing.allocator.free(words);
    try std.testing.expect(words[0] != 0);
    for (words[4..]) |w| try std.testing.expectEqual(@as(u32, 0), w);
    try std.testing.expectEqual(HostRect{ .x = 1016, .y = 0, .w = 8, .h = 1 }, p.fake.last_rect.?);
}

test "GPU-only: anOverflowingFrameReachesTheHostWhole" {
    var p = try Pair.init();
    defer p.deinit();
    p.drain();
    p.got.sink.rec.limit_records = 16;
    p.got.sink.rec.limit_payload = 64;
    p.triangle(0x00FF00);
    p.gp0(0xA0000000);
    p.gp0(xy(100, 100));
    p.gp0(xy(16, 16));
    for (0..128) |i| p.gp0(@intCast(0x7C1F03E0 +% i * 0x00010001));
    p.triangle(red);
    p.drain();
    p.got.settleVram(HostRect.all, false);
    try expectVramEqual(&p.want.vram, &p.got.vram);
    try std.testing.expect(p.fake.flushes >= 1);
    try std.testing.expect(!p.got.sink.rec.overflow);
}

test "GPU-only: nothingIsReadWhileSpeculating" {
    var p = try Pair.init();
    defer p.deinit();
    p.got.sink.speculating = true;
    p.readSetup(0, 0, 4, 1);
    _ = p.got.readData();
    try std.testing.expectEqual(@as(usize, 0), p.fake.reads);
    try std.testing.expectEqual(@as(u64, 1), p.got.sink.stats.speculative_reads);
    try std.testing.expectEqual(@as(u64, 0), p.got.sink.stats.unserved_reads);
}

test "GPU-only: aSpeculativeReadIsCountedApartFromAnUnservedOne" {
    var p = try Pair.init();
    defer p.deinit();
    p.got.sink.speculating = true;
    p.got.sink.settle(&p.got.vram, HostRect.all, false);
    try std.testing.expectEqual(@as(u64, 1), p.got.sink.stats.speculative_reads);
    try std.testing.expectEqual(@as(u64, 0), p.got.sink.stats.unserved_reads);
    try std.testing.expectEqual(@as(usize, 0), p.fake.reads);
    p.got.sink.host = null;
    p.got.sink.speculating = false;
    p.got.sink.settle(&p.got.vram, HostRect.all, false);
    try std.testing.expectEqual(@as(u64, 1), p.got.sink.stats.unserved_reads);
    try std.testing.expectEqual(@as(u64, 1), p.got.sink.stats.speculative_reads);
}

test "GPU-only: aSpeculativeReadLeavesTheRealStaleMark" {
    var p = try Pair.init();
    defer p.deinit();
    p.fill(0, 0, 16, 1, red);
    p.readSetup(0, 0, 8, 1);
    p.fill(0, 0, 16, 1, blue);
    p.drain();
    try std.testing.expect(p.got.sink.read_stale);
    p.got.sink.speculating = true;
    _ = p.got.readData();
    try std.testing.expect(p.got.sink.read_stale);
    p.got.sink.speculating = false;
    const reads = p.fake.reads;
    _ = p.got.readData();
    try std.testing.expectEqual(reads + 1, p.fake.reads);
    try std.testing.expect(!p.got.sink.read_stale);
}

test "GPU-only: transferCursorsAreRealWithoutRasterizing" {
    var p = try Pair.init();
    defer p.deinit();
    p.readSetup(32, 32, 4, 2);
    p.gp0(0xA0000000);
    p.gp0(xy(4, 4));
    p.gp0(xy(8, 8));
    for (0..16) |i| p.gp0(@intCast(i));
    p.drain();
    const w = &p.want.vram;
    const g = &p.got.vram;
    try std.testing.expectEqual(w.write_active, g.write_active);
    try std.testing.expectEqual(w.write_curr_x, g.write_curr_x);
    try std.testing.expectEqual(w.write_curr_y, g.write_curr_y);
    try std.testing.expectEqual(w.write_remaining, g.write_remaining);
    try std.testing.expectEqual(w.read_active, g.read_active);
    try std.testing.expectEqual(w.read_x, g.read_x);
    try std.testing.expectEqual(w.read_w, g.read_w);
    try std.testing.expectEqual(w.read_remaining, g.read_remaining);
    try std.testing.expect(p.got.sink.transfer.matches(g));
}

test "GPU-only: rasterizingIsTheDefaultAndUnchanged" {
    const gpu = try newGpu();
    defer std.testing.allocator.destroy(gpu);
    try std.testing.expect(gpu.sink.rasterize);
    _ = gpu.writeGp0(0x02FF0000, Value.none);
    _ = gpu.writeGp0(xy(0, 0), Value.none);
    _ = gpu.writeGp0(xy(16, 16), Value.none);
    _ = gpu.step(50_000_000);
    try std.testing.expect(gpu.vram.data[0] != 0);
    try std.testing.expectEqual(ps1_core.gpu.HostStats{}, gpu.sink.stats);
}

const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;
const savestate = ps1_core.savestate;

fn gpuOnlyBus(host: ?Host) !*Bus {
    const bus = try Bus.init(std.testing.allocator);
    bus.gpu.sink.rec.arm();
    bus.gpu.sink.setRasterize(false);
    bus.gpu.sink.host = host;
    return bus;
}

fn saveTrustedAlloc(cpu: *const Cpu) ![]u8 {
    const n = try savestate.saveTrusted(cpu, null, .write);
    const buf = try std.testing.allocator.alloc(u8, n);
    _ = try savestate.saveTrusted(cpu, buf, .write);
    return buf;
}

// In this binary rather than savestate_test.zig: that one builds against the
// software core, where `rasterize` is ignored and the host is never asked.
test "savestate: saveTrustedSettlesNothingOnItsOwn" {
    const fake = try std.testing.allocator.create(FakeHost);
    defer std.testing.allocator.destroy(fake);
    fake.* = .{ .vram = try newVram() };
    defer std.testing.allocator.destroy(fake.vram);
    const bus = try gpuOnlyBus(fake.host());
    defer bus.deinit(std.testing.allocator);
    const cpu = Cpu.init(bus);
    const buf = try saveTrustedAlloc(&cpu);
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqual(@as(usize, 0), fake.reads);
}

fn halfUpload(gpu: *Gpu) void {
    for ([_]u32{ 0xE3000000, 0xE407FFFF, 0xE5000000, 0xA0000000, xy(4, 4), xy(8, 8) }) |w|
        _ = gpu.writeGp0(w, Value.none);
    for (0..16) |i| _ = gpu.writeGp0(@as(u32, 0x11112222) *% @as(u32, @intCast(i + 1)), Value.none);
    _ = gpu.step(50_000_000);
}

test "savestate: aStateSavedMidUploadUnderGpuOnlyCarriesTheSoftwareCursors" {
    const a = std.testing.allocator;
    const want_bus = try Bus.init(a);
    defer want_bus.deinit(a);
    want_bus.gpu.sink.rec.arm();
    const got_bus = try gpuOnlyBus(null);
    defer got_bus.deinit(a);
    halfUpload(&want_bus.gpu);
    halfUpload(&got_bus.gpu);
    try std.testing.expect(got_bus.gpu.vram.write_active);
    // The landing area is not part of the claim; everything else is.
    got_bus.gpu.vram.data = want_bus.gpu.vram.data;

    const want_cpu = Cpu.init(want_bus);
    const got_cpu = Cpu.init(got_bus);
    const want = try saveTrustedAlloc(&want_cpu);
    defer a.free(want);
    const got = try saveTrustedAlloc(&got_cpu);
    defer a.free(got);
    try std.testing.expectEqualSlices(u8, want, got);

    for ([_][]const u8{ want, got }) |state| {
        const fresh = try Bus.init(a);
        defer fresh.deinit(a);
        var cpu = Cpu.init(fresh);
        try savestate.loadTrusted(&cpu, state);
        try std.testing.expect(fresh.gpu.vram.write_active);
        try std.testing.expect(fresh.gpu.sink.transfer.matches(&fresh.gpu.vram));
        try std.testing.expect(fresh.gpu.sink.transfer.writeActive());
    }
}

test "GPU-only: aMarkUnderGpuOnlyLeavesTheDepthPlaneAlone" {
    const bus = try gpuOnlyBus(null);
    defer bus.deinit(std.testing.allocator);
    bus.setPgxp(true);
    bus.setPgxpDepthBuffer(true);
    var cpu = Cpu.init(bus);
    const mark = try std.testing.allocator.create(savestate.Mark);
    defer std.testing.allocator.destroy(mark);
    mark.* = savestate.Mark.init(std.testing.allocator);
    defer mark.deinit();
    @memset(&bus.gpu.vram.depth, 7);
    bus.gpu.gp0.depth_state = .{ .last_w = 3.0, .dirty = true };
    try mark.take(&cpu);
    @memset(&bus.gpu.vram.depth, 9);
    bus.gpu.gp0.depth_state = .{};
    try mark.restore(&cpu);
    for (&bus.gpu.vram.depth) |d| try std.testing.expectEqual(@as(@TypeOf(d), 9), d);
    try std.testing.expectEqual(@as(f32, 3.0), bus.gpu.gp0.depth_state.last_w);
    try std.testing.expect(bus.gpu.gp0.depth_state.dirty);
}
