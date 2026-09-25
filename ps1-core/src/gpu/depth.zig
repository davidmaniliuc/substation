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

/// One absolute reciprocal-depth unit: `reciprocal(1) == iz_one`. 2^30 keeps
/// `interp`'s numerator under 3 * 2^29 * 2^30 < 2^61, inside i64/long at every
/// internal resolution, and resolves the far end (W = 65535) to 1 part in 16k.
pub const iz_one: i32 = 1 << 30;

/// `round(2^30 / w)`, clamped to `[1, 2^30]`; 0 when `w` carries no depth
/// (not > 0, which also catches NaN). f64 because this is computed once per
/// vertex on the CPU and a quantisation step saved here costs nothing.
pub fn reciprocal(w: f32) i32 {
    if (!(w > 0)) return 0;
    const q = @round(@as(f64, iz_one) / @as(f64, w));
    return std.math.clamp(std.math.lossyCast(i32, q), 1, iz_one);
}

pub const Decision = struct { check: bool = false, write: bool = false };

/// DuckStation's rule, over one POLYGON's vertices (four for a quad, so both
/// halves agree): it tests only if every vertex carries a depth and the depths
/// are not all equal — a polygon at one depth is a 2D overlay drawn with a
/// projected position — and it is opaque or `transparent_depth` is on. A
/// transparent polygon never writes. Compared on W, not on the quantised iz.
pub fn decide(ws: []const f32, transparent: bool, enabled: bool, transparent_depth: bool) Decision {
    if (!enabled) return .{};
    for (ws) |w| if (!(w > 0)) return .{};
    const flat = for (ws[1..]) |w| {
        if (w != ws[0]) break false;
    } else true;
    if (flat) return .{};
    if (transparent and !transparent_depth) return .{};
    return .{ .check = true, .write = !transparent };
}

/// The polygon's mean W, capped at the far end as DuckStation's is.
pub fn averageW(ws: []const f32) f32 {
    var sum: f32 = 0;
    for (ws) |w| sum += w;
    return @min(sum / @as(f32, @floatFromInt(ws.len)), far_w);
}
