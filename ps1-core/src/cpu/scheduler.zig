//! One countdown for the whole machine.
//!
//! Every device already defers its own work behind a deadline (the GPU, the
//! timers and the CD-ROM keep an `event_countdown`), so handing every step's
//! cycles to every device mostly adds and compares. `downcount` is the
//! minimum of those deadlines in CPU cycles. A step that ends short of it
//! only adds its cycles to `pending`; the step that reaches it takes the slow
//! path, which hands the backlog over and then runs the per-step fan-out
//! exactly as it always ran.
//!
//! Exact, not approximate. The rules that keep it exact:
//!
//!  - Nothing is due inside a deferred window, so handing a device the whole
//!    backlog in one call leaves it holding what a call per step would have.
//!    The slow path hands the backlog over FIRST and only then the step that
//!    reached the deadline, so every device's event body sees the same last
//!    `delta` it always saw.
//!  - Any MMIO access calls `sync` first: the device reads its state current,
//!    and the zeroed `downcount` sends the step in progress down the slow
//!    path, which recomputes the deadline AFTER the access has moved it.
//!  - A DMA-stalled step always takes the slow path. A DMA word can arm a
//!    block gap, start a chop CPU turn or end a transfer without any register
//!    access. Every cycle in `pending` was therefore spent by the CPU, and
//!    `pending` doubles as the DMA CPU-window count.
//!  - A block engine charges a whole block at once (`charge`) and may run
//!    past the deadline by up to its own length; `serviceDue` at the block
//!    boundary hands the overrun over one deadline at a time. The
//!    interpreter never overruns, and never reaches that path.
//!  - `deadline` names EVERY device countdown. One left out is not a slow
//!    event; it is an event that fires late.

const std = @import("std");
const Bus = @import("../memory.zig").Bus;

/// Cycles per SPU output sample: 33.8688 MHz / 44100 Hz.
const spu_sample_cycles: i64 = 768;

pub const Scheduler = struct {
    /// CPU cycles until the earliest device deadline, counted down by every
    /// step. Zero, the power-on value and what `sync` leaves, sends the next
    /// step down the slow path, which recomputes it.
    downcount: i64 = 0,
    /// Cycles and `Cpu.step()` calls not yet handed to the devices. SIO
    /// takes the step count: its /ACK delay counts steps, not cycles.
    pending: u32 = 0,
    pending_steps: u32 = 0,
    /// Carry for the CPU->video clock conversion. The GPU/video clock runs
    /// at 11/7 the CPU clock (53.2224 MHz vs 33.8688 MHz); `gpu.step()` is
    /// denominated in video cycles, so CPU cycles are scaled before being
    /// handed to it. Saved in the `CPU ` section, where it always was.
    gpu_clock_frac: u32 = 0,
};

/// One `Cpu.step()`'s `delta` cycles. `cpu_window` is false for a
/// DMA-stalled step, which neither ticks the DMA CPU window nor defers.
pub inline fn tick(bus: *Bus, delta: u32, cpu_window: bool) void {
    const s = &bus.sched;
    s.downcount -= delta;
    if (s.downcount > 0 and cpu_window) {
        s.pending += delta;
        s.pending_steps += 1;
        return;
    }
    tickSlow(bus, delta, cpu_window);
}

fn tickSlow(bus: *Bus, delta: u32, cpu_window: bool) void {
    const s = &bus.sched;
    if (s.pending > 0) {
        // Every step before this one ended short of the deadline, so the
        // backlog lies inside one window. This holds under the block engines
        // too, because each of their `run()`s ends in `serviceDue`.
        if (std.debug.runtime_safety) std.debug.assert(s.pending < deadline(bus));
        handOver(bus, s.pending, s.pending_steps);
        s.pending = 0;
        s.pending_steps = 0;
    }
    advance(bus, delta, 1);
    if (cpu_window) bus.dma.tickCpuWindow(delta);
    s.downcount = deadline(bus);
}

/// A block engine's `cycles` spanning `steps` would-be `Cpu.step()` calls.
/// Defers only, never the slow path: a block may run past the deadline,
/// and `serviceDue` at the block boundary hands the overrun over.
pub inline fn charge(bus: *Bus, cycles: u32, steps: u32) void {
    const s = &bus.sched;
    s.downcount -= cycles;
    s.pending += cycles;
    s.pending_steps += steps;
}

/// The block boundary's half of `tick`'s slow path: anything that came due
/// during the block is handed over and the deadline recomputed.
pub fn serviceDue(bus: *Bus) void {
    if (bus.sched.downcount > 0) return;
    flush(bus);
    bus.sched.downcount = deadline(bus);
}

/// Hands everything deferred to the devices and sends the step in progress
/// down the slow path. Called before every MMIO access, before a savestate
/// is written and before `ps1-golden` hashes a sample.
pub fn sync(bus: *Bus) void {
    flush(bus);
    bus.sched.downcount = 0;
}

fn flush(bus: *Bus) void {
    const s = &bus.sched;
    // Also what makes a second sync in one step harmless: stepping a device
    // by 0 cycles with a zeroed countdown would fire its event body.
    if (s.pending == 0) return;
    if (s.downcount > 0) {
        // Short of the deadline it was computed against, and nothing has
        // moved it since (a move means an MMIO access, which syncs first).
        handOver(bus, s.pending, s.pending_steps);
    } else {
        flushOverrun(bus);
    }
    s.pending = 0;
    s.pending_steps = 0;
}

/// Hands a backlog that ran past the deadline over one deadline at a time.
/// A device given more than a deadline's worth in one call misses events:
/// `Timer.stepRaw` sees one target crossing per call, and the CD-ROM's
/// batch assumes nothing is due inside it. Steps go with the earliest
/// cycles. A step costs at least one cycle, so no chunk is handed more
/// steps than cycles, and none more than SIO's own term allows.
fn flushOverrun(bus: *Bus) void {
    const s = &bus.sched;
    while (s.pending > 0) {
        const chunk: u32 = @intCast(@min(@as(i64, s.pending), deadline(bus)));
        const steps = if (chunk == s.pending) s.pending_steps else @min(s.pending_steps, chunk);
        handOver(bus, chunk, steps);
        s.pending -= chunk;
        s.pending_steps -= steps;
    }
}

/// Deferred cycles to the devices. Every deferred cycle was spent by the CPU,
/// so the same count drains the DMA CPU window.
fn handOver(bus: *Bus, cycles: u32, steps: u32) void {
    advance(bus, cycles, steps);
    bus.dma.tickCpuWindow(cycles);
}

/// The device fan-out for `cycles` cycles spanning `steps` `Cpu.step()`
/// calls. The order matters: timer 0 consumes the dotclock ticks and timer 1
/// the hblank tick that the GPU produced earlier in the same call.
fn advance(bus: *Bus, cycles: u32, steps: u32) void {
    bus.spu.step(cycles);

    // Without the 11/7 conversion the vblank period is ~1.57x too long
    // relative to the CPU-cycle root counters, so the BIOS VSync wait times
    // out during KERNEL SETUP and the boot hangs.
    const gpu_scaled = cycles * 11 + bus.sched.gpu_clock_frac;
    bus.sched.gpu_clock_frac = gpu_scaled % 7;
    const gpu_result = bus.gpu.step(gpu_scaled / 7);

    if (gpu_result.trigger_vblank_irq) bus.interrupts.trigger(.Vblank);
    if (gpu_result.trigger_gp0_irq) bus.interrupts.trigger(.Gpu);
    if (bus.spu.irq_flag) bus.interrupts.trigger(.Spu);

    // Controller/memcard port: /ACK arrives a few steps after a byte is
    // clocked out, so the IRQ is raised here rather than from the write.
    if (bus.sio.advance(steps)) bus.interrupts.trigger(.Controller);

    if (bus.timers[0].usesExternalClock()) {
        if (gpu_result.dotclock_ticks > 0 and bus.timers[0].step(gpu_result.dotclock_ticks)) {
            bus.interrupts.trigger(.Timer0);
        }
    } else if (bus.timers[0].step(cycles)) {
        bus.interrupts.trigger(.Timer0);
    }

    if (bus.timers[1].usesExternalClock()) {
        if (gpu_result.tick_hblank_timer and bus.timers[1].step(1)) {
            bus.interrupts.trigger(.Timer1);
        }
    } else if (bus.timers[1].step(cycles)) {
        bus.interrupts.trigger(.Timer1);
    }

    if (bus.timers[2].step(cycles)) bus.interrupts.trigger(.Timer2);

    bus.cdrom.step(cycles, &bus.spu);
    bus.cdrom.updateInterrupts(&bus.interrupts);
}

/// CPU cycles until the earliest device deadline, at least 1.
fn deadline(bus: *const Bus) i64 {
    var d: i64 = spu_sample_cycles - @as(i64, bus.spu.cycle_accumulator);

    // The GPU counts video cycles. It is due once floor((11c + frac) / 7)
    // reaches its countdown, which takes ceil((7 * countdown - frac) / 11)
    // CPU cycles.
    d = @min(d, @divFloor(7 * bus.gpu.event_countdown - @as(i64, bus.sched.gpu_clock_frac) + 10, 11));

    // Timers 0 and 1 on an external clock count GPU ticks and need no term:
    // timer 0 on the dotclock keeps the GPU eager (deadline 1), and timer 1
    // counts the hblank the GPU's scanline deadline already stops on. Timer
    // 2 always counts CPU cycles, whatever its mode.
    for (&bus.timers, 0..) |*t, i| {
        if (i < 2 and t.usesExternalClock()) continue;
        d = @min(d, t.event_countdown);
    }

    d = @min(d, bus.cdrom.event_countdown);

    // SIO counts steps, not cycles. A step costs at least one cycle, so the
    // step count used as a cycle count is a bound that arrives early, never
    // late; an early slow path finds SIO not yet due and re-arms. Do not
    // "convert" it.
    if (bus.sio.irq_timer > 0) d = @min(d, bus.sio.irq_timer);

    d = @min(d, bus.dma.cpuWindowDeadline());
    return @max(d, 1);
}
