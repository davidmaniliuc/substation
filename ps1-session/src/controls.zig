//! Every setting another thread hands the emulator thread: atomics, written
//! from any thread and read once per pass.
//!
//! The defaults are deliberately the "off" values rather than the shipped
//! ones: the session's owner re-applies every setting before `start`, and a
//! default that matched the shipped value would hide a setting it forgot.

const std = @import("std");
const machine = @import("machine.zig");

const Atomic = std.atomic.Value;

/// One bit per PGXP switch in `Controls.pgxp_flags`.
const Bit = enum(u5) {
    enabled,
    cpu,
    culling,
    texture_correction,
    color_correction,
    depth_buffer,
    transparent_depth,
    disable_2d,
    preserve_projection,
};

const bits = [_]struct { Bit, []const u8 }{
    .{ .enabled, "enabled" },
    .{ .cpu, "cpu" },
    .{ .culling, "culling" },
    .{ .texture_correction, "texture_correction" },
    .{ .color_correction, "color_correction" },
    .{ .depth_buffer, "depth_buffer" },
    .{ .transparent_depth, "transparent_depth" },
    .{ .disable_2d, "disable_2d" },
    .{ .preserve_projection, "preserve_projection" },
};

fn mask(b: Bit) u32 {
    return @as(u32, 1) << @backingInt(b);
}

/// The centred sticks, one byte per axis as the pad reports them.
pub const sticks_centred: u32 = 0x8080_8080;

pub const Controls = struct {
    /// A whole multiple of real time, 1 to `pacing.max_speed`.
    speed: Atomic(u32) = .init(1),
    paused: Atomic(bool) = .init(false),
    /// Active low: 0xFFFF is no button held.
    buttons: Atomic(u32) = .init(0xFFFF),
    /// lx | ly << 8 | rx << 16 | ry << 24.
    sticks: Atomic(u32) = .init(sticks_centred),
    /// Presses waiting for the emulator thread. A count rather than a flag
    /// only so a press is never lost to a race; the pad itself collapses
    /// several presses before one idle into one toggle.
    analog_presses: Atomic(u32) = .init(0),
    pgxp_flags: Atomic(u32) = .init(0),
    /// The tolerance's `f32` bit pattern; negative is the core's "none".
    pgxp_tolerance: Atomic(u32) = .init(@bitCast(@as(f32, -1))),
    /// Crosses to the machine only on CHANGE: it allocates or frees 83 MB.
    vertex_cache: Atomic(bool) = .init(false),
    /// `machine.Engine`, crossing only on change: a block engine allocates
    /// its cache.
    engine: Atomic(u8) = .init(@backingInt(machine.Engine.interpreter)),
    /// Rewind's memory budget in bytes, 0 for off; crosses only on change.
    rewind_budget: Atomic(usize) = .init(0),
    rewinding: Atomic(bool) = .init(false),
    /// Runahead frames, 0 for off.
    runahead: Atomic(u32) = .init(0),
    /// `PS1_SOFTWARE_DISPLAY` / `PS1_LIVE_DIFF`: their readers need the
    /// shadow of every frame. Set once, before the thread starts.
    shadow_every_frame: bool = false,

    pub fn pressAnalogButton(self: *Controls) void {
        _ = self.analog_presses.fetchAdd(1, .acq_rel);
    }

    pub fn takeAnalogPress(self: *Controls) bool {
        return self.analog_presses.swap(0, .acq_rel) > 0;
    }

    pub fn setPgxp(self: *Controls, p: machine.Pgxp) void {
        var flags: u32 = 0;
        inline for (bits) |b| {
            if (@field(p, b[1])) flags |= mask(b[0]);
        }
        self.pgxp_tolerance.store(@bitCast(p.tolerance), .release);
        self.pgxp_flags.store(flags, .release);
    }

    pub fn pgxp(self: *const Controls) machine.Pgxp {
        const flags = self.pgxp_flags.load(.acquire);
        var p: machine.Pgxp = .{ .tolerance = @bitCast(self.pgxp_tolerance.load(.acquire)) };
        inline for (bits) |b| @field(p, b[1]) = flags & mask(b[0]) != 0;
        return p;
    }

    /// Whether the depth plane travels with every shadow: the PGXP depth
    /// buffer switch itself, so the machine and the shadows can never
    /// disagree about it.
    pub fn depthBuffer(self: *const Controls) bool {
        return self.pgxp_flags.load(.acquire) & mask(.depth_buffer) != 0;
    }
};
