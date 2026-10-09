//! The PGXP half of a runahead mark: every shadow a state does not carry.
//!
//! A return writes the machine back in place, so without this the shadows
//! would hold what the speculative frames recorded. The identity check
//! rejects those (nothing is drawn wrong), but every rejected vertex is one
//! that falls back to integers, and a return every frame turns that into the
//! steady state. Carrying them keeps PGXP's coverage across a return.
//!
//! Copied only while PGXP is on: with it off nothing reads a shadow. The
//! vertex cache is left out on purpose. It is 83 MB, it validates every
//! entry by the word, and copying it twice a frame would cost more than the
//! rest of runahead together. The depth plane and the depth state come along
//! only while the depth buffer is on, because neither is in a state and the
//! software rasterizer depth-tests against both.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Bus = @import("../memory.zig").Bus;
const Gpu = @import("../gpu/gpu.zig").Gpu;
const Gp0 = @TypeOf(@as(Gpu, undefined).gp0);
const Vram = @TypeOf(@as(Gpu, undefined).vram);
const Value = @import("../pgxp/pgxp.zig").Value;

/// The small shadows, by value. The RAM shadow and the depth plane are
/// heap buffers in `PgxpShadows`, allocated on first use.
const Registers = struct {
    gpr: @TypeOf(@as(Cpu, undefined).gpr_shadow),
    load: Value,
    delay: Value,
    hi: Value,
    lo: Value,
    cop0: @TypeOf(@as(Cpu, undefined).cop0_shadow),
    cop2: @TypeOf(@as(Cpu, undefined).cop2.precise),
    jit_loads: [2]Value,
    scratch: @TypeOf(@as(Bus, undefined).scratch_shadow),
    pending: Value,
    fifo: @TypeOf(@as(Gpu, undefined).fifo_pgxp),
    cmd_buffer: @TypeOf(@as(Gp0, undefined).cmd_buffer_pgxp),
    weld: @TypeOf(@as(Gp0, undefined).weld),
    depth_state: @TypeOf(@as(Gp0, undefined).depth_state),
};

pub const PgxpShadows = struct {
    allocator: std.mem.Allocator,
    ram: ?*@TypeOf(@as(Bus, undefined).ram_shadow) = null,
    depth: ?*@TypeOf(@as(Vram, undefined).depth) = null,
    regs: ?*Registers = null,
    /// What the last `take` copied: nothing with PGXP off, the depth half
    /// only with the depth buffer on.
    held: bool = false,
    held_depth: bool = false,

    pub fn init(allocator: std.mem.Allocator) PgxpShadows {
        return .{ .allocator = allocator };
    }

    pub fn deinit(s: *PgxpShadows) void {
        if (s.ram) |p| s.allocator.destroy(p);
        if (s.depth) |p| s.allocator.destroy(p);
        if (s.regs) |p| s.allocator.destroy(p);
        s.* = undefined;
    }

    /// The raster worker must already be drained: the depth plane is its.
    pub fn take(s: *PgxpShadows, cpu: *const Cpu) error{OutOfMemory}!void {
        const bus = cpu.bus;
        s.held = bus.pgxp_enabled;
        s.held_depth = s.held and bus.pgxpDepthBuffer();
        if (!s.held) return;

        if (s.ram == null) s.ram = try s.allocator.create(@TypeOf(bus.ram_shadow));
        if (s.regs == null) s.regs = try s.allocator.create(Registers);
        // Field by field, never through a struct literal: the weld table
        // alone is a quarter of a megabyte, and a literal is built on the
        // stack of a thread the app gives 1 MB.
        @memcpy(s.ram.?, &bus.ram_shadow);
        const r = s.regs.?;
        r.gpr = cpu.gpr_shadow;
        r.load = cpu.load_shadow;
        r.delay = cpu.delay_shadow;
        r.hi = cpu.hi_shadow;
        r.lo = cpu.lo_shadow;
        r.cop0 = cpu.cop0_shadow;
        r.cop2 = cpu.cop2.precise;
        r.jit_loads = if (bus.blocks) |c| c.pins.load_shadows else @splat(.none);
        r.scratch = bus.scratch_shadow;
        r.pending = bus.pgxp_pending;
        r.fifo = bus.gpu.fifo_pgxp;
        r.cmd_buffer = bus.gpu.gp0.cmd_buffer_pgxp;
        @memcpy(&r.weld, &bus.gpu.gp0.weld);
        r.depth_state = bus.gpu.gp0.depth_state;
        if (s.held_depth) {
            if (s.depth == null) s.depth = try s.allocator.create(@TypeOf(bus.gpu.vram.depth));
            @memcpy(s.depth.?, &bus.gpu.vram.depth);
        }
    }

    /// Writes back what `take` held, while PGXP is still on: a setting
    /// turned off between the two has nothing left to read the shadows.
    pub fn restore(s: *const PgxpShadows, cpu: *Cpu) void {
        const bus = cpu.bus;
        if (!s.held or !bus.pgxp_enabled) return;
        @memcpy(&bus.ram_shadow, s.ram.?);
        const r = s.regs.?;
        cpu.gpr_shadow = r.gpr;
        cpu.load_shadow = r.load;
        cpu.delay_shadow = r.delay;
        cpu.hi_shadow = r.hi;
        cpu.lo_shadow = r.lo;
        cpu.cop0_shadow = r.cop0;
        cpu.cop2.precise = r.cop2;
        if (bus.blocks) |c| c.pins.load_shadows = r.jit_loads;
        bus.scratch_shadow = r.scratch;
        bus.pgxp_pending = r.pending;
        bus.gpu.fifo_pgxp = r.fifo;
        bus.gpu.gp0.cmd_buffer_pgxp = r.cmd_buffer;
        @memcpy(&bus.gpu.gp0.weld, &r.weld);
        if (s.held_depth and bus.pgxpDepthBuffer()) {
            bus.gpu.syncRaster();
            bus.gpu.gp0.depth_state = r.depth_state;
            @memcpy(&bus.gpu.vram.depth, s.depth.?);
        }
    }
};
