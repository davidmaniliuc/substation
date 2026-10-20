//! The renderer benchmark: replays `.p1fx` fixtures through the Zig Metal
//! renderer at several internal resolutions and reports what a frame costs.
//!
//! Two passes per (fixture, scale, config):
//! - SYNCHRONOUS: each frame waited on, so `GPUEndTime - GPUStartTime` summed
//!   over the buffers it committed (read after the wait, not from completed
//!   handlers) is a per-frame cost. Overlapping buffers would otherwise sum
//!   past wall time.
//! - PIPELINED: `synchronous = false`, timed wall-clock over the whole run,
//!   which is the frame rate a player can actually get.
//!
//! The defaults are the shipped settings, because a headless binary has no
//! `UserDefaults` to read the player's own from.

const std = @import("std");
const ps1_metal = @import("ps1_metal");

const objc = ps1_metal.objc;
const mtl = ps1_metal.mtl;
const pi = ps1_metal.prim_instance;
const fixture = ps1_metal.fixture;
const fixture_corpus = ps1_metal.fixture_corpus;
const MetalVram = ps1_metal.metal_vram.MetalVram;
const Rasterizer = ps1_metal.rasterizer.Rasterizer;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Gpu = struct {
    device: mtl.Device,
    queue: mtl.CommandQueue,
    lib: mtl.Library,
};

pub const Config = struct {
    name: []const u8 = "current",
    dither: pi.DitherMode = .true_color,
    filter: pi.TextureFilter = .bilinear,
    sprite_filter: pi.TextureFilter = .nearest,
};

pub const Result = struct {
    /// Borrowed from the `Options` the run was given.
    fixture: []const u8,
    scale: u32,
    config: []const u8,
    gpu_ms: f64,
    cpu_ms: f64,
    fps: f64,
    frames: usize,

    /// The Swift benchmark's `Result.line`, byte for byte, padding that
    /// truncates included, so the two benchmarks' output compares by eye.
    pub fn format(self: Result, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("[gpu-bench] {s:<24} {d}x {s:<10} gpu {d:>6.2} ms  cpu {d:>6.2} ms  {d:>6.1} fps  ({d} frames)", .{
            self.fixture[0..@min(self.fixture.len, 24)],
            self.scale,
            self.config[0..@min(self.config.len, 10)],
            self.gpu_ms,
            self.cpu_ms,
            self.fps,
            self.frames,
        });
    }
};

pub const Options = struct {
    fixtures: []const []const u8,
    scales: []const u32,
    configs: []const Config,
    repeats: u32,
};

/// The command line: `<fixture>[,<fixture>…]` then the flags.
pub const Args = struct {
    fixtures: []const []const u8,
    scales: []const u32,
    repeats: u32 = 5,
    config: Config = .{},

    /// Fixture names borrow from `argv`.
    pub fn parse(alloc: Allocator, argv: []const []const u8) !Args {
        var a: Args = .{ .fixtures = &.{}, .scales = &.{} };
        var list: ?[]const u8 = null;
        var scales: []const u8 = "1,4,6,8";
        for (argv) |arg| {
            if (value(arg, "--scales=")) |v| {
                scales = v;
            } else if (value(arg, "--repeats=")) |v| {
                a.repeats = std.fmt.parseInt(u32, v, 10) catch return error.BadRepeats;
                if (a.repeats == 0) return error.BadRepeats;
            } else if (value(arg, "--dither=")) |v| {
                a.config.dither = dither(v) orelse return error.BadDither;
            } else if (value(arg, "--filter=")) |v| {
                a.config.filter = filter(v) orelse return error.BadFilter;
            } else if (value(arg, "--sprite-filter=")) |v| {
                a.config.sprite_filter = filter(v) orelse return error.BadFilter;
            } else if (std.mem.startsWith(u8, arg, "--") or list != null) {
                return error.BadArgument;
            } else {
                list = arg;
            }
        }

        var names: std.ArrayList([]const u8) = .empty;
        errdefer names.deinit(alloc);
        var it = std.mem.tokenizeScalar(u8, list orelse "", ',');
        while (it.next()) |n| try names.append(alloc, n);
        if (names.items.len == 0) return error.NoFixtures;

        var nums: std.ArrayList(u32) = .empty;
        errdefer nums.deinit(alloc);
        var st = std.mem.tokenizeScalar(u8, scales, ',');
        while (st.next()) |s| {
            const n = std.fmt.parseInt(u32, s, 10) catch return error.BadScale;
            if (n < 1 or n > 8) return error.BadScale;
            try nums.append(alloc, n);
        }
        if (nums.items.len == 0) return error.BadScale;

        a.fixtures = try names.toOwnedSlice(alloc);
        a.scales = try nums.toOwnedSlice(alloc);
        return a;
    }

    pub fn deinit(self: Args, alloc: Allocator) void {
        alloc.free(self.fixtures);
        alloc.free(self.scales);
    }

    fn value(arg: []const u8, comptime prefix: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, arg, prefix)) arg[prefix.len..] else null;
    }

    fn dither(v: []const u8) ?pi.DitherMode {
        if (std.mem.eql(u8, v, "true-color")) return .true_color;
        if (std.mem.eql(u8, v, "native")) return .native;
        if (std.mem.eql(u8, v, "scaled")) return .scaled;
        if (std.mem.eql(u8, v, "off")) return .off;
        return null;
    }

    fn filter(v: []const u8) ?pi.TextureFilter {
        if (std.mem.eql(u8, v, "nearest")) return .nearest;
        if (std.mem.eql(u8, v, "bilinear")) return .bilinear;
        return null;
    }
};

/// Best of `repeats` per row, by GPU ms, in (fixture, scale, config) order.
/// Configs are interleaved inside each repeat (A, B, A, B), never run as
/// blocks: thermal drift on a fanless machine would otherwise land on one
/// config. Owned by the caller.
pub fn run(alloc: Allocator, io: Io, gpu: Gpu, o: Options) ![]Result {
    const per_fixture = o.scales.len * o.configs.len;
    const best = try alloc.alloc(?Result, o.fixtures.len * per_fixture);
    defer alloc.free(best);
    @memset(best, null);

    for (o.fixtures, 0..) |name, fi| {
        const parsed = try fixture_corpus.load(alloc, io, name);
        defer parsed.deinit(alloc);
        for (o.scales, 0..) |scale, si| {
            for (0..o.repeats) |_| {
                for (o.configs, 0..) |config, ci| {
                    const r = try measure(alloc, io, gpu, parsed, name, scale, config);
                    const slot = &best[fi * per_fixture + si * o.configs.len + ci];
                    if (slot.* == null or r.gpu_ms < slot.*.?.gpu_ms) slot.* = r;
                }
            }
        }
    }
    const out = try alloc.alloc(Result, best.len);
    for (best, out) |b, *r| r.* = b.?;
    return out;
}

/// A `MetalVram` and the rasterizer drawing into it, on the heap so the
/// rasterizer's pointer to the VRAM stays put.
const Rig = struct {
    vram: MetalVram,
    r: Rasterizer,

    fn create(alloc: Allocator, gpu: Gpu, scale: u32, config: Config) !*Rig {
        const self = try alloc.create(Rig);
        errdefer alloc.destroy(self);
        self.vram = try MetalVram.init(alloc, gpu.device, gpu.queue, scale, false);
        errdefer self.vram.deinit();
        self.r = try Rasterizer.init(alloc, &self.vram, gpu.lib);
        self.r.dither_mode = config.dither;
        self.r.texture_filter = config.filter;
        self.r.sprite_filter = config.sprite_filter;
        return self;
    }

    fn destroy(self: *Rig, alloc: Allocator) void {
        self.r.deinit();
        self.vram.deinit();
        alloc.destroy(self);
    }

    fn replay(self: *Rig, parsed: fixture.Parsed) void {
        for (0..parsed.frames.len) |i| {
            const pool = objc.Pool.push();
            defer pool.pop();
            const s = parsed.frameStream(i);
            self.r.beginFrame(s.payload);
            for (s.records) |c| self.r.apply(c);
            self.r.endFrame();
        }
    }
};

/// The command buffers a synchronous pass committed, retained. Read only
/// after each has been waited on, so the timestamps are final.
const Committed = struct {
    alloc: Allocator,
    list: std.ArrayList(mtl.CommandBuffer) = .empty,

    fn hook(ctx: *anyopaque, cmd: mtl.CommandBuffer) void {
        const self: *Committed = @ptrCast(@alignCast(ctx));
        self.list.append(self.alloc, cmd.retain()) catch @panic("gpu-bench out of memory");
    }

    fn clear(self: *Committed) void {
        for (self.list.items) |cmd| cmd.release();
        self.list.clearRetainingCapacity();
    }

    fn gpuSeconds(self: *const Committed) f64 {
        var total: f64 = 0;
        for (self.list.items) |cmd| total += @max(0, cmd.gpuEndTime() - cmd.gpuStartTime());
        return total;
    }

    fn deinit(self: *Committed) void {
        self.clear();
        self.list.deinit(self.alloc);
    }
};

fn nanosSince(io: Io, t0: Io.Timestamp) u64 {
    return @intCast(Io.Clock.now(.awake, io).nanoseconds - t0.nanoseconds);
}

fn measure(alloc: Allocator, io: Io, gpu: Gpu, parsed: fixture.Parsed, name: []const u8, scale: u32, config: Config) !Result {
    const frames = parsed.frames.len;

    // Synchronous pass: per-frame GPU and CPU cost.
    const sync = try Rig.create(alloc, gpu, scale, config);
    defer sync.destroy(alloc);
    var committed: Committed = .{ .alloc = alloc };
    defer committed.deinit();
    sync.r.synchronous = true;
    sync.r.on_commit = .{ .ctx = &committed, .f = Committed.hook };
    sync.replay(parsed); // warm-up: pipelines, caches
    committed.clear();
    var cpu_ns: u64 = 0;
    for (0..frames) |i| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = parsed.frameStream(i);
        const t0 = Io.Clock.now(.awake, io);
        sync.r.beginFrame(s.payload);
        for (s.records) |c| sync.r.apply(c);
        // CPU encode only: endFrame's synchronous wait is GPU time, and is
        // excluded by stopping the clock before it.
        cpu_ns += nanosSince(io, t0);
        sync.r.endFrame();
    }
    const gpu_seconds = committed.gpuSeconds();

    // Pipelined pass: the throughput a player gets.
    const piped = try Rig.create(alloc, gpu, scale, config);
    defer piped.destroy(alloc);
    piped.r.synchronous = false;
    piped.replay(parsed); // warm-up
    const t0 = Io.Clock.now(.awake, io);
    piped.replay(parsed);
    {
        // Commit order is completion order on one queue, so an empty buffer
        // committed last completes after every frame's.
        const pool = objc.Pool.push();
        defer pool.pop();
        const fence = gpu.queue.commandBuffer() orelse return error.NoCommandBuffer;
        fence.commit();
        fence.waitUntilCompleted();
    }
    const wall_ns = nanosSince(io, t0);

    const n: f64 = @floatFromInt(@max(frames, 1));
    return .{
        .fixture = name,
        .scale = scale,
        .config = config.name,
        .gpu_ms = gpu_seconds * 1e3 / n,
        .cpu_ms = @as(f64, @floatFromInt(cpu_ns)) / 1e6 / n,
        .fps = @as(f64, @floatFromInt(frames)) / (@as(f64, @floatFromInt(wall_ns)) / 1e9),
        .frames = frames,
    };
}
