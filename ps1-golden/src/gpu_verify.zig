//! `ps1-golden-metal gpu-verify`: the trace goldens with Metal as the
//! machine's only VRAM.
//!
//! Every workload boots as `verify` boots it, on a `Bus` that records without
//! rasterizing. Nothing takes a frame: every record reaches the renderer
//! through a chunk, flushed when the recorder fills or taken by a readback,
//! so the run exercises exactly the GPU-only paths. At every sample the whole
//! VRAM is settled through a readback before it is hashed, and the hashes
//! must match the unchanged goldens.
//!
//! The renderer runs at 1x, `.native` dithering, both filters nearest: the
//! configuration `parity` proves equal to the software rasterizer.
//! `--record-limit` lowers the recorder's capacities so real content forces
//! flushes. A workload whose machine asked for a read nobody served fails.

const std = @import("std");
const ps1 = @import("ps1_core");
const ps1_metal = @import("ps1_metal");
const golden = @import("golden.zig");
const boot = @import("boot.zig");
const script = @import("script.zig");
const state_hash = @import("state_hash.zig");
const verify = @import("verify.zig");
const Ticker = @import("ticker.zig").Ticker;

const Metal = ps1_metal.metal_context.Metal;
const Rig = ps1_metal.metal_context.Rig;
const objc = ps1_metal.objc;
const native_pixels = ps1_metal.metal_vram.native_pixels;
const HostRect = ps1.gpu.HostRect;

pub const default_instructions: u64 = 600_000_000;
pub const default_interval: u64 = 2_500_000;

pub const Options = struct {
    instructions: u64 = default_instructions,
    interval: u64 = default_interval,
    /// `Recorder.limit_records`; the payload limit is eight words a record.
    record_limit: ?usize = null,
};

/// The machine's VRAM host: each chunk it takes goes straight into the rig,
/// synchronously, and a read gathers the native texture back.
const GateHost = struct {
    rig: *Rig,
    scratch: *[native_pixels]u16,

    fn host(self: *GateHost) ps1.gpu.Host {
        return .{ .ctx = self, .read = read, .flush = flush };
    }

    fn execute(self: *GateHost, sink: *ps1.gpu.Sink) void {
        const s = sink.rec.takeChunk();
        if (!s.complete) @panic("gpu-verify: a chunk overflowed the recorder");
        const pool = objc.Pool.push();
        defer pool.pop();
        self.rig.frame(s.payload, s.records);
    }

    fn flush(ctx: *anyopaque, sink: *ps1.gpu.Sink) void {
        const self: *GateHost = @ptrCast(@alignCast(ctx));
        self.execute(sink);
    }

    fn read(ctx: *anyopaque, sink: *ps1.gpu.Sink, vram: *ps1.gpu.Vram, rect: HostRect, depth: bool) void {
        const self: *GateHost = @ptrCast(@alignCast(ctx));
        self.execute(sink);
        self.rig.vram.readbackNative(self.scratch);
        for (rect.y..@as(usize, rect.y) + rect.h) |y| {
            const lo = ps1.gpu.Vram.index(rect.x, y);
            const hi = lo + rect.w;
            @memcpy(vram.data[lo..hi], self.scratch[lo..hi]);
            // The rig runs without a depth plane: everything is far.
            if (depth) @memset(vram.depth[lo..hi], 0);
        }
    }
};

pub const Result = struct {
    run: verify.RunResult,
    stats: ps1.gpu.HostStats,
};

pub fn runWorkload(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    opts: Options,
    gpu: Metal,
    set: *const ps1_metal.pipelines.Set,
) !Result {
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);
    try boot.loadMachine(a, io, wl, null, bus);
    try boot.selectEngine(&cpu, .interpreter, .{});

    const rig = try Rig.create(a, gpu, .{ .scale = 1, .depth_buffer = false, .set = set });
    defer rig.destroy();
    rig.r.dither_mode = .native;
    rig.r.texture_filter = .nearest;
    rig.r.sprite_filter = .nearest;
    rig.r.synchronous = true;
    var gate: GateHost = .{ .rig = rig, .scratch = try a.create([native_pixels]u16) };

    const sink = &bus.gpu.sink;
    sink.rec.arm();
    if (opts.record_limit) |n| {
        sink.rec.limit_records = n;
        sink.rec.limit_payload = 8 * n;
    }
    sink.setRasterize(false);
    sink.host = gate.host();

    const static_before = state_hash.hashStatic(bus);
    var samples = std.ArrayList(golden.Sample).empty;
    var pad = script.Pad{};
    var sample_at = Ticker.init(opts.interval, opts.interval);
    var i: u64 = 0;
    while (i < opts.instructions) {
        if (pad.maskAt(i)) |m| bus.sio.setButtons(m);
        const next = @min(opts.instructions, @min(sample_at.next, pad.next()));
        i += cpu.runFor(@intCast(@min(next - i, std.math.maxInt(u32))));
        if (sample_at.due(i)) |at| {
            boot.settleForSample(bus);
            // The sample itself is a readback: the hash sees the texture.
            bus.gpu.settleVram(.all, false);
            var s = golden.Sample{ .instr = at, .hashes = undefined };
            state_hash.hashAll(&cpu, &s.hashes);
            try samples.append(a, s);
        }
    }
    return .{
        .run = .{
            .samples = try samples.toOwnedSlice(a),
            .static_before = static_before,
            .static_after = state_hash.hashStatic(bus),
        },
        .stats = sink.stats,
    };
}

/// Returns true when the workload failed.
pub fn report(a: std.mem.Allocator, io: std.Io, key: []const u8, opts: Options, r: Result) !bool {
    const diverged = try verify.verifyGolden(a, io, key, opts.instructions, opts.interval, .interpreter, r.run);
    std.debug.print("  {s: <22} reads {d}  stale {d}  flushes {d}  unserved {d}  speculative {d}\n", .{
        "", r.stats.reads, r.stats.stale_reads, r.stats.flushes, r.stats.unserved_reads, r.stats.speculative_reads,
    });
    if (r.stats.unserved_reads != 0) {
        std.debug.print("  {s: <22} FAIL: {d} reads found no host\n", .{ key, r.stats.unserved_reads });
        return true;
    }
    return diverged;
}
