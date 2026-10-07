//! The gate that a savestate captures the WHOLE machine: two machines, one of
//! which saved and was restored into a fresh `Bus`, must then run to the same
//! hash in every region. A field a section forgets fails here as soon as it
//! matters — unless it still holds its power-on value at the save point,
//! which is what `trace-golden -- savestate` (mid-game, every workload) is for.

const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");
const state_hash = @import("state_hash.zig");

const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;
const savestate = ps1.savestate;

const bios_path = "SCPH-1001_BIOS_1995_US.bin";
const v1_fixture_path = "ps1-core/tests/goldens/savestate/v1-synthetic.state";
const v2_fixture_path = "ps1-core/tests/goldens/savestate/v2-synthetic.state";

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    fn init(bios: []const u8) !Machine {
        const bus = try Bus.init(std.testing.allocator);
        @memcpy(&bus.bios, bios);
        return .{ .bus = bus, .cpu = Cpu.init(bus) };
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(std.testing.allocator);
    }

    fn run(m: *Machine, n: u64) void {
        var i: u64 = 0;
        while (i < n) i += m.cpu.run();
    }

    /// Settles the deferred devices first, exactly as `ps1-golden` does
    /// before every sample.
    fn hashes(m: *Machine) [golden.region_count]u64 {
        ps1.scheduler.sync(m.bus);
        m.bus.cdrom.catchUp();
        m.bus.gpu.catchUp();
        for (&m.bus.timers) |*t| t.catchUp();
        var out: [golden.region_count]u64 = undefined;
        state_hash.hashAll(&m.cpu, &out);
        return out;
    }

    fn saveAlloc(m: *Machine) ![]u8 {
        const n = try savestate.save(&m.cpu, null);
        const buf = try std.testing.allocator.alloc(u8, n);
        _ = try savestate.save(&m.cpu, buf);
        return buf;
    }
};

fn readBios() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, bios_path, std.testing.allocator, .limited(1 << 20)) catch
        return error.SkipZigTest; // BIOS images are gitignored
}

test "a restored machine runs on to the same hash in every region" {
    const bios = try readBios();
    defer std.testing.allocator.free(bios);

    var a = try Machine.init(bios);
    defer a.deinit();
    a.run(8_000_000); // well into the BIOS logo: GPU, SPU, timers and DMA all live

    const state = try a.saveAlloc();
    defer std.testing.allocator.free(state);

    var b = try Machine.init(bios);
    defer b.deinit();
    try savestate.load(&b.cpu, state);

    a.run(2_000_000);
    b.run(2_000_000);
    const want = a.hashes();
    const got = b.hashes();
    for (want, got, golden.region_names) |w, g, name| {
        if (w != g) std.debug.print("region {s} diverged after restore\n", .{name});
    }
    try std.testing.expectEqualSlices(u64, &want, &got);
}

test "a refused load leaves the machine it was handed byte-identical" {
    const bios = try readBios();
    defer std.testing.allocator.free(bios);

    var a = try Machine.init(bios);
    defer a.deinit();
    a.run(1_000_000);
    const state = try a.saveAlloc();
    defer std.testing.allocator.free(state);
    state[savestate.header_len + 10] ^= 0xFF;

    var b = try Machine.init(bios);
    defer b.deinit();
    b.run(500_000);
    const before = b.hashes();
    try std.testing.expectError(error.StateCorrupt, savestate.load(&b.cpu, state));
    try std.testing.expectEqualSlices(u64, &before, &b.hashes());
}

/// Deterministic, BIOS-free, and touches at least one field of every section,
/// so the committed fixture exercises every section's v1 reader. NO BIOS code
/// is involved — the BIOS is all zeros — so the fixture carries nothing
/// copyrighted into the repository.
fn buildFixtureMachine() anyerror!Machine {
    const zeros: [512 * 1024]u8 = @splat(0);
    var m = try Machine.init(&zeros);
    m.bus.ram[0x10] = 0xA1;
    m.cpu.regs[4] = 0xA2;
    m.cpu.cop2.ctrl_regs[26] = 0xA3;
    m.bus.interrupts.mask = 0xA4;
    m.bus.timers[1].target = 0xA5;
    m.bus.dma.channels[6].base_addr = 0xA6;
    m.bus.gpu.vram.data[0] = 0xA7;
    m.bus.spu.voices[23].regs.pitch = 0xA8;
    m.bus.cdrom.drive.mode = 0xA9;
    m.bus.mdec.quant_color[0] = 0xAA;
    m.bus.sio.baud = 0xAB;
    return m;
}

/// The v1 machine plus a pad that is mid-packet in config mode, so the
/// fixture exercises every field `SIO ` v2 added.
fn buildV2FixtureMachine() anyerror!Machine {
    var m = try buildFixtureMachine();
    const p = &m.bus.sio.pad;
    p.config = true;
    p.dualshock = true;
    p.rumble_map[0] = 0x00;
    p.sticks[2] = 0x12;
    p.motor_large = 0x34;
    p.command = 0x42;
    p.len = 8;
    p.step = 3;
    p.tx = .{ 0xF3, 0x5A, 0xFF, 0xFF, 0x80, 0x80, 0x12, 0x80 };
    m.bus.sio.ctrl_state = .Pad;
    return m;
}

/// Loads a committed state into a fresh machine and requires it to hash
/// exactly as the machine `build` describes. The first run writes the file
/// and fails, so a new fixture is noticed and committed.
fn expectFixtureLoads(path: []const u8, comptime build: fn () anyerror!Machine) !void {
    const file = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            var m = try build();
            defer m.deinit();
            const state = try m.saveAlloc();
            defer std.testing.allocator.free(state);
            try std.Io.Dir.cwd().createDirPath(std.testing.io, "ps1-core/tests/goldens/savestate");
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = state });
            std.debug.print("wrote {s}; commit it\n", .{path});
            return error.FixtureWritten;
        },
        else => return err,
    };
    defer std.testing.allocator.free(file);

    var want = try build();
    defer want.deinit();
    const zeros: [512 * 1024]u8 = @splat(0);
    var got = try Machine.init(&zeros);
    defer got.deinit();
    try savestate.load(&got.cpu, file);
    try std.testing.expectEqualSlices(u64, &want.hashes(), &got.hashes());
}

test "the committed v1 state still loads, into exactly the machine that wrote it" {
    try expectFixtureLoads(v1_fixture_path, buildFixtureMachine);
}

test "the committed v2 state still loads, into exactly the machine that wrote it" {
    try expectFixtureLoads(v2_fixture_path, buildV2FixtureMachine);
}
