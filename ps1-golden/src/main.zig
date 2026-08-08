const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");
const state_hash = @import("state_hash.zig");

const default_instructions: u64 = 600_000_000;
const default_interval: u64 = 2_500_000;
const goldens_dir = "ps1-core/tests/goldens/trace";

const usage =
    \\usage: ps1-golden <capture|verify> [options]
    \\
    \\  --filter=<substring>    only run workloads whose key contains this
    \\  --instructions=<n>      instructions per workload (default 600000000)
    \\  --interval=<n>          instructions between samples (default 2500000)
    \\  --bios=<path>           override the auto-selected BIOS
    \\
;

const Options = struct {
    capture: bool,
    filter: ?[]const u8 = null,
    instructions: u64 = default_instructions,
    interval: u64 = default_interval,
    bios_override: ?[]const u8 = null,
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

    const workloads = try golden.discover(a, init.io);

    var failures: usize = 0;
    var ran: usize = 0;

    for (workloads) |wl| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, wl.key, f) == null) continue;
        }
        ran += 1;

        const bios_path = opts.bios_override orelse wl.bios_path;
        const result = runWorkload(a, init.io, wl, bios_path, opts) catch |err| {
            std.debug.print("  {s: <22} ERROR {s}\n", .{ wl.key, @errorName(err) });
            failures += 1;
            continue;
        };

        if (opts.capture) {
            try writeGolden(a, init.io, wl.key, opts, result);
            std.debug.print("  {s: <22} {d}M instr  {d} hashes   CAPTURED\n", .{
                wl.key, opts.instructions / 1_000_000, result.samples.len,
            });
        } else {
            if (try verifyGolden(a, init.io, wl.key, opts, result)) failures += 1;
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

    var opts = Options{ .capture = std.mem.eql(u8, mode, "capture") };
    if (!opts.capture and !std.mem.eql(u8, mode, "verify")) return error.UnknownMode;

    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--filter=")) {
            opts.filter = arg["--filter=".len..];
        } else if (std.mem.startsWith(u8, arg, "--instructions=")) {
            opts.instructions = try std.fmt.parseInt(u64, arg["--instructions=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--interval=")) {
            opts.interval = try std.fmt.parseInt(u64, arg["--interval=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--bios=")) {
            opts.bios_override = arg["--bios=".len..];
        } else {
            return error.UnknownOption;
        }
    }
    if (opts.interval == 0) return error.BadArguments;
    return opts;
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

    const bios = try std.Io.Dir.cwd().readFileAlloc(io, bios_path, a, .limited(1 << 20));
    defer a.free(bios);
    if (bios.len != 512 * 1024) return error.BadBiosSize;
    @memcpy(bus.bios[0..], bios);

    if (wl.cue_path) |cue_path| {
        const cue_text = try std.Io.Dir.cwd().readFileAlloc(io, cue_path, a, .limited(1 << 20));
        const bin_path = try std.fmt.allocPrint(a, "{s}.bin", .{cue_path[0 .. cue_path.len - 4]});
        const bin_bytes = try std.Io.Dir.cwd().readFileAlloc(io, bin_path, a, .limited(900 * 1024 * 1024));
        bus.cdrom.setDisc(ps1.disc.Disc.initFromCue(cue_text, bin_bytes));
    }

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

/// Replaced wholesale in Task 6. Present now only so `main` compiles.
fn verifyGolden(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
    _: Options,
    _: RunResult,
) !bool {
    return false;
}
