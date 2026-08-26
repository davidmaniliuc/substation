const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");
const state_hash = @import("state_hash.zig");
const synthetic = @import("synthetic.zig");

const default_instructions: u64 = 600_000_000;
const default_interval: u64 = 2_500_000;
const goldens_dir = "ps1-core/tests/goldens/trace";

const usage =
    \\usage: ps1-golden <capture|verify|stream-verify|stream-capture> [options]
    \\
    \\  capture         rewrite the machine-state goldens
    \\  verify          diff machine state against the goldens
    \\  stream-verify   replay each frame's recorded GP0 command stream into a
    \\                  shadow VRAM and require full-VRAM equality with the
    \\                  software rasterizer
    \\  stream-capture  write .p1fx fixtures of the recorded command stream
    \\
    \\  --filter=<substring>    only run workloads whose key contains this
    \\  --instructions=<n>      instructions per workload (default 600000000)
    \\  --interval=<n>          instructions between samples (default 2500000;
    \\                          ignored by stream-verify, which samples per frame)
    \\  --bios=<path>           override the auto-selected BIOS
    \\  --out=<dir>             fixture output directory (default zig-out/fixtures)
    \\
;

const Mode = enum { capture, verify, stream_verify, stream_capture };

const Options = struct {
    mode: Mode,
    filter: ?[]const u8 = null,
    instructions: u64 = default_instructions,
    interval: u64 = default_interval,
    bios_override: ?[]const u8 = null,
    out_dir: []const u8 = "zig-out/fixtures",
};

const RunResult = struct {
    samples: []golden.Sample,
    static_before: u64,
    static_after: u64,
};

/// The same deterministic button script ps1-trace uses: Start, Cross, Circle in
/// rotation so intros, FMVs and title menus are walked past. Driven off the
/// instruction counter, never a wall clock.
const press_period: u64 = 4_000_000;
const press_hold: u64 = 1_000_000;
const released: u16 = 0xFFFF;
const press_seq = [_]u16{
    released & ~@as(u16, 1 << 3), // Start
    released & ~@as(u16, 1 << 14), // Cross
    released & ~@as(u16, 1 << 13), // Circle
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const opts = parseArgs(init) catch {
        std.debug.print("{s}", .{usage});
        return error.BadArguments;
    };

    if (opts.mode == .stream_capture) {
        try std.Io.Dir.cwd().createDirPath(init.io, opts.out_dir);

        // The synthetic fixture is not a workload: no BIOS, no disc, no CPU.
        // It is also the only one committed to git, because it is the only one
        // whose hashes the Swift side can verify without a rasterizer.
        const bytes = try synthetic.build(a);
        const path = try std.fmt.allocPrint(a, "{s}/synthetic-movers.p1fx", .{opts.out_dir});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
        std.debug.print("  {s: <22} {d} bytes   WRITTEN\n", .{ "synthetic-movers", bytes.len });

        // The synthetic fixture is the ONLY thing stream-capture writes until
        // Task 5 adds runStreamCapture, so returning here keeps the mode out of
        // the workload loop — which would otherwise boot all ten workloads for
        // 600M instructions apiece and then hit the `unreachable` below.
        // Task 5 deletes this `return`.
        return;
    }

    const workloads = try golden.discover(a, init.io);

    var failures: usize = 0;
    var ran: usize = 0;

    for (workloads) |wl| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, wl.key, f) == null) continue;
        }
        ran += 1;

        // Each workload gets its own arena so a finished disc image (up to
        // ~700 MB) is actually returned to the allocator before the next
        // workload loads its own — the outer arena lives for the whole
        // process and would otherwise retain every workload's Bus/BIOS/cue/
        // disc buffer simultaneously. Torn down after this workload's golden
        // is written/verified, since `result.samples` (and the text
        // `writeGolden`/`verifyGolden` build from it) are allocated from it.
        var workload_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer workload_arena.deinit();
        const wa = workload_arena.allocator();

        const bios_path = opts.bios_override orelse wl.bios_path;

        if (opts.mode == .stream_verify) {
            const sr = runStreamVerify(wa, init.io, wl, bios_path, opts) catch |err| {
                std.debug.print("  {s: <22} ERROR {s}\n", .{ wl.key, @errorName(err) });
                failures += 1;
                continue;
            };
            if (reportStream(wl.key, sr)) failures += 1;
            continue;
        }

        const result = runWorkload(wa, init.io, wl, bios_path, opts) catch |err| {
            std.debug.print("  {s: <22} ERROR {s}\n", .{ wl.key, @errorName(err) });
            failures += 1;
            continue;
        };

        switch (opts.mode) {
            .capture => {
                try writeGolden(wa, init.io, wl.key, opts, result);
                std.debug.print("  {s: <22} {d}M instr  {d} hashes   CAPTURED\n", .{
                    wl.key, opts.instructions / 1_000_000, result.samples.len,
                });
            },
            .verify => {
                if (try verifyGolden(wa, init.io, wl.key, opts, result)) failures += 1;
            },
            .stream_verify, .stream_capture => unreachable, // handled above
        }
    }

    if (ran == 0) {
        std.debug.print("no workloads matched\n", .{});
        return error.NoWorkloads;
    }
    if (failures != 0) {
        std.debug.print("\n{d} workload(s) diverged\n", .{failures});
        return error.TraceDivergence;
    }
}

fn parseArgs(init: std.process.Init) !Options {
    var it = init.minimal.args.iterate();
    _ = it.skip();
    const mode = it.next() orelse return error.MissingMode;

    var opts = Options{ .mode = if (std.mem.eql(u8, mode, "capture"))
        .capture
    else if (std.mem.eql(u8, mode, "verify"))
        .verify
    else if (std.mem.eql(u8, mode, "stream-verify"))
        .stream_verify
    else if (std.mem.eql(u8, mode, "stream-capture"))
        .stream_capture
    else
        return error.UnknownMode };

    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--filter=")) {
            opts.filter = arg["--filter=".len..];
        } else if (std.mem.startsWith(u8, arg, "--instructions=")) {
            opts.instructions = try std.fmt.parseInt(u64, arg["--instructions=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--interval=")) {
            opts.interval = try std.fmt.parseInt(u64, arg["--interval=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--bios=")) {
            opts.bios_override = arg["--bios=".len..];
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            opts.out_dir = arg["--out=".len..];
        } else {
            return error.UnknownOption;
        }
    }
    if (opts.interval == 0) return error.BadArguments;
    return opts;
}

/// BIOS, disc image, cue and LibCrypt sidecar. Shared by `runWorkload` and
/// `runStreamVerify`; the two differ only in what they do with the machine.
fn loadMachine(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_path: []const u8,
    bus: *ps1.memory.Bus,
) !void {
    const bios = try std.Io.Dir.cwd().readFileAlloc(io, bios_path, a, .limited(1 << 20));
    defer a.free(bios);
    if (bios.len != 512 * 1024) return error.BadBiosSize;
    @memcpy(bus.bios[0..], bios);

    if (wl.cue_path) |cue_path| {
        const cue_text = try std.Io.Dir.cwd().readFileAlloc(io, cue_path, a, .limited(1 << 20));
        const bin_path = try std.fmt.allocPrint(a, "{s}.bin", .{cue_path[0 .. cue_path.len - 4]});
        const bin_bytes = try std.Io.Dir.cwd().readFileAlloc(io, bin_path, a, .limited(900 * 1024 * 1024));
        var d = ps1.disc.Disc.initFromCue(cue_text, bin_bytes);

        // A LibCrypt disc without its `.sbi` never gets past its own protection
        // check, so a run without one records a loop, not a boot.
        const sbi_path = try std.fmt.allocPrint(a, "{s}.sbi", .{cue_path[0 .. cue_path.len - 4]});
        if (std.Io.Dir.cwd().readFileAlloc(io, sbi_path, a, .limited(1 << 20))) |sbi| {
            d.setSbi(sbi);
        } else |_| {}

        bus.cdrom.setDisc(d);
    }
}

fn runWorkload(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_path: []const u8,
    opts: Options,
) !RunResult {
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);
    try loadMachine(a, io, wl, bios_path, bus);

    const static_before = state_hash.hashStatic(bus);

    var samples = std.ArrayList(golden.Sample).empty;
    var press_idx: usize = 0;
    var i: u64 = 0;
    while (i < opts.instructions) : (i += 1) {
        if (i % press_period == 0) {
            bus.sio.setButtons(press_seq[press_idx]);
            press_idx = (press_idx + 1) % press_seq.len;
        }
        if (i % press_period == press_hold) bus.sio.setButtons(released);

        cpu.step();

        if ((i + 1) % opts.interval == 0) {
            var s = golden.Sample{ .instr = i + 1, .hashes = undefined };
            state_hash.hashAll(&cpu, &s.hashes);
            try samples.append(a, s);
        }
    }

    return .{
        .samples = try samples.toOwnedSlice(a),
        .static_before = static_before,
        .static_after = state_hash.hashStatic(bus),
    };
}

const StreamResult = struct {
    frames: usize,
    /// The largest single-frame record and payload counts seen. Printed on
    /// success as well as failure: it is the only measurement we have of
    /// whether recorder.max_records and max_payload_words are sized right,
    /// and Phase B sizes its Metal buffers off it.
    peak_records: usize,
    peak_payload: usize,
    failure: ?Failure,
};

const Failure = struct {
    frame: usize,
    instr: u64,
    reason: enum { overflow, pixels },
    diff_pixels: usize = 0,
    first_x: usize = 0,
    first_y: usize = 0,
    want: u16 = 0,
    got: u16 = 0,
};

const Diff = struct { pixels: usize, index: usize, want: u16, got: u16 };

/// The equality fast path is load-bearing, not a micro-optimisation. This runs
/// once per emulated FRAME — on the order of 25,000 frames across the ten
/// workloads — and the counting loop below cannot vectorise: it carries a
/// dependency and an early-exit branch, so it is ~10^10 scalar compares on top
/// of a replay that already doubles every rasterisation. `std.mem.eql` lowers
/// to a vectorised memcmp and covers the case that holds on every frame except
/// the failing one.
fn firstDiff(want: *const ps1.gpu.Vram, got: *const ps1.gpu.Vram) ?Diff {
    if (std.mem.eql(u16, &want.data, &got.data)) return null;

    var found: ?Diff = null;
    var count: usize = 0;
    for (want.data, got.data, 0..) |w, g, i| {
        if (w == g) continue;
        count += 1;
        if (found == null) found = .{ .pixels = 0, .index = i, .want = w, .got = g };
    }
    if (found) |*d| {
        d.pixels = count;
        return d.*;
    }
    return null;
}

/// One flat, greppable line per record. When this fires it IS the debugging
/// session, the same way `verify`'s per-region attribution is.
fn dumpCommand(cmd: ps1.gpu.command.Command) void {
    std.debug.print(
        "      {s: <28} op={x:0>2} tr={d} val={x:0>8} clut={x:0>4} tpage={x:0>4} " ++
            "x={d} y={d} x2={d} y2={d} w={d} h={d} " ++
            "v0=({d},{d},{d},{d},{x:0>6}) v1=({d},{d},{d},{d},{x:0>6}) v2=({d},{d},{d},{d},{x:0>6})\n",
        .{
            @tagName(cmd.kind), cmd.opcode, cmd.transparent, cmd.value,      cmd.clut,       cmd.tpage,
            cmd.x,              cmd.y,      cmd.x2,          cmd.y2,         cmd.w,          cmd.h,
            cmd.v[0].x,         cmd.v[0].y, cmd.v[0].u,      cmd.v[0].v,     cmd.v[0].color, cmd.v[1].x,
            cmd.v[1].y,         cmd.v[1].u, cmd.v[1].v,      cmd.v[1].color, cmd.v[2].x,     cmd.v[2].y,
            cmd.v[2].u,         cmd.v[2].v, cmd.v[2].color,
        },
    );
}

fn runStreamVerify(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_path: []const u8,
    opts: Options,
) !StreamResult {
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);
    try loadMachine(a, io, wl, bios_path, bus);

    bus.gpu.sink.rec.arm();

    // The shadow starts where the rasterizer's VRAM starts: all zeros, default
    // drawing environment. Every mutation from then on arrives through the
    // stream, so the two stay in step for the WHOLE run rather than being
    // resynced per frame — which is what makes a divergence attributable to
    // the frame that caused it instead of to the frame that noticed it.
    const shadow = try a.create(ps1.gpu.Vram);
    shadow.* = .{};
    var shadow_env: ps1.gpu.Regs.DrawingEnv = .{};

    var result = StreamResult{
        .frames = 0,
        .peak_records = 0,
        .peak_payload = 0,
        .failure = null,
    };

    var prev_vblank = false;
    var press_idx: usize = 0;
    var i: u64 = 0;
    while (i < opts.instructions) : (i += 1) {
        if (i % press_period == 0) {
            bus.sio.setButtons(press_seq[press_idx]);
            press_idx = (press_idx + 1) % press_seq.len;
        }
        if (i % press_period == press_hold) bus.sio.setButtons(released);

        cpu.step();

        const vblank = bus.gpu.is_vblank;
        defer prev_vblank = vblank;
        if (!vblank or prev_vblank) continue;

        // The stream aliases the recorder's storage and is valid only until
        // emulation resumes, so it is consumed here, before the next step().
        const s = bus.gpu.sink.rec.takeFrame();
        result.frames += 1;
        result.peak_records = @max(result.peak_records, s.records.len);
        result.peak_payload = @max(result.peak_payload, s.payload.len);

        if (!s.complete) {
            result.failure = .{ .frame = result.frames, .instr = i, .reason = .overflow };
            return result;
        }

        ps1.gpu.command.replay(s, shadow, &shadow_env);

        if (firstDiff(&bus.gpu.vram, shadow)) |d| {
            std.debug.print("  {s: <22} frame {d}: {d} records (first 64 shown)\n", .{
                wl.key, result.frames, s.records.len,
            });
            for (s.records[0..@min(s.records.len, 64)]) |cmd| dumpCommand(cmd);
            result.failure = .{
                .frame = result.frames,
                .instr = i,
                .reason = .pixels,
                .diff_pixels = d.pixels,
                .first_x = d.index % 1024,
                .first_y = d.index / 1024,
                .want = d.want,
                .got = d.got,
            };
            return result;
        }
    }
    return result;
}

/// Returns true when the workload failed.
fn reportStream(key: []const u8, r: StreamResult) bool {
    if (r.failure) |f| {
        switch (f.reason) {
            .overflow => std.debug.print(
                "  {s: <22} OVERFLOW @ frame {d} (instr {d}) — raise recorder.max_records / max_payload_words\n",
                .{ key, f.frame, f.instr },
            ),
            .pixels => std.debug.print(
                "  {s: <22} DIVERGED @ frame {d} (instr {d}): {d} px, first ({d},{d}) raster={x:0>4} replay={x:0>4}\n",
                .{ key, f.frame, f.instr, f.diff_pixels, f.first_x, f.first_y, f.want, f.got },
            ),
        }
        return true;
    }
    std.debug.print("  {s: <22} {d} frames   peak {d} rec / {d} payload   OK\n", .{
        key, r.frames, r.peak_records, r.peak_payload,
    });
    return false;
}

fn goldenPath(a: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.txt", .{ goldens_dir, key });
}

fn writeGolden(
    a: std.mem.Allocator,
    io: std.Io,
    key: []const u8,
    opts: Options,
    result: RunResult,
) !void {
    if (result.static_before != result.static_after) {
        std.debug.print(
            "  {s: <22} WARNING: BIOS/expansion memory changed during the run\n",
            .{key},
        );
    }
    const text = try golden.serialize(a, .{
        .workload = key,
        .instructions = opts.instructions,
        .interval = opts.interval,
        .samples = result.samples,
    });
    defer a.free(text);
    const path = try goldenPath(a, key);
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// Returns true when the workload diverged. Reports the first differing sample
/// and every region that moved in it — "first diff: cdrom" is the whole
/// debugging session, which is why regions are hashed separately.
fn verifyGolden(
    a: std.mem.Allocator,
    io: std.Io,
    key: []const u8,
    opts: Options,
    result: RunResult,
) !bool {
    const path = try goldenPath(a, key);
    defer a.free(path);

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 << 20)) catch {
        std.debug.print("  {s: <22} NO GOLDEN — run `capture` first\n", .{key});
        return true;
    };
    defer a.free(text);

    const want = golden.parse(a, text) catch |err| {
        std.debug.print("  {s: <22} MALFORMED: {s}\n", .{ key, @errorName(err) });
        return true;
    };
    defer a.free(want.samples);

    // Check that BIOS/expansion RAM did not change during the run.
    if (result.static_before != result.static_after) {
        std.debug.print(
            "  {s: <22} DIVERGED: BIOS/expansion memory changed during run\n",
            .{key},
        );
        return true;
    }

    if (want.instructions != opts.instructions or want.interval != opts.interval) {
        std.debug.print(
            "  {s: <22} SKIP: golden is {d} instr @ {d}, run is {d} @ {d}\n",
            .{ key, want.instructions, want.interval, opts.instructions, opts.interval },
        );
        return true;
    }

    if (want.samples.len != result.samples.len) {
        std.debug.print(
            "  {s: <22} FAIL: {d} samples, golden has {d}\n",
            .{ key, result.samples.len, want.samples.len },
        );
        return true;
    }

    for (want.samples, result.samples) |exp, got| {
        // Verify instruction counts match before comparing hashes.
        if (exp.instr != got.instr) {
            std.debug.print("  {s: <22} FAIL: sample misalignment @ expected instr {d}, got {d}\n", .{
                key, exp.instr, got.instr,
            });
            return true;
        }

        if (std.mem.eql(u64, &exp.hashes, &got.hashes)) continue;

        std.debug.print("  {s: <22} {d}M instr   {d} hashes   FAIL @ instr {d}\n", .{
            key, opts.instructions / 1_000_000, result.samples.len, got.instr,
        });
        for (exp.hashes, got.hashes, golden.region_names) |e, g, name| {
            if (e != g) {
                std.debug.print("                         {s}: want {x:0>16}, got {x:0>16}\n", .{ name, e, g });
            }
        }
        return true;
    }

    std.debug.print("  {s: <22} {d}M instr   {d} hashes   OK\n", .{
        key, opts.instructions / 1_000_000, result.samples.len,
    });
    return false;
}
