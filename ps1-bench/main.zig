//! Wall-clock benchmark frontend.
//!
//! Boots a disc and runs N frames through the SAME vblank-to-vblank loop
//! `ps1_capi`'s `ps1_run_frame` uses, so a number here is a number the macOS
//! app would see. It exists because the alternative is arguing about
//! performance from a profile alone: a profile apportions the time it finds,
//! it does not tell you whether the total moved.
//!
//! Two things about using it, both learned the hard way. Take the BEST of
//! several runs, not one — a run started straight after `trace-golden` reads
//! about 15% slow while the machine settles. And it is only a fair A/B when
//! both sides execute the same instructions: a change that alters emulated
//! behaviour sends the game somewhere else, and the comparison is then
//! measuring two different workloads rather than two implementations.
//!
//! `--engine=cached` times a block engine through the same loop, so an engine
//! A/B is one binary with a flag.
//!
//! `threaded` attaches a raster worker and drains it once per frame, as
//! `ps1_copy_vram` does in the app.
const std = @import("std");
const ps1 = @import("ps1_core");

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.smp_allocator;

    var it = init.minimal.args.iterate();
    _ = it.skip();
    const bios_path = it.next() orelse return error.MissingArgs;
    const disc_path = it.next() orelse return error.MissingArgs;
    const frames = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArgs, 10);
    var no_copy = false;
    var pgxp = false;
    var pgxp_cpu = true;
    var engine: ps1.recompiler.Engine = .interpreter;
    var threaded = false;
    var jit_lower: ps1.recompiler.jit.Lowering = .{};
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "nocopy")) no_copy = true;
        if (std.mem.eql(u8, a, "threaded")) threaded = true;
        if (std.mem.eql(u8, a, "pgxp")) pgxp = true;
        if (std.mem.eql(u8, a, "pgxp-no-cpu")) pgxp_cpu = false;
        if (std.mem.startsWith(u8, a, "--engine=")) {
            engine = std.meta.stringToEnum(ps1.recompiler.Engine, a["--engine=".len..]) orelse return error.UnknownEngine;
        }
        if (std.mem.startsWith(u8, a, "--jit-lower=")) {
            jit_lower = try ps1.recompiler.jit.Lowering.parse(a["--jit-lower=".len..]);
        }
    }

    const cwd = std.Io.Dir.cwd();
    const io = init.io;
    const bios = try cwd.readFileAlloc(io, bios_path, alloc, .limited(1 << 20));
    defer alloc.free(bios);

    const bus = try ps1.memory.Bus.init(alloc);
    defer bus.deinit(alloc);
    @memcpy(bus.bios[0..], bios[0..524288]);
    if (comptime ps1.gpu.Sink.kind == .dual) bus.gpu.sink.rec.arm();
    bus.setPgxp(pgxp);
    bus.setPgxpCpu(pgxp_cpu);

    var bin_path: []const u8 = disc_path;
    var owned_bin: ?[]u8 = null;
    defer if (owned_bin) |p| alloc.free(p);
    var cue_text: ?[]u8 = null;
    defer if (cue_text) |c| alloc.free(c);

    if (std.mem.endsWith(u8, disc_path, ".cue")) {
        cue_text = try cwd.readFileAlloc(io, disc_path, alloc, .limited(1 << 20));
        const dir = std.fs.path.dirname(disc_path) orelse ".";
        // Take the FILE line's quoted name.
        const q1 = std.mem.indexOfScalar(u8, cue_text.?, '"') orelse return error.BadCue;
        const q2 = std.mem.indexOfScalarPos(u8, cue_text.?, q1 + 1, '"') orelse return error.BadCue;
        owned_bin = try std.fs.path.join(alloc, &.{ dir, cue_text.?[q1 + 1 .. q2] });
        bin_path = owned_bin.?;
    }

    const data = try cwd.readFileAlloc(io, bin_path, alloc, .limited(1 << 30));
    defer alloc.free(data);

    const reader: ?*ps1.chd.Reader = if (cue_text == null and ps1.chd.isChd(data)) try ps1.chd.Reader.open(alloc, data) else null;
    defer if (reader) |r| r.close();
    const disc = if (cue_text) |c|
        ps1.disc.Disc.initFromCue(c, data)
    else if (reader) |r|
        ps1.disc.Disc.initFromChd(r)
    else
        ps1.disc.Disc.init(data);
    bus.cdrom.setDisc(disc);

    var cpu = ps1.cpu.Cpu.init(bus);
    try ps1.recompiler.setEngine(&cpu, alloc, engine);
    ps1.recompiler.setLowering(cpu.bus, jit_lower);
    if (threaded) try cpu.bus.gpu.attachRasterWorker(alloc, io, .thread);
    const vram_copy = try alloc.alloc(u16, 1024 * 512);
    defer alloc.free(vram_copy);

    const t0 = std.Io.Clock.now(.awake, io);
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        while (cpu.bus.gpu.is_vblank) _ = cpu.runFor(std.math.maxInt(u32));
        while (!cpu.bus.gpu.is_vblank) _ = cpu.runFor(std.math.maxInt(u32));
        cpu.bus.gpu.syncRaster();
        if (!no_copy) @memcpy(vram_copy, cpu.bus.gpu.vram.data[0..]);
        if (comptime ps1.gpu.Sink.kind == .dual) _ = cpu.bus.gpu.sink.rec.takeFrame();
    }
    const t1 = std.Io.Clock.now(.awake, io);
    const ns: u64 = @intCast(t1.nanoseconds - t0.nanoseconds);

    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    std.debug.print("sink={s} engine={s} threaded={} copy={} pgxp={} cpu={} frames={d} wall={d:.3}s fps={d:.1} realtime={d:.2}x\n", .{
        @tagName(ps1.gpu.Sink.kind),            @tagName(engine),                                 threaded, !no_copy, pgxp, pgxp_cpu, frames, secs,
        @as(f64, @floatFromInt(frames)) / secs, (@as(f64, @floatFromInt(frames)) / secs) / 59.94,
    });
}
