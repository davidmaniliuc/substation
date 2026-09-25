//! The PGXP depth buffer's decisions that are arithmetic: the reciprocal, which
//! polygons test, the average-depth jump that starts a new pass. Nothing here
//! knows GP0; `gp0.zig` asks and records the answers, so a Metal replay only
//! ever follows a record.

const std = @import("std");

/// The far end of the GTE's Z range, and the value "no depth tested since the
/// last clear" is stored as — DuckStation's `m_last_depth_z = 1.0`.
pub const far_w: f32 = 65535;
/// DuckStation's default `gpu_pgxp_depth_clear_threshold`, in W units.
pub const clear_threshold: f32 = 4096;

/// What `gp0` remembers between polygons.
pub const State = struct {
    /// The previous depth-tested polygon's average W.
    last_w: f32 = far_w,
    /// A polygon has tested since the last clear — the only case in which a
    /// drawing-area change has anything to clear.
    dirty: bool = false,

    /// Records a depth-tested polygon's average W; true when it sits at least
    /// `clear_threshold` FURTHER than the previous one. Signed on purpose: a
    /// jump toward the camera is a nearer object, a jump away is a new pass.
    /// `last_w` becomes this polygon's either way, as DuckStation's does.
    pub fn jump(self: *State, avg: f32) bool {
        const due = avg - self.last_w >= clear_threshold;
        self.last_w = avg;
        self.dirty = true;
        return due;
    }

    pub fn cleared(self: *State) void {
        self.* = .{};
    }
};
