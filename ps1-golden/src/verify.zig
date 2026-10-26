//! A run's samples against its committed golden: shared by `ps1-golden`'s
//! `verify` family and `ps1-golden-metal`'s `gpu-verify`.

const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");
const Engine = ps1.recompiler.Engine;

const goldens_dir = "ps1-core/tests/goldens/trace";
const goldens_block_dir = "ps1-core/tests/goldens/trace-block";

pub const RunResult = struct {
    samples: []golden.Sample,
    static_before: u64,
    static_after: u64,
};

pub fn goldensDir(engine: Engine) []const u8 {
    return if (engine == .interpreter) goldens_dir else goldens_block_dir;
}

pub fn goldenPath(a: std.mem.Allocator, key: []const u8, engine: Engine) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.txt", .{ goldensDir(engine), key });
}

/// Returns true when the workload diverged. Reports the first differing sample
/// and every region that moved in it — "first diff: cdrom" is the whole
/// debugging session, which is why regions are hashed separately.
pub fn verifyGolden(
    a: std.mem.Allocator,
    io: std.Io,
    key: []const u8,
    instructions: u64,
    interval: u64,
    engine: Engine,
    result: RunResult,
) !bool {
    const path = try goldenPath(a, key, engine);
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

    if (want.instructions != instructions or want.interval != interval) {
        std.debug.print(
            "  {s: <22} SKIP: golden is {d} instr @ {d}, run is {d} @ {d}\n",
            .{ key, want.instructions, want.interval, instructions, interval },
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
            key, instructions / 1_000_000, result.samples.len, got.instr,
        });
        for (exp.hashes, got.hashes, golden.region_names) |e, g, name| {
            if (e != g) {
                std.debug.print("                         {s}: want {x:0>16}, got {x:0>16}\n", .{ name, e, g });
            }
        }
        return true;
    }

    std.debug.print("  {s: <22} {d}M instr   {d} hashes   OK\n", .{
        key, instructions / 1_000_000, result.samples.len,
    });
    return false;
}
