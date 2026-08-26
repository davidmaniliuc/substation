const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");
const state_hash = @import("state_hash.zig");
const synthetic = @import("synthetic.zig");
const fixture = @import("fixture.zig");

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
    \\  --instructions=<n>      instructions per workload (default 600000000).
    \\                          Silently ignored for EXE (PeterLemon) workloads,
    \\                          which always run a fixed boot+run budget.
    \\  --interval=<n>          instructions between samples (default 2500000;
    \\                          ignored by stream-verify, which samples per frame)
    \\  --bios=<path>           override the auto-selected BIOS
    \\  --out=<dir>             fixture output directory (default zig-out/fixtures)
    \\  --capture-from=<instr>  (stream-capture) skip frames before this
    \\                          instruction count (default 0). For EXE
    \\                          workloads this counts from 0 at the post-boot
    \\                          sideload, NOT from the start of the run.
    \\  --frames=<n>            (stream-capture) stop after this many frames
    \\                          (default 0 = until the instruction budget runs out)
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
    capture_from: u64 = 0,
    frames: u64 = 0, // 0 = until the instruction budget runs out
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

/// The button schedule and vblank-rising-edge frame-boundary detector, shared
/// by `runStreamVerify` and `runStreamCapture`. It must be the ONE place that
/// owns this, not two copies: `stream-verify` is what proves a recorded
/// stream reconstructs VRAM, and `stream-capture` is what writes the streams
/// that get banked as fixtures, so a schedule that drifts between them would
/// silently stop describing the artifact.
const FrameStepper = struct {
    press_idx: usize = 0,
    prev_vblank: bool = false,

    /// Drives the button schedule and one `cpu.step()` for instruction `i`.
    /// Returns the drained stream when this step lands on a vblank rising
    /// edge (a frame boundary), null otherwise.
    fn step(self: *FrameStepper, i: u64, cpu: *ps1.cpu.Cpu, bus: *ps1.memory.Bus) ?ps1.gpu.command.Stream {
        if (i % press_period == 0) {
            bus.sio.setButtons(press_seq[self.press_idx]);
            self.press_idx = (self.press_idx + 1) % press_seq.len;
        }
        if (i % press_period == press_hold) bus.sio.setButtons(released);

        cpu.step();

        const vblank = bus.gpu.is_vblank;
        defer self.prev_vblank = vblank;
        if (!vblank or self.prev_vblank) return null;

        // The stream aliases the recorder's storage and is valid only until
        // emulation resumes, so callers must consume it before stepping again.
        return bus.gpu.sink.rec.takeFrame();
    }
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
    }

    const workloads = try golden.discover(a, init.io);

    var failures: usize = 0;
    var ran: usize = 0;

    for (workloads) |wl| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, wl.key, f) == null) continue;
        }
        // EXE workloads exist only for fixture capture: they have no
        // machine-state goldens, and adding them to verify would report a
        // regression that is really a missing baseline.
        if (wl.source == .exe and opts.mode != .stream_capture) continue;
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

        if (opts.mode == .stream_capture) {
            _ = runStreamCapture(wa, init.io, wl, bios_path, opts) catch |err| {
                std.debug.print("  {s: <22} ERROR {s}\n", .{ wl.key, @errorName(err) });
                failures += 1;
            };
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
        } else if (std.mem.startsWith(u8, arg, "--capture-from=")) {
            opts.capture_from = try std.fmt.parseInt(u64, arg["--capture-from=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--frames=")) {
            opts.frames = try std.fmt.parseInt(u64, arg["--frames=".len..], 10);
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

    switch (wl.source) {
        // A PS-EXE sideload attaches nothing here. It needs the BIOS booted far
        // enough to have set up its jump tables before loadExe can run, and
        // loadMachine does not own the Cpu — so the caller boots, then calls
        // sideloadExe below.
        .bios_only, .exe => {},
        .disc => |cue_path| {
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
        },
    }
}

/// PL ROMs boot the BIOS for 25M instructions to initialise its jump tables,
/// then sideload. Mirrors peterlemon_test.zig's preamble; the budget is OURS
/// and deliberately not shared with that file, since a fixture needs only to be
/// deterministic, not to match the test.
const pl_boot_instructions: u64 = 25_000_000;
const pl_run_instructions: u64 = 10_000_000;

fn sideloadExe(a: std.mem.Allocator, io: std.Io, cpu: *ps1.cpu.Cpu, exe_path: []const u8) !void {
    const exe = try std.Io.Dir.cwd().readFileAlloc(io, exe_path, a, .limited(10 << 20));
    defer a.free(exe);
    try cpu.loadExe(exe);
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

    var stepper = FrameStepper{};
    var i: u64 = 0;
    while (i < opts.instructions) : (i += 1) {
        const s = stepper.step(i, &cpu, bus) orelse continue;
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

/// Records frames into a .p1fx. Structurally `runStreamVerify` minus the
/// comparison and plus the writing: recording starts once the instruction
/// counter reaches `capture_from`, and stops after `frames` frames.
///
/// `--instructions=` is silently NOT honoured for `.exe` workloads: `budget`
/// is unconditionally overridden by `pl_run_instructions` below, on purpose
/// (Design Decision 5 — the capture tool picks its own PL budgets), and that
/// is documented in `usage` rather than diagnosed here.
fn runStreamCapture(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_path: []const u8,
    opts: Options,
) !usize {
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);
    try loadMachine(a, io, wl, bios_path, bus);

    var budget = opts.instructions;
    if (wl.source == .exe) {
        var b: u64 = 0;
        while (b < pl_boot_instructions) : (b += 1) cpu.step();
        try sideloadExe(a, io, &cpu, wl.source.exe);
        budget = pl_run_instructions;
    }

    bus.gpu.sink.rec.arm();

    // RULE: a fixture's recording window begins from a blank VRAM, not from
    // whatever the boot/pre-window run left behind. Without this, a `.exe`
    // workload's window opens on top of BIOS boot residue (25M instructions
    // of it), and `--capture-from` opens on top of the discarded frames'
    // mutations — either way a from-blank replay (what a consumer does)
    // hashes differently than what got recorded here. Blanking again after
    // every skipped frame below re-establishes this for the `--capture-from`
    // case, where the window opens partway through the run instead of here.
    bus.gpu.vram = .{};

    var w = fixture.Writer.empty;
    defer w.deinit(a);

    var stepper = FrameStepper{};
    var i: u64 = 0;
    while (i < budget) : (i += 1) {
        const s = stepper.step(i, &cpu, bus) orelse continue;
        if (!s.complete) return error.StreamOverflow;

        if (i < opts.capture_from) {
            // Still before the window: this frame's commands are discarded,
            // and its VRAM mutations must be too, so the frame that DOES
            // open the window starts from blank per the rule above.
            bus.gpu.vram = .{};
            continue;
        }

        try w.addFrame(a, s, fixture.hashVram(&bus.gpu.vram));
        if (opts.frames != 0 and w.frames.items.len >= opts.frames) break;
    }

    const bytes = try w.serialize(a);
    const path = try std.fmt.allocPrint(a, "{s}/{s}.p1fx", .{ opts.out_dir, wl.key });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    std.debug.print("  {s: <22} {d} frames   {d} bytes   WRITTEN\n", .{
        wl.key, w.frames.items.len, bytes.len,
    });
    return w.frames.items.len;
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
