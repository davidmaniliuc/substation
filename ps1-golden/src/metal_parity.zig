//! `ps1-golden-metal`: the trace workloads with Metal as the replayer.
//!
//!   ps1-golden-metal parity [--filter=<s>] [--instructions=<n>]
//!   ps1-golden-metal gpu-verify [--filter=<s>] [--record-limit=<records>]
//!
//! `parity` boots every workload as `stream-verify` does and replays each
//! frame's recorded stream through the Metal renderer at 1x, `.native`
//! dithering, both filters nearest, then requires the whole native VRAM to
//! equal the software rasterizer's. It is the prerequisite of the GPU-only
//! trace gate, which assumes exactly that equality on every workload.
//!
//! A diverging frame is counted and the texture is re-seeded from the software
//! VRAM, so one run says how MANY frames diverge, not just the first.
//!
//! `gpu-verify` is the GPU-only trace gate; see `gpu_verify.zig`.

const std = @import("std");
const ps1 = @import("ps1_core");
const ps1_metal = @import("ps1_metal");
const golden = @import("golden.zig");
const boot = @import("boot.zig");
const gpu_verify = @import("gpu_verify.zig");

const Metal = ps1_metal.metal_context.Metal;
const Rig = ps1_metal.metal_context.Rig;
const objc = ps1_metal.objc;
const native_pixels = ps1_metal.metal_vram.native_pixels;

const usage =
    \\usage: ps1-golden-metal parity [--filter=<s>] [--instructions=<n>]
    \\       ps1-golden-metal gpu-verify [--filter=<s>] [--record-limit=<records>]
    \\Run it from the repo root, built -Doptimize=ReleaseFast.
    \\
;

/// Workloads known to diverge for a reason no GPU backend can remove, each
/// with its class. Reported with its first diverging frame on every run and
/// never failing it; a workload missing here that diverges fails the run.
const known_divergences = [_]struct { key: []const u8, class: []const u8 }{};

const Options = struct {
    mode: enum { parity, gpu_verify } = .parity,
    filter: ?[]const u8 = null,
    instructions: u64 = gpu_verify.default_instructions,
    record_limit: ?usize = null,
};

const Divergence = struct {
    frame: usize,
    instr: u64,
    diff: boot.Diff,
};

const Result = struct {
    frames: usize = 0,
    diverged: usize = 0,
    first: ?Divergence = null,
    /// The frame whose recording overflowed; the run ends there.
    overflow: ?usize = null,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const opts = parseArgs(init) catch |err| {
        std.debug.print("{s}\n" ++ usage, .{@errorName(err)});
        std.process.exit(2);
    };

    const gpu = try Metal.open();
    defer gpu.deinit();
    var set = try gpu.buildPipelines();
    defer set.deinit();

    var failures: usize = 0;
    var ran: usize = 0;
    for (try golden.discover(a, init.io)) |wl| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, wl.key, f) == null) continue;
        }
        if (wl.source == .exe) continue;
        ran += 1;

        var workload_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer workload_arena.deinit();
        const wa = workload_arena.allocator();
        const failed = switch (opts.mode) {
            .parity => if (runParity(wa, init.io, wl, opts, gpu, &set)) |r| report(wl.key, r) else |err| fail(wl.key, err),
            .gpu_verify => if (gpu_verify.runWorkload(wa, init.io, wl, .{
                .instructions = opts.instructions,
                .record_limit = opts.record_limit,
            }, gpu, &set)) |r| try gpu_verify.report(wa, init.io, wl.key, .{ .instructions = opts.instructions }, r) else |err| fail(wl.key, err),
        };
        if (failed) failures += 1;
    }

    if (ran == 0) {
        std.debug.print("no workloads matched\n", .{});
        return error.NoWorkloads;
    }
    if (failures != 0) {
        std.debug.print("\n{d} workload(s) diverged\n", .{failures});
        return if (opts.mode == .parity) error.ParityDivergence else error.TraceDivergence;
    }
}

fn parseArgs(init: std.process.Init) !Options {
    var it = init.minimal.args.iterate();
    _ = it.skip();
    const mode = it.next() orelse return error.MissingMode;
    var opts = Options{};
    if (std.mem.eql(u8, mode, "gpu-verify")) {
        opts.mode = .gpu_verify;
    } else if (!std.mem.eql(u8, mode, "parity")) return error.UnknownMode;

    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--filter=")) {
            opts.filter = arg["--filter=".len..];
        } else if (std.mem.startsWith(u8, arg, "--instructions=")) {
            opts.instructions = try std.fmt.parseInt(u64, arg["--instructions=".len..], 10);
        } else if (opts.mode == .gpu_verify and std.mem.startsWith(u8, arg, "--record-limit=")) {
            opts.record_limit = try std.fmt.parseInt(usize, arg["--record-limit=".len..], 10);
        } else return error.UnknownArgument;
    }
    return opts;
}

fn runParity(
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
    bus.gpu.sink.rec.arm();

    const rig = try Rig.create(a, gpu, .{ .scale = 1, .depth_buffer = false, .set = set });
    defer rig.destroy();
    rig.r.dither_mode = .native;
    rig.r.texture_filter = .nearest;
    rig.r.sprite_filter = .nearest;
    rig.r.synchronous = true;

    // At 1x the texture is the native VRAM, so it compares as a `Vram`.
    const metal = try a.create(ps1.gpu.Vram);
    metal.* = .{};

    var result = Result{};
    var stepper = boot.FrameStepper{};
    while (stepper.i < opts.instructions) {
        const f = stepper.step(&cpu, bus) orelse continue;
        const s = f.stream;
        result.frames += 1;
        if (!s.complete) {
            result.overflow = result.frames;
            return result;
        }

        const pool = objc.Pool.push();
        defer pool.pop();
        rig.frame(s.payload, s.records);
        rig.vram.readbackNative(&metal.data);
        if (boot.firstDiff(&bus.gpu.vram, metal)) |d| {
            result.diverged += 1;
            if (result.first == null) result.first = .{ .frame = result.frames, .instr = f.at, .diff = d };
            rig.vram.upload(&bus.gpu.vram.data);
        }
    }
    return result;
}

fn fail(key: []const u8, err: anyerror) bool {
    std.debug.print("  {s: <22} ERROR {s}\n", .{ key, @errorName(err) });
    return true;
}

fn knownClass(key: []const u8) ?[]const u8 {
    for (known_divergences) |k| {
        if (std.mem.eql(u8, k.key, key)) return k.class;
    }
    return null;
}

/// Returns true when the workload failed.
fn report(key: []const u8, r: Result) bool {
    if (r.overflow) |frame| {
        std.debug.print("  {s: <22} OVERFLOW @ frame {d}\n", .{ key, frame });
        return true;
    }
    const first = r.first orelse {
        std.debug.print("  {s: <22} {d} frames  OK\n", .{ key, r.frames });
        return false;
    };
    const class = knownClass(key);
    std.debug.print("  {s: <22} {s}DIVERGED in {d} of {d} frames, first @ frame {d} (instr {d}): {d} px, first ({d},{d}) metal={x:0>4} software={x:0>4}\n", .{
        key,
        if (class != null) "EXCLUDED, " else "",
        r.diverged,
        r.frames,
        first.frame,
        first.instr,
        first.diff.pixels,
        first.diff.index % 1024,
        first.diff.index / 1024,
        first.diff.got,
        first.diff.want,
    });
    if (class) |c| {
        std.debug.print("  {s: <22} EXCLUDED ({s})\n", .{ key, c });
        return false;
    }
    return true;
}
