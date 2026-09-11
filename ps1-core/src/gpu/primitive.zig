//! Primitive-decode helpers for GP0 polygon/line/rectangle commands. Pure
//! functions on raw command words with no dependency on `Gp0Engine` — the
//! command-buffer glue that calls these stays in `gp0.zig`.

const std = @import("std");
const pgxp = @import("../pgxp/pgxp.zig");
const Value = pgxp.Value;

pub const Point = struct {
    x: i16,
    y: i16,
    /// Screen position in 16.16. Equals `x << 16` unless PGXP resolved a
    /// sub-pixel for this vertex.
    px: i32,
    py: i32,
    /// Whether PGXP supplied and accepted a candidate for this vertex.
    ///
    /// Carried explicitly rather than inferred from `px != x << 16`, because a
    /// vertex whose true sub-pixel lands exactly on the integer grid is
    /// indistinguishable from an unresolved one that way — and `Gp0Engine`'s
    /// mixed-primitive rule would then drag its NEIGHBOURS back to integers on
    /// account of a vertex that was in fact resolved. Not carried in the
    /// command record: `unify` runs before the sink, so a record never
    /// describes a mixed primitive.
    resolved: bool = false,
    /// Whether `toFixed` had to pull `px` or `py` back inside the wire's own
    /// pixel to produce this vertex — see `toFixed`. Always false when
    /// `resolved` is false. `Gp0Engine.point` reports this as its `clamped`
    /// counter; `primitive.zig` is the single place that decides it, so a
    /// change to `toFixed`'s rounding cannot silently stop being measured.
    clamped: bool = false,
};

pub const Size = struct {
    w: i32,
    h: i32,
};

pub const Texcoord = struct {
    u: u8,
    v: u8,
};

pub const TexturedPoint = struct {
    point: Point,
    texcoord: Texcoord,
};

pub inline fn getCommandLength(opcode: u8) usize {
    return switch (opcode) {
        0x00, 0x01, 0x1F => 1,
        0x02 => 3,
        0x20...0x23 => 4,
        0x24...0x27 => 7,
        0x30...0x33 => 6,
        0x34...0x37 => 9,
        0x28...0x2B => 5,
        0x2C...0x2F => 9,
        0x38...0x3B => 8,
        0x3C...0x3F => 12,
        0x40...0x47 => 3,
        0x50...0x57 => 4,
        0x60...0x63 => 3,
        0x64...0x67 => 4,
        0x70...0x73 => 2,
        0x74...0x77 => 3,
        0x78...0x7B => 2,
        0x7C...0x7F => 3,
        0x80 => 4,
        0xA0, 0xC0 => 3,
        0xE1...0xE6 => 1,
        else => 1,
    };
}

pub inline fn getPoint(value: u32) Point {
    const x = getX(value);
    const y = getY(value);
    return .{ .x = x, .y = y, .px = @as(i32, x) << 16, .py = @as(i32, y) << 16, .resolved = false };
}

/// `getPoint` with a candidate sub-pixel position. The candidate is used only
/// if it was recorded against the very word the wire carries: a projected
/// vertex's word IS its packed integer SXY, so a match means the sub-pixel
/// describes this vertex and no other.
///
/// `tolerance` is a second, weaker admission test in pixels, and a negative
/// value disables it — see `withinTolerance`.
pub inline fn getPointPrecise(value: u32, p: Value, tolerance: f32) Point {
    var pt = getPoint(value);
    if (p.flags & Value.valid_xy == Value.valid_xy and p.word == value) {
        const tx = pgxp.truncateVertexPosition(p.x);
        const ty = pgxp.truncateVertexPosition(p.y);
        if (!withinTolerance(pt.x, tx, tolerance) or !withinTolerance(pt.y, ty, tolerance)) return pt;
        const fx = toFixed(pt.x, tx);
        const fy = toFixed(pt.y, ty);
        pt.px = fx.v;
        pt.py = fy.v;
        pt.resolved = true;
        pt.clamped = fx.clamped or fy.clamped;
    }
    return pt;
}

/// How far a candidate may sit from the integer vertex it claims to describe,
/// per axis, in pixels. Negative disables it, which is the shipped default.
///
/// It is the mitigation for what word-matched staleness gives up: an untracked
/// write that happens to leave the word unchanged leaves a stale entry
/// admissible, and CPU-mode arithmetic can drift a shadow arbitrarily far from
/// the integer it accompanies. The check runs BEFORE `toFixed`, and that
/// ordering is the whole value of it — the clamp there pins a disagreeing
/// candidate inside the wire's own pixel, so after it no consumer can tell a
/// five-pixel drift from a sub-pixel one.
///
/// Measured against the TRUNCATED candidate, since that is what is compared
/// with the wire's own folded coordinate; against the raw value every vertex
/// past the 11-bit boundary would read as 2048 px adrift.
inline fn withinTolerance(base: i16, v: f32, tolerance: f32) bool {
    if (tolerance < 0) return true;
    return @abs(v - @as(f32, @floatFromInt(base))) <= tolerance;
}

/// `toFixed`'s result plus whether producing it required the clamp — see
/// `toFixed`.
const FixedResult = struct { v: i32, clamped: bool };

/// A precise coordinate into the record's 16.16, held inside the pixel the wire
/// names. The cast saturates because the record is `i32` and a garbage shadow
/// must not be able to trap here.
///
/// The clamp is NOT a staleness check — the word match already did that — it
/// bounds an `f32` rounding artifact. `f32` cannot hold every 16.16 position,
/// and a fraction within half an ulp of 1.0 rounds UP onto the next integer:
/// at x = 1023 that lands on 1024, whose 11-bit fold is -1024, and the vertex
/// is drawn 2047 columns from where its own command word says it is. What the
/// clamp restores is the invariant `renderer.zig`'s `toQ` documents,
/// `px >> 16 == x`.
///
/// `clamped` is true when the clamp actually moved the value — a CLAMP EVENT,
/// the `f32`-representation edge case itself, not merely "disagreed by more
/// than an artifact". `Gp0Engine.point` is the only consumer, and reads this
/// field rather than re-deriving the same conversion: this function is the
/// single source of truth for what counts as a clamp.
inline fn toFixed(base: i16, v: f32) FixedResult {
    const scaled = std.math.lossyCast(i32, @as(f64, v) * 65536.0);
    const lo = @as(i32, base) << 16;
    const clamped_v = std.math.clamp(scaled, lo, lo + 0xFFFF);
    return .{ .v = clamped_v, .clamped = clamped_v != scaled };
}

pub inline fn getSize(value: u32) Size {
    return .{
        .w = @intCast(value & 0xFFFF),
        .h = @intCast((value >> 16) & 0xFFFF),
    };
}

pub inline fn getTexcoord(value: u32) Texcoord {
    return .{
        .u = @truncate(value),
        .v = @truncate(value >> 8),
    };
}

pub inline fn getTexturedPoint(point_word: u32, texcoord_word: u32) TexturedPoint {
    return .{
        .point = getPoint(point_word),
        .texcoord = getTexcoord(texcoord_word),
    };
}

pub inline fn getClut(value: u32) u16 {
    return @truncate(value >> 16);
}

pub inline fn getTpage(value: u32) u16 {
    return @truncate(value >> 16);
}

pub inline fn isTransparent(opcode: u8) bool {
    return (opcode & 0x02) != 0;
}

pub inline fn getTexturedRectangleSize(opcode: u8, size_word: u32) Size {
    return switch (opcode & 0x18) {
        0x00 => getSize(size_word),
        0x10 => .{ .w = 8, .h = 8 },
        0x18 => .{ .w = 16, .h = 16 },
        else => unreachable,
    };
}

pub inline fn getX(val: u32) i16 {
    const bits = val & 0x7FF;
    const sign_extended = if ((bits & 0x400) != 0) bits | 0xF800 else bits;
    return @as(i16, @bitCast(@as(u16, @truncate(sign_extended))));
}

pub inline fn getY(val: u32) i16 {
    const bits = (val >> 16) & 0x7FF;
    const sign_extended = if ((bits & 0x400) != 0) bits | 0xF800 else bits;
    return @as(i16, @bitCast(@as(u16, @truncate(sign_extended))));
}
