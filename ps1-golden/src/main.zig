const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");
const state_hash = @import("state_hash.zig");
const synthetic = @import("synthetic.zig");
const synthetic_prims = @import("synthetic_prims.zig");
const fixture = @import("fixture.zig");
const script = @import("script.zig");
const env_sync = @import("env_sync.zig");
const pgxp_sweep = @import("pgxp_sweep.zig");

const default_instructions: u64 = 600_000_000;
const default_interval: u64 = 2_500_000;
const goldens_dir = "ps1-core/tests/goldens/trace";
const pgxp_floors_path = "ps1-core/tests/goldens/pgxp/floors.txt";

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
    \\  --probe                 (stream-capture) print one PROBE line per frame
    \\                          instead of writing a fixture. Six columns:
    \\                          instruction, record count, payload words, draw
    \\                          records, textured rectangles, VRAM->VRAM copies.
    \\  --cue=<path> --key=<name>  (stream-capture) capture ONE named disc
    \\                          instead of the discovered workloads. The only
    \\                          way to reach a multi-disc game: discover() skips
    \\                          them, and deepening its glob would mint new
    \\                          verify workloads with no goldens.
    \\  --pgxp-on               (stream-capture) capture with PGXP enabled
    \\  --memcard=<path.mcd>    (stream-capture) install a card into slot 1
    \\  --input=<schedule>      (stream-capture) a script.zig pad schedule,
    \\                          "700:circle;730:cross", keyed in MILLIONS of
    \\                          instructions. Owns the pad when present.
    \\  --dump-frame=<n>        (stream-capture) also write frame <n>'s reference
    \\                          VRAM as a raw 1 MB blob to `<out>/<key>-frame<n>.vram`
    \\
;

const Mode = enum { capture, verify, stream_verify, stream_capture, pgxp };

const Options = struct {
    mode: Mode,
    filter: ?[]const u8 = null,
    instructions: u64 = default_instructions,
    interval: u64 = default_interval,
    bios_override: ?[]const u8 = null,
    out_dir: []const u8 = "zig-out/fixtures",
    capture_from: u64 = 0,
    frames: u64 = 0, // 0 = until the instruction budget runs out
    probe: bool = false,
    dump_frame: ?u64 = null,
    /// An AD-HOC capture workload: a disc named directly rather than
    /// discovered. `discover` walks `games/*/` one level deep and skips a
    /// directory holding more than one `.cue`, which between them exclude every
    /// multi-disc game — Final Fantasy VII keeps each disc in its own subfolder,
    /// so nothing under it is ever a workload. Rather than deepen the glob,
    /// which would mint new `verify` workloads and demand new goldens for them,
    /// stream-capture can be pointed straight at a cue. Capture is a producer;
    /// it owns no goldens, so an ad-hoc target costs nothing downstream.
    cue: ?[]const u8 = null,
    /// The fixture's name, and therefore its filename. Required with `--cue`,
    /// since there is no directory to derive one from.
    key: ?[]const u8 = null,
    /// A `.mcd` image installed into slot 1 before boot. A game with a save is
    /// a different program from a game without one: it reaches scenes a fresh
    /// boot cannot, which is the entire reason this exists.
    memcard: ?[]const u8 = null,
    /// A `script.zig` pad schedule. When given it OWNS the pad for the run.
    input: ?[]const u8 = null,
    /// Capture with PGXP ON. The record a replay consumes carries the sub-pixel
    /// positions gp0 resolved, so a fixture captured with PGXP off cannot
    /// reproduce a PGXP-on frame — and PGXP-on is a shipping player setting.
    pgxp_on: bool = false,
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
    /// A scripted schedule, which OWNS the pad when present: the rotating
    /// Start/Cross/Circle below cannot work a menu, and two schedulers fighting
    /// over one button mask is not reproducible.
    script: []const script.Press = &.{},
    script_idx: usize = 0,

    /// Drives the button schedule and one `cpu.step()` for instruction `i`.
    /// Returns the drained stream when this step lands on a vblank rising
    /// edge (a frame boundary), null otherwise.
    fn step(self: *FrameStepper, i: u64, cpu: *ps1.cpu.Cpu, bus: *ps1.memory.Bus) ?ps1.gpu.command.Stream {
        if (self.script.len > 0) {
            if (script.maskAt(self.script, &self.script_idx, i, press_hold)) |m| bus.sio.setButtons(m);
        } else {
            if (i % press_period == 0) {
                bus.sio.setButtons(press_seq[self.press_idx]);
                self.press_idx = (self.press_idx + 1) % press_seq.len;
            }
            if (i % press_period == press_hold) bus.sio.setButtons(released);
        }

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

        const prim_bytes = try synthetic_prims.build(a);
        const prim_path = try std.fmt.allocPrint(a, "{s}/synthetic-primitives.p1fx", .{opts.out_dir});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = prim_path, .data = prim_bytes });
        std.debug.print("  {s: <22} {d} bytes   WRITTEN\n", .{ "synthetic-primitives", prim_bytes.len });
    }

    // An ad-hoc `--cue` REPLACES discovery rather than adding to it: the point
    // is to capture one named disc, and running the whole library alongside it
    // would take an hour to produce the one fixture that was asked for.
    const workloads = if (opts.cue) |cue_path| blk: {
        const one = try a.alloc(golden.Workload, 1);
        one[0] = .{
            .key = opts.key.?,
            .source = .{ .disc = cue_path },
            .bios_path = golden.biosForKey(opts.key.?),
        };
        break :blk one;
    } else try golden.discover(a, init.io);
    const floors = if (opts.mode == .pgxp) try readFloors(a, init.io) else &[_]pgxp_sweep.Floor{};

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

        if (opts.mode == .pgxp) {
            const pr = runPgxp(wa, init.io, wl, bios_path, opts) catch |err| {
                std.debug.print("  {s: <22} ERROR {s}\n", .{ wl.key, @errorName(err) });
                failures += 1;
                continue;
            };
            if (pgxp_sweep.report(wl.key, pr, floors)) failures += 1;
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
            .stream_verify, .stream_capture, .pgxp => unreachable, // handled above
        }
    }

    if (ran == 0) {
        std.debug.print("no workloads matched\n", .{});
        // Fatal for the gates — a filter that selects nothing there means the
        // run proved nothing and must not read as green. Not fatal for
        // stream-capture, which is a producer: `games/` is gitignored, so
        // `zig build fixtures`' `--filter=croc` run matches nothing on any
        // machine but the author's, and by then the PL fixtures and the
        // committed synthetic one have already been written.
        if (opts.mode != .stream_capture) return error.NoWorkloads;
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
    else if (std.mem.eql(u8, mode, "pgxp"))
        .pgxp
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
        } else if (std.mem.eql(u8, arg, "--probe")) {
            opts.probe = true;
        } else if (std.mem.startsWith(u8, arg, "--dump-frame=")) {
            opts.dump_frame = try std.fmt.parseInt(u64, arg["--dump-frame=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--cue=")) {
            opts.cue = arg["--cue=".len..];
        } else if (std.mem.startsWith(u8, arg, "--key=")) {
            opts.key = arg["--key=".len..];
        } else if (std.mem.startsWith(u8, arg, "--memcard=")) {
            opts.memcard = arg["--memcard=".len..];
        } else if (std.mem.startsWith(u8, arg, "--input=")) {
            opts.input = arg["--input=".len..];
        } else if (std.mem.eql(u8, arg, "--pgxp-on")) {
            opts.pgxp_on = true;
        } else {
            return error.UnknownOption;
        }
    }
    if (opts.interval == 0) return error.BadArguments;
    // `--cue` and `--key` are one option in two halves: the key is the fixture's
    // filename and there is no directory to fall back on.
    if ((opts.cue == null) != (opts.key == null)) return error.BadArguments;
    if (opts.cue != null and opts.mode != .stream_capture) return error.BadArguments;
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

/// The reference half of the pixel-wise diff. Raw little-endian u16, row-major,
/// full 1024x512 — no header, because the Swift side reads it into a fixed-size
/// array and a header would be one more thing two languages could disagree on.
fn dumpFrame(a: std.mem.Allocator, io: std.Io, opts: Options, key: []const u8, index: usize, vram: *const ps1.gpu.Vram) !void {
    const n = opts.dump_frame orelse return;
    if (index != n) return;
    const path = try std.fmt.allocPrint(a, "{s}/{s}-frame{d}.vram", .{ opts.out_dir, key, n });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.sliceAsBytes(vram.data[0..]) });
    std.debug.print("  {s: <22} frame {d} VRAM dumped\n", .{ key, n });
}

/// PL ROMs boot the BIOS for 25M instructions to initialise its jump tables,
/// then sideload. Mirrors peterlemon_test.zig's preamble; the budget is OURS
/// and deliberately not shared with that file, since a fixture needs only to be
/// deterministic, not to match the test.
const pl_boot_instructions: u64 = 25_000_000;
const pl_run_instructions: u64 = 10_000_000;

/// A fixture's capture window, pinned by INSTRUCTION rather than by frame
/// ordinal: ps1-golden's button schedule is instruction-indexed, so an
/// instruction is reproducible and a frame number is not.
///
/// Croc's window is the densest 200 frames of A0 PAYLOAD in a 600M-instruction
/// run — i.e. where the FMV is. It contains zero draw records, which is
/// correct for what it exists to cover (the memory movers at real-game
/// payload sizes) and is why the other two entries exist at all.
///
/// The other two are the densest 100 frames of DRAW records among 8 candidate
/// discs, measured with `stream-capture --probe` on 2026-08-27, restricted to
/// candidates whose window has a non-zero `textured_rects` (the point of this
/// task): silent-hill-usa (84,045 draws, 132 textured rects, 100 copies) and
/// tr1-usa-v1-1 (13,419 draws, 979 textured rects, 0 copies) beat every other
/// disc that also had textured rects (metal-gear-solid, 8,946 draws) and every
/// disc with more raw draws but zero textured rects (crash-bandicoot-2, 105,752;
/// spyro, 96,246; crash-bandicoot-warped, 88,676; crash-bandicoot-europe-edc,
/// 50,504; resident-evil-usa, 9,192). 100 rather than 200 because a
/// geometry-dense frame carries up to 3,715 records: 200 frames of that is a
/// ~53 MB build artifact for no extra coverage.
///
/// The silent-hill-usa figures above are what the SHIPPED FIXTURE actually
/// contains, not the `--probe` sum over its picked window — the two can
/// legitimately differ. `--probe` counts every frame from `capture_from`
/// onward, but `stream-capture` doesn't open the window there: it holds off
/// until the first frame boundary at or after `capture_from` where
/// `vram.write_active` is false on both sides (see the RULE comment below),
/// so a `capture_from` that lands mid-transfer shifts the real window a few
/// frames later than what was probed. tr1-usa-v1-1 happened to open exactly
/// on its probed boundary, so its two sets of numbers match exactly; treat
/// that as luck, not a guarantee, when picking a window from a probe log.
const PinnedWindow = struct {
    key_substring: []const u8,
    capture_from: u64,
    frames: u64,
};

const pinned_windows = [_]PinnedWindow{
    .{ .key_substring = "croc", .capture_from = 166638789, .frames = 200 },
    .{ .key_substring = "silent-hill", .capture_from = 529697586, .frames = 100 },
    .{ .key_substring = "tr1", .capture_from = 346354412, .frames = 100 },
};

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
            // The CDROM defers its timers between events (see `pending_cycles`
            // there), so settle them first. This is not a nudge to make a
            // mismatch go away: settling cannot fire anything — the guard only
            // ever skips cycles no deadline falls inside — and it leaves the
            // timers holding exactly what a per-instruction tick would have
            // left them holding, which is what lets the goldens captured
            // before that rewrite still verify it.
            bus.cdrom.catchUp();

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

/// `runWorkload` with three differences: PGXP is on, no state-hash samples are
/// taken at all (PGXP-on state has no golden and never will), and the GP0
/// vertex counters are read at the end.
fn runPgxp(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_path: []const u8,
    opts: Options,
) !pgxp_sweep.Report {
    const bus = try ps1.memory.Bus.init(a);
    defer bus.deinit(a);
    var cpu = ps1.cpu.Cpu.init(bus);
    try loadMachine(a, io, wl, bios_path, bus);
    bus.setPgxp(true);

    var press_idx: usize = 0;
    var i: u64 = 0;
    while (i < opts.instructions) : (i += 1) {
        if (i % press_period == 0) {
            bus.sio.setButtons(press_seq[press_idx]);
            press_idx = (press_idx + 1) % press_seq.len;
        }
        if (i % press_period == press_hold) bus.sio.setButtons(released);

        cpu.step();
    }

    const p = bus.gpu.gp0.pgxp;
    return .{
        .vertices = p.vertices,
        .resolved = p.resolved,
        .identity_fail = p.identity_fail,
        .disp_sum = p.disp_sum,
        .disp_max = p.disp_max,
        .mixed_primitives = p.mixed_primitives,
        .thin_primitives = p.thin_primitives,
        .welded = p.welded,
        .weld_collisions = p.weld_collisions,
    };
}

/// An absent or unreadable floors file is EMPTY, not fatal: every workload
/// then reports WARN and the sweep still prints its numbers, which is what a
/// first measurement needs.
fn readFloors(a: std.mem.Allocator, io: std.Io) ![]pgxp_sweep.Floor {
    const text = std.Io.Dir.cwd().readFileAlloc(io, pgxp_floors_path, a, .limited(1 << 20)) catch |err| {
        std.debug.print("[golden] no {s} ({s}); every workload reports WARN\n", .{
            pgxp_floors_path, @errorName(err),
        });
        return &[_]pgxp_sweep.Floor{};
    };
    return pgxp_sweep.parseFloors(a, text);
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

/// Per-frame census columns for `--probe`. `draws` counts the seven
/// rasterizing kinds; `textured_rects` and `copies` are called out separately
/// because they were absent from the WHOLE Phase A2 corpus, and a window that
/// contains neither is not a real-game gate no matter how many triangles it
/// has.
const Census = struct {
    draws: usize = 0,
    textured_rects: usize = 0,
    copies: usize = 0,

    fn count(records: []const ps1.gpu.command.Command) Census {
        var c = Census{};
        for (records) |cmd| {
            switch (cmd.kind) {
                .draw_triangle,
                .draw_shaded_triangle,
                .draw_textured_triangle,
                .draw_rectangle,
                .draw_textured_rectangle,
                .draw_line,
                .draw_shaded_line,
                => c.draws += 1,
                else => {},
            }
            switch (cmd.kind) {
                .draw_textured_rectangle => c.textured_rects += 1,
                .copy_rect => c.copies += 1,
                else => {},
            }
        }
        return c;
    }
};

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

    // A pinned window applies only when neither flag is given, so an explicit
    // `--capture-from`/`--frames` on the command line still overrides it.
    var capture_from = opts.capture_from;
    var frame_limit = opts.frames;
    if (capture_from == 0 and frame_limit == 0) {
        for (pinned_windows) |p| {
            if (std.mem.indexOf(u8, wl.key, p.key_substring) != null) {
                capture_from = p.capture_from;
                frame_limit = p.frames;
                break;
            }
        }
    }

    bus.setPgxp(opts.pgxp_on);

    if (opts.memcard) |path| {
        const img = try std.Io.Dir.cwd().readFileAlloc(
            io, path, a, .limited(ps1.sio.Sio.memcard_bytes + 1));
        if (img.len != ps1.sio.Sio.memcard_bytes) return error.BadMemcardSize;
        bus.sio.setMemoryCardData(0, img[0..ps1.sio.Sio.memcard_bytes]);
        std.debug.print("  {s: <22} memcard slot 1 <- {s}\n", .{ wl.key, path });
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
    //
    // Blank the PIXELS ONLY, never the whole struct (`= .{}`). `Vram` also
    // carries the CPU<->VRAM transfer FSM (write_active/write_curr_x/y/
    // write_remaining, and the matching read_* cursors); gp0.zig's ONLY gate
    // keeping an in-flight GP0(A0) transfer's data words out of the opcode
    // decoder is `vram.write_active` (`if (vram.write_active) { sink.
    // vramWriteData(...); return 1; }`). Resetting it mid-transfer aborts the
    // transfer, and its remaining data words get reinterpreted as GP0
    // commands the game never issued.
    @memset(&bus.gpu.vram.data, 0);

    var w = fixture.Writer.empty;
    defer w.deinit(a);

    var stepper = FrameStepper{
        .script = if (opts.input) |text| try script.parse(a, text) else &.{},
    };
    if (stepper.script.len > 0) {
        std.debug.print("  {s: <22} {d} scripted presses\n", .{ wl.key, stepper.script.len });
    }
    // The DrawingEnv as of the START of the frame currently being formed —
    // i.e. as observed at the PREVIOUS boundary, before this frame's own
    // GP0 E1-E6/GP1(09) commands run. `bus.gpu.draw_env` itself is always the
    // env AFTER the just-completed frame's own commands, so it is one
    // boundary too late for this purpose; this variable is what the window
    // must inherit if this frame turns out to be the first one kept. Updated
    // at every boundary while the window is still closed (see the discard
    // branch below); once the window opens it is no longer read. Initialized
    // to the live env here, not to `DrawingEnv{}` — for a `.exe` workload the
    // BIOS-boot preamble above already ran GP0 commands, so "before frame 0"
    // is that preamble's end state, not a hardware reset.
    var env_at_frame_start: ps1.gpu.Regs.DrawingEnv = bus.gpu.draw_env;
    // Set once the recording window has actually opened — i.e. once a frame
    // boundary is found that is both past `capture_from` AND has no CPU->VRAM
    // transfer in flight AT EITHER END of that frame's accumulation window.
    // Only checked before the window opens: once frames are being kept, any
    // `vram_write_setup` a later frame's payload run extends is already
    // recorded in an earlier IN-WINDOW frame, so there is nothing orphaned
    // for a from-blank consumer to choke on.
    var window_open = false;
    // `write_active` as observed at the PREVIOUS boundary — i.e. whether the
    // frame about to be examined even STARTED clean. Checking only the
    // CURRENT boundary's `write_active` (the frame's END state) is not
    // enough on its own: `pushVramWriteData` (recorder.zig) extends the
    // previous `.vram_write_data` record in place, and `takeFrame` resets
    // `count` at every boundary, discarded or not. So a transfer that STARTS
    // while a frame is being discarded and FINISHES inside the very next
    // frame leaves that next frame's first record an orphan run with no
    // preceding `vram_write_setup` — even though `write_active` reads false
    // once THAT frame's own boundary is reached (the transfer just finished).
    // A frame is safe to keep only when write_active was false at BOTH its
    // start and its end. `read_active` needs no matching flag: it mutates no
    // VRAM and records no payload, and each polyline segment is submitted to
    // the sink complete, so neither can orphan a record. The outer
    // `i < budget` bound still terminates this loop even if a pathological
    // workload never lands a boundary outside a transfer — it just writes
    // zero frames.
    var mid_transfer_at_frame_start = false;
    var i: u64 = 0;
    while (i < budget) : (i += 1) {
        const s = stepper.step(i, &cpu, bus) orelse continue;
        if (!s.complete) return error.StreamOverflow;

        if (opts.probe) {
            // One line per frame, piped into awk to find the densest window.
            // Columns: instruction, records, payload words, draw records,
            // textured rectangles, VRAM->VRAM copies.
            const c = Census.count(s.records);
            std.debug.print("PROBE {d} {d} {d} {d} {d} {d}\n", .{
                i, s.records.len, s.payload.len, c.draws, c.textured_rects, c.copies,
            });
            continue;
        }

        if (!window_open) {
            const active_now = bus.gpu.vram.write_active;
            if (i < capture_from or mid_transfer_at_frame_start or active_now) {
                @memset(&bus.gpu.vram.data, 0);
                mid_transfer_at_frame_start = active_now;
                env_at_frame_start = bus.gpu.draw_env;
                continue;
            }
            window_open = true;

            // RULE: the window must be self-contained for the drawing
            // environment too, not just VRAM pixels. GP0(E1-E6)/GP1(09)
            // issued in DISCARDED frames are dropped from the recorded
            // stream while their effect persists live in `bus.gpu.draw_env`
            // — a consumer replaying from a default `DrawingEnv`
            // (`registers.zig` defaults `area_bot_right` to 0, a degenerate
            // clip rect that draws nothing) would diverge starting at this
            // very first kept frame. Fixed by SYNTHESIZING seven records
            // that drive a default-constructed DrawingEnv to exactly the
            // state it had right before this frame's own commands ran
            // (`env_at_frame_start` — NOT the current `bus.gpu.draw_env`,
            // which already includes this frame's own mutations), prepended
            // ahead of this frame's real records. A reset-at-replay-time
            // fix was rejected: it would clip the FMV away in any frame that
            // does not happen to reissue E3/E4 itself.
            const synth = env_sync.envSyncRecords(env_at_frame_start);
            const combined = try a.alloc(ps1.gpu.command.Command, synth.len + s.records.len);
            @memcpy(combined[0..synth.len], &synth);
            @memcpy(combined[synth.len..], s.records);
            try w.addFrame(a, .{ .records = combined, .payload = s.payload, .complete = true }, fixture.hashVram(&bus.gpu.vram));
            try dumpFrame(a, io, opts, wl.key, w.frames.items.len - 1, &bus.gpu.vram);
            if (frame_limit != 0 and w.frames.items.len >= frame_limit) break;
            continue;
        }

        try w.addFrame(a, s, fixture.hashVram(&bus.gpu.vram));
        try dumpFrame(a, io, opts, wl.key, w.frames.items.len - 1, &bus.gpu.vram);
        if (frame_limit != 0 and w.frames.items.len >= frame_limit) break;
    }

    if (opts.probe) return 0;

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
