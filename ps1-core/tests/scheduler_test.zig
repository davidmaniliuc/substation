//! The scheduler must be invisible. Every test here runs a machine that
//! defers device ticks against one forced onto the slow path every step,
//! which is exactly the old per-step `tickPeripherals`, and requires them to
//! agree at every step and in every byte of a savestate.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;
const scheduler = ps1_core.scheduler;
const savestate = ps1_core.savestate;

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    fn init() !Machine {
        const bus = try Bus.init(std.testing.allocator);
        return .{ .bus = bus, .cpu = Cpu.init(bus) };
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(std.testing.allocator);
    }

    /// One step under the old model: every device ticked on every step.
    fn stepPerStep(m: *Machine) void {
        m.bus.sched.downcount = 0;
        m.cpu.step();
    }

    /// What `ps1-golden` does before hashing a sample.
    fn settle(m: *Machine) void {
        scheduler.sync(m.bus);
        m.bus.cdrom.catchUp();
        m.bus.gpu.catchUp();
        for (&m.bus.timers) |*t| t.catchUp();
    }
};

/// Arms every deadline the scheduler takes a term from: timer 0 and timer 2
/// on the system clock (timer 2 prescaled), timer 1 on hblank, a pad
/// transfer waiting on /ACK, and a paced mode-1 SPU DMA whose block gaps
/// hand the bus back to the CPU. The BIOS is zeroed, so the CPU retires nops
/// with I_MASK clear and never takes an interrupt.
fn armSystemClock(bus: *Bus) void {
    bus.write32(0x1F801108, 333); // timer 0 target
    bus.write32(0x1F801104, 0x0058); // sysclk; reset + IRQ on target, repeat
    armCommon(bus);
}

/// The same, but timer 0 counts the dotclock, which keeps the GPU eager:
/// every step is a slow step, and the result must still be exact.
fn armDotclock(bus: *Bus) void {
    bus.write32(0x1F801108, 333);
    bus.write32(0x1F801104, 0x0158); // dotclock
    armCommon(bus);
}

fn armCommon(bus: *Bus) void {
    bus.write32(0x1F801118, 3); // timer 1 target
    bus.write32(0x1F801114, 0x0158); // hblank
    bus.write32(0x1F801128, 100); // timer 2 target
    bus.write32(0x1F801124, 0x0258); // sysclk/8
    bus.write8(0x1F801040, 0x01); // select the pad: arms /ACK
    for (0..64) |i| bus.write32(@intCast(0x1000 + i * 4), @intCast(i));
    bus.write32(0x1F8010F0, 0x00080000); // DPCR: channel 4 enabled
    bus.write32(0x1F8010C0, 0x1000); // MADR
    bus.write32(0x1F8010C4, 0x00040010); // 4 blocks of 16 words
    bus.write32(0x1F8010C8, 0x01000201); // from RAM, sync mode 1, start
}

fn expectSameState(a: *Machine, b: *Machine) !void {
    const alloc = std.testing.allocator;
    const n = try savestate.save(&a.cpu, null);
    try expectEqual(n, try savestate.save(&b.cpu, null));
    const x = try alloc.alloc(u8, n);
    defer alloc.free(x);
    const y = try alloc.alloc(u8, n);
    defer alloc.free(y);
    _ = try savestate.save(&a.cpu, x);
    _ = try savestate.save(&b.cpu, y);
    try std.testing.expectEqualSlices(u8, x, y);
}

fn expectEquivalent(comptime arm: fn (*Bus) void) !void {
    var ref = try Machine.init();
    defer ref.deinit();
    var sch = try Machine.init();
    defer sch.deinit();
    arm(ref.bus);
    arm(sch.bus);

    var i: u32 = 0;
    while (i < 200_000) : (i += 1) {
        ref.stepPerStep();
        const stalled = sch.bus.dma.isCpuStalled(sch.bus);
        sch.cpu.step();

        try expectEqual(ref.bus.interrupts.stat, sch.bus.interrupts.stat);
        try expectEqual(ref.cpu.cycles, sch.cpu.cycles);
        // A DMA-stalled step hands the backlog over and never defers.
        if (stalled) try expectEqual(@as(u32, 0), sch.bus.sched.pending);

        if (i % 20_000 == 0) {
            ref.settle();
            sch.settle();
            try expectSameState(&ref, &sch);
        }
    }
    try expectSameState(&ref, &sch);

    // The run reached every device it armed, so it compared something.
    const stat = sch.bus.interrupts.stat;
    try expect(stat & (1 << 0) != 0); // vblank
    try expect(stat & (1 << 5) != 0); // timer 1
    try expect(stat & (1 << 6) != 0); // timer 2
    try expect(stat & (1 << 7) != 0); // controller
    try expect(!sch.bus.dma.channels[4].transfer_active);
}

test "a deferring machine matches one that ticks every device every step" {
    try expectEquivalent(armSystemClock);
}

test "timer 0 on the dotclock keeps every step slow and still exact" {
    try expectEquivalent(armDotclock);
}

test "an idle machine defers its device ticks" {
    var m = try Machine.init();
    defer m.deinit();
    m.cpu.step(); // power-on downcount is 0: the slow path arms it
    m.cpu.step();
    m.cpu.step();
    try expectEqual(@as(u32, 2), m.bus.sched.pending_steps);
    try expect(m.bus.sched.pending > 0);
}

test "an MMIO read sees the deferred cycles" {
    var ref = try Machine.init();
    defer ref.deinit();
    var sch = try Machine.init();
    defer sch.deinit();
    for (0..50) |_| {
        ref.stepPerStep();
        sch.cpu.step();
    }
    try expect(sch.bus.sched.pending > 0);
    try expectEqual(ref.bus.read32(0x1F801120), sch.bus.read32(0x1F801120)); // timer 2 counter
    try expectEqual(@as(u32, 0), sch.bus.sched.pending);
    try expectEqual(@as(i64, 0), sch.bus.sched.downcount);
}

test "a second sync in the same step steps no device" {
    var m = try Machine.init();
    defer m.deinit();
    for (0..10) |_| m.cpu.step();
    scheduler.sync(m.bus);
    m.bus.gpu.catchUp(); // as the GPU's own register access does
    const gpu_countdown = m.bus.gpu.event_countdown;
    const spu_acc = m.bus.spu.cycle_accumulator;
    scheduler.sync(m.bus);
    try expectEqual(gpu_countdown, m.bus.gpu.event_countdown);
    try expectEqual(spu_acc, m.bus.spu.cycle_accumulator);
}

test "a savestate load resets the scheduler and keeps the GPU clock carry" {
    var m = try Machine.init();
    defer m.deinit();
    for (0..37) |_| m.cpu.step();

    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, try savestate.save(&m.cpu, null));
    defer alloc.free(buf);
    _ = try savestate.save(&m.cpu, buf);
    const frac = m.bus.sched.gpu_clock_frac;

    for (0..13) |_| m.cpu.step();
    try expect(m.bus.sched.pending > 0);

    try savestate.load(&m.cpu, buf);
    try expectEqual(@as(u32, 0), m.bus.sched.pending);
    try expectEqual(@as(u32, 0), m.bus.sched.pending_steps);
    try expectEqual(@as(i64, 0), m.bus.sched.downcount);
    try expectEqual(frac, m.bus.sched.gpu_clock_frac);
}

test "a savestate taken mid-window resumes identically on another bus" {
    var ref = try Machine.init();
    defer ref.deinit();
    var sch = try Machine.init();
    defer sch.deinit();
    armSystemClock(ref.bus);
    armSystemClock(sch.bus);
    for (0..30_001) |_| {
        ref.stepPerStep();
        sch.cpu.step();
    }

    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, try savestate.save(&sch.cpu, null));
    defer alloc.free(buf);
    _ = try savestate.save(&sch.cpu, buf);

    var restored = try Machine.init();
    defer restored.deinit();
    try savestate.load(&restored.cpu, buf);

    for (0..30_000) |_| {
        ref.stepPerStep();
        restored.cpu.step();
        try expectEqual(ref.bus.interrupts.stat, restored.bus.interrupts.stat);
    }
    ref.settle();
    restored.settle();
    try expectSameState(&ref, &restored);
}
