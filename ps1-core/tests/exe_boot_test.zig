const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;
const exe = ps1_core.exe;
const exe_boot = ps1_core.exe_boot;
const savestate = ps1_core.savestate;
const Engine = ps1_core.recompiler.Engine;

const gpa = std.testing.allocator;
const bios_path = "SCPH-1001_BIOS_1995_US.bin";
const exe_path = "test-roms/peterlemon/hello-world/HelloWorld16BPP.exe";
/// Far past kernel init, which SCPH-1001 reaches inside a million steps.
const step_limit = 50_000_000;

fn readOrSkip(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,
    exe_bytes: []u8,
    boot: exe_boot.Boot,

    fn init(m: *Machine, engine: Engine, fast_boot: bool) !void {
        const bios = try readOrSkip(bios_path);
        defer gpa.free(bios);
        m.exe_bytes = try readOrSkip(exe_path);
        errdefer gpa.free(m.exe_bytes);
        m.boot = .{
            .main = try exe.parse(gpa, m.exe_bytes),
            .libps = null,
            .fingerprint = exe.fingerprint(m.exe_bytes, ""),
        };
        errdefer m.boot.main.deinit(gpa);
        m.bus = try Bus.init(gpa);
        errdefer m.bus.deinit(gpa);
        @memcpy(&m.bus.bios, bios);
        if (fast_boot) m.bus.bios_patch = ps1_core.bios.patchFastBoot(&m.bus.bios) orelse return error.NoFastBootMatch;
        m.cpu = Cpu.init(m.bus);
        ps1_core.recompiler.setEngine(&m.cpu, gpa, engine) catch |err| switch (err) {
            error.EngineUnavailable => return error.SkipZigTest,
            else => return err,
        };
        m.bus.exe_boot = &m.boot;
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(gpa);
        m.boot.main.deinit(gpa);
        gpa.free(m.exe_bytes);
    }

    /// Runs until the program's entry block has run, or the limit. The
    /// steps it took, or null if the program never started.
    fn runToProgram(m: *Machine, limit: u64) ?u64 {
        const entry = m.boot.main.entry.pc;
        const seg = m.boot.main.segments[0];
        var steps: u64 = 0;
        while (steps < limit) {
            steps += m.cpu.runFor(1);
            const pc = m.cpu.pipeline.current_pc;
            if (pc == entry or (pc >= seg.addr and pc < seg.addr + seg.bytes.len)) return steps;
        }
        return null;
    }

    fn expectProgramPlaced(m: *Machine) !void {
        const seg = m.boot.main.segments[0];
        const at = seg.addr & 0x1FFFFF;
        try expectEqualSlices(u8, seg.bytes[0..64], m.bus.ram[at..][0..64]);
        try expectEqual(false, m.bus.exe_due);
    }
};

fn expectBootsProgram(engine: Engine, fast_boot: bool) !void {
    var m: Machine = undefined;
    try m.init(engine, fast_boot);
    defer m.deinit();
    _ = m.runToProgram(step_limit) orelse return error.ProgramNeverRan;
    try m.expectProgramPlaced();
    const sp = m.boot.main.entry.sp;
    try expectEqual(sp, m.cpu.regs[@backingInt(ps1_core.cpu.Reg.sp)]);
    try expectEqual(sp, m.cpu.regs[@backingInt(ps1_core.cpu.Reg.fp)]);
}

test "kernelInitWritesPost7" {
    var m: Machine = undefined;
    try m.init(.interpreter, false);
    defer m.deinit();
    // The step that stores the POST code leaves no request behind it: the
    // same `runFor` serves it, so a mark taken between calls never sees one.
    var steps: u64 = 0;
    while (steps < step_limit and m.bus.ram[m.boot.main.segments[0].addr & 0x1FFFFF] == 0) {
        steps += m.cpu.runFor(1);
        try expectEqual(false, m.bus.exe_due);
    }
    try expect(steps < step_limit);
    try m.expectProgramPlaced();
}

test "armedExeRunsAtKernelInit interpreter" {
    try expectBootsProgram(.interpreter, false);
}

test "armedExeRunsAtKernelInit cached" {
    try expectBootsProgram(.cached, false);
}

test "armedExeRunsAtKernelInit jit" {
    try expectBootsProgram(.jit, false);
}

test "armedExeRunsWithFastBoot" {
    try expectBootsProgram(.interpreter, true);
}

test "markBeforeInjectStillStarts" {
    var probe: Machine = undefined;
    try probe.init(.jit, false);
    const reached = probe.runToProgram(step_limit);
    probe.deinit();
    const n = reached orelse return error.ProgramNeverRan;
    // Kernel init comes within the first million steps, so the mark is
    // taken halfway there rather than a fixed distance before it.
    const lead = n / 2;

    var m: Machine = undefined;
    try m.init(.jit, false);
    defer m.deinit();
    var steps: u64 = 0;
    while (steps < n - lead) steps += m.cpu.runFor(1);

    const len = try savestate.saveTrusted(&m.cpu, null, .write);
    const mark = try gpa.alloc(u8, len);
    defer gpa.free(mark);
    _ = try savestate.saveTrusted(&m.cpu, mark, .write);

    _ = m.runToProgram(step_limit) orelse return error.ProgramNeverRan;
    try savestate.loadTrusted(&m.cpu, mark);
    @memset(m.bus.ram[m.boot.main.segments[0].addr & 0x1FFFFF ..][0..64], 0);
    _ = m.runToProgram(step_limit) orelse return error.ProgramNeverRanAfterReturn;
    try m.expectProgramPlaced();
}
