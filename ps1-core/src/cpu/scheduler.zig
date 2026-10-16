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
//!    An access that can move no countdown but its own device's, which that
//!    device re-arms itself, calls `settle` after it instead: the deadline
//!    is derived there and then, and the step defers like any other. Reads
//!    of the MDEC, I_STAT, I_MASK and the DMA registers skip both: nothing
//!    deferred changes what they answer, and reading them moves nothing.
//!  - A GP0 write and a GPUSTAT read touch the GPU alone, so they call
//!    `syncGpu`, which hands the backlog to the GPU and leaves it deferred
//!    for everything else (`gpu_ahead`). `deadline` counts the backlog
//!    against each device it has not reached.
//!  - A DMA-stalled step defers only while its channel runs on (`Step.dma`).
//!    A word that arms a block gap, starts a chop CPU turn or ends the
//!    transfer changes the deadline without any register access, so it takes
//!    the slow path (`Step.dma_last`), and so does a word whose device access
//!    synced. A backlog is therefore all CPU cycles or all stalled ones,
//!    never both: only the CPU's drain the DMA CPU window (`pending_stalled`).
//!  - A block engine charges a whole block at once (`charge`) and may run
//!    past the deadline by up to its own length; `serviceDue` at the block
//!    boundary hands the overrun over one deadline at a time. The
//!    interpreter never overruns, and never reaches that path.
//!  - `deadline` names EVERY device countdown. One left out is not a slow
//!    event; it is an event that fires late.

const std = @import("std");
const Bus = @import("../memory.zig").Bus;
const GpuStepResult = @import("../gpu/gpu.zig").Gpu.GpuStepResult;

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
    /// `pending` was run up by DMA-stalled steps, which do not drain the DMA
    /// CPU window. Cleared with the backlog.
    pending_stalled: bool = false,
    /// The last `sync` handed over a backlog that had reached the deadline,
    /// which only a block engine leaves (`settle`).
    overran: bool = false,
    /// The head of the backlog that `syncGpu` has already handed to the GPU,
    /// in cycles and steps. Always inside the window: nothing was due in it.
    gpu_ahead: u32 = 0,
    gpu_ahead_steps: u32 = 0,
    /// Carry for the CPU->video clock conversion. The GPU/video clock runs
    /// at 11/7 the CPU clock (53.2224 MHz vs 33.8688 MHz); `gpu.step()` is
    /// denominated in video cycles, so CPU cycles are scaled before being
    /// handed to it. Saved in the `CPU ` section, where it always was.
    gpu_clock_frac: u32 = 0,
};

/// What one `Cpu.step()` was.
pub const Step = enum {
    /// An instruction or an interrupt entry: it drains the DMA CPU window.
    cpu,
    /// A DMA word after which its channel runs on: nothing `deadline` reads
    /// has changed, and the next step is stalled too.
    dma,
    /// Any other DMA word: always the slow path.
    dma_last,
};

/// One `Cpu.step()`'s `delta` cycles.
pub inline fn tick(bus: *Bus, delta: u32, step: Step) void {
    const s = &bus.sched;
    s.downcount -= delta;
    if (s.downcount > 0 and step != .dma_last) {
        // A stall begins at an MMIO store or a deadline, both of which leave
        // the backlog empty, and ends at a `dma_last` word.
        if (std.debug.runtime_safety) std.debug.assert(s.pending == 0 or s.pending_stalled == (step == .dma));
        s.pending += delta;
        s.pending_steps += 1;
        s.pending_stalled = step == .dma;
        return;
    }
    tickSlow(bus, delta, step);
}

fn tickSlow(bus: *Bus, delta: u32, step: Step) void {
    const s = &bus.sched;
    if (s.pending > 0) {
        // Every step before this one ended short of the deadline, so the
        // backlog lies inside one window. This holds under the block engines
        // too: each `run()` ends in `serviceDue`, which flushes whenever a
        // block reached or passed the deadline or an MMIO sync zeroed it.
        if (std.debug.runtime_safety) assertInWindow(bus);
        handOver(bus, s.pending, s.pending_steps, s.pending - s.gpu_ahead);
        clearPending(s);
    }
    advance(bus, delta, 1, delta);
    if (step == .cpu) bus.dma.tickCpuWindow(delta);
    s.downcount = deadline(bus);
}

fn clearPending(s: *Scheduler) void {
    s.pending = 0;
    s.pending_steps = 0;
    s.pending_stalled = false;
    s.gpu_ahead = 0;
    s.gpu_ahead_steps = 0;
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
    bus.sched.overran = bus.sched.downcount <= 0 and bus.sched.pending > 0;
    flush(bus);
    bus.sched.downcount = 0;
}

/// `sync` for an access that reads and moves the GPU alone, followed by
/// `settle`: only the GPU is handed the backlog, and every other device
/// stays deferred. A backlog that reached the deadline takes the full
/// `sync`, because the GPU could be due inside it.
pub fn syncGpu(bus: *Bus) void {
    const s = &bus.sched;
    if (s.downcount <= 0) return sync(bus);
    s.overran = false;
    if (s.pending == s.gpu_ahead) return;
    _ = stepGpu(bus, s.pending - s.gpu_ahead);
    s.gpu_ahead = s.pending;
    s.gpu_ahead_steps = s.pending_steps;
}

/// After a `sync`ed access that moved no countdown but the accessed
/// device's own, which it re-armed: derives the deadline the slow path
/// would have, so the step in progress need not take it. Not after a sync
/// that handed a block's overrun over: events fired there, perhaps an
/// interrupt or a DMA request, and only the dispatcher acts on those, so
/// the zero must stand to end a linked chain.
pub fn settle(bus: *Bus) void {
    if (std.debug.runtime_safety) std.debug.assert(bus.sched.pending == bus.sched.gpu_ahead);
    if (bus.sched.overran) return;
    bus.sched.downcount = deadline(bus);
}

fn flush(bus: *Bus) void {
    const s = &bus.sched;
    // Also what makes a second sync in one step harmless: stepping a device
    // by 0 cycles with a zeroed countdown would fire its event body.
    if (s.pending == 0) return;
    if (s.downcount > 0) {
        // Short of the deadline it was computed against, and nothing has
        // moved it since (a move means an MMIO access, which syncs first).
        if (std.debug.runtime_safety) assertInWindow(bus);
        handOver(bus, s.pending, s.pending_steps, s.pending - s.gpu_ahead);
    } else {
        flushOverrun(bus);
    }
    clearPending(s);
}

/// Hands a backlog that ran past the deadline over one deadline at a time.
/// A device given more than a deadline's worth in one call misses events:
/// `Timer.stepRaw` sees one target crossing per call, and the CD-ROM's
/// batch assumes nothing is due inside it. Steps go with the earliest
/// cycles. A step costs at least one cycle, so no chunk is handed more
/// steps than cycles, and none more than SIO's own term allows. The effect:
/// SIO's /ACK can fire up to one block's steps early in cycle time. It is
/// never late and never skipped, because SIO's term is in `deadline`.
fn flushOverrun(bus: *Bus) void {
    const s = &bus.sched;
    // Only a block overruns, and a block is never a stall.
    if (std.debug.runtime_safety) std.debug.assert(!s.pending_stalled);
    // The head the GPU already has goes to the rest as one chunk, as the
    // full `sync` it stands for would have handed it. A deadline chunk
    // spanning it would hand the event that ends it a different delta.
    if (s.gpu_ahead > 0) {
        handOver(bus, s.gpu_ahead, s.gpu_ahead_steps, 0);
        s.pending -= s.gpu_ahead;
        s.pending_steps -= s.gpu_ahead_steps;
        s.gpu_ahead = 0;
        s.gpu_ahead_steps = 0;
    }
    while (s.pending > 0) {
        const chunk: u32 = @intCast(@min(@as(i64, s.pending), @max(due(bus, 0, 0, 0).min(), 1)));
        const steps = if (chunk == s.pending) s.pending_steps else @min(s.pending_steps, chunk);
        handOver(bus, chunk, steps, chunk);
        s.pending -= chunk;
        s.pending_steps -= steps;
    }
}

/// Deferred cycles to the devices. Cycles the CPU spent also drain the DMA
/// CPU window; a stall's do not.
fn handOver(bus: *Bus, cycles: u32, steps: u32, gpu_cycles: u32) void {
    advance(bus, cycles, steps, gpu_cycles);
    if (!bus.sched.pending_stalled) bus.dma.tickCpuWindow(cycles);
}

/// `cycles` CPU cycles to the GPU, at its own clock.
fn stepGpu(bus: *Bus, cycles: u32) GpuStepResult {
    // Without the 11/7 conversion the vblank period is ~1.57x too long
    // relative to the CPU-cycle root counters, so the BIOS VSync wait times
    // out during KERNEL SETUP and the boot hangs.
    const gpu_scaled = cycles * 11 + bus.sched.gpu_clock_frac;
    bus.sched.gpu_clock_frac = gpu_scaled % 7;
    return bus.gpu.step(gpu_scaled / 7);
}

/// The device fan-out for `cycles` cycles spanning `steps` `Cpu.step()`
/// calls, of which the GPU takes the last `gpu_cycles` (`syncGpu` handed
/// it the rest). The order matters: timer 0 consumes the dotclock ticks and
/// timer 1 the hblank tick that the GPU produced earlier in the same call.
fn advance(bus: *Bus, cycles: u32, steps: u32, gpu_cycles: u32) void {
    bus.spu.step(cycles);

    // Stepped by zero, a GPU whose countdown is zero would fire its event
    // body with the wrong delta; one that is ahead has nothing due here.
    const gpu_result: GpuStepResult = if (gpu_cycles > 0) stepGpu(bus, gpu_cycles) else .{};

    if (gpu_result.trigger_vblank_irq) bus.interrupts.trigger(.Vblank);
    if (gpu_result.trigger_gp0_irq) bus.interrupts.trigger(.Gpu);
    if (bus.spu.irq_flag and !bus.spu.irq_line) bus.interrupts.trigger(.Spu);
    bus.spu.irq_line = bus.spu.irq_flag;

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

/// CPU cycles until the earliest device deadline, at least 1, counting the
/// backlog as spent.
fn deadline(bus: *const Bus) i64 {
    const s = &bus.sched;
    return @max(due(bus, s.pending, s.pending_steps, s.pending - s.gpu_ahead).min(), 1);
}

/// The backlog lies inside one window: no device is due within the part of
/// it that device has not been handed.
fn assertInWindow(bus: *const Bus) void {
    const s = &bus.sched;
    const d = due(bus, s.pending, s.pending_steps, s.pending - s.gpu_ahead);
    std.debug.assert(d.rest > 0 and (d.gpu > 0 or s.pending == s.gpu_ahead));
}

const Due = struct {
    gpu: i64,
    rest: i64,

    fn min(self: Due) i64 {
        return @min(self.gpu, self.rest);
    }
};

/// CPU cycles from now until each device deadline, given `cycles` and
/// `steps` the devices have not been handed yet, of which the GPU has not
/// been handed `gpu_cycles`. Unclamped: zero or less is due already.
fn due(bus: *const Bus, cycles: u32, steps: u32, gpu_cycles: u32) Due {
    // The GPU counts video cycles. It is due once floor((11c + frac) / 7)
    // reaches its countdown, which takes ceil((7 * countdown - frac) / 11)
    // CPU cycles.
    const gpu = @divFloor(7 * bus.gpu.event_countdown - @as(i64, bus.sched.gpu_clock_frac) + 10, 11) - gpu_cycles;

    var d: i64 = spu_sample_cycles - @as(i64, bus.spu.cycle_accumulator);

    // Timers 0 and 1 on an external clock count GPU ticks and need no term:
    // timer 0 on the dotclock keeps the GPU eager (deadline 1), and timer 1
    // counts the hblank the GPU's scanline deadline already stops on. Timer
    // 2 always counts CPU cycles, whatever its mode.
    for (&bus.timers, 0..) |*t, i| {
        if (i < 2 and t.usesExternalClock()) continue;
        d = @min(d, t.event_countdown);
    }

    d = @min(d, bus.cdrom.event_countdown);
    d -= cycles;

    // SIO counts steps, not cycles. A step costs at least one cycle, so the
    // step count used as a cycle count is a bound that arrives early, never
    // late; an early slow path finds SIO not yet due and re-arms. Do not
    // "convert" it.
    if (bus.sio.irq_timer > 0) d = @min(d, @as(i64, bus.sio.irq_timer) - steps);

    // Only the CPU's cycles drain the DMA CPU window.
    d = @min(d, bus.dma.cpuWindowDeadline() - if (bus.sched.pending_stalled) 0 else @as(i64, cycles));
    return .{ .gpu = gpu, .rest = d };
}
