//! PGXP's one shared type: a 32-bit word kept at the precision the value was
//! actually computed with, rather than the precision the machine stores.
//!
//! Every consumer — `cop2/`, `cpu/`, `memory.zig`, `dma.zig`, `gpu/` — imports
//! this and nothing else of PGXP's, so the representation is decided in one
//! place.

const std = @import("std");

/// One tracked 32-bit word, at the precision the value was actually computed
/// with.
///
/// `x` and `y` are the precise values of the word's LOW and HIGH halfwords —
/// NOT screen x and screen y. For a packed SXY the two readings coincide, and
/// for everything else they are simply two halves. That generalisation is the
/// whole reason arithmetic propagation is possible: a coupled screen position
/// has nothing to say the moment a game splits a word into two registers.
///
/// `word` is the integer this entry was recorded against, and is the staleness
/// check: a projected vertex's word IS its packed integer SXY, so a match
/// means the precise value agrees with that vertex's integers exactly.
///
/// `extern struct` because it travels in `Bus`'s shadow tables and in the GP0
/// FIFO alongside data the C ABI already sees; 20 bytes rather than a packed
/// form plus a side validity bitmap, which would save memory and cost a second
/// dependent load on the hottest lookup in the feature.
pub const Value = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Depth term. For a projected vertex this is the W that Phase 3's
    /// texture correction and depth buffer consume.
    z: f32 = 0,
    word: u32 = 0,
    flags: u32 = 0,

    pub const none: Value = .{};

    pub const valid_x: u32 = 1 << 0;
    pub const valid_y: u32 = 1 << 1;
    pub const valid_z: u32 = 1 << 2;
    pub const valid_xy: u32 = valid_x | valid_y;
    pub const valid_xyz: u32 = valid_xy | valid_z;
    /// Which half a z arrived from, so a half-word write can retire it.
    pub const low_z: u32 = 1 << 16;
    pub const high_z: u32 = 1 << 17;
    /// x or y has been altered since the z was recorded, so the z loses to an
    /// untainted one when two values are combined.
    pub const tainted_z: u32 = 1 << 31;

    pub fn validate(self: *Value, current: u32) void {
        if (self.word != current) self.flags = 0;
    }

    pub fn validX(self: Value, current: u32) f32 {
        if (self.flags & valid_x != 0) return self.x;
        return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(current)))));
    }

    pub fn validY(self: Value, current: u32) f32 {
        if (self.flags & valid_y != 0) return self.y;
        return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(current >> 16)))));
    }
};

/// The three helpers that model the 16-bit boundary between the halves.
///
/// Each converts through an integer, and each CLAMPS rather than wrapping on
/// the way. That is a deliberate divergence: the reference truncates to i64
/// and narrows to i32, which wraps, while Zig's `@intFromFloat` is illegal
/// out of range and would panic in a Debug build. A value far enough out of
/// range for the two to differ is not a coordinate under any reading, so
/// clamping costs nothing real and removes a crash.
/// Round onto the 1/65536 grid and reinterpret as a signed 16-bit quantity.
pub fn signFold(val: f64) f64 {
    const scaled = std.math.lossyCast(i64, val * 65536.0);
    const narrowed: i32 = @truncate(scaled);
    return @as(f64, @floatFromInt(narrowed)) / 65536.0;
}

/// Lift a negative half onto the unsigned 16-bit range.
pub fn unsign(val: f64) f64 {
    return if (val >= 0) val else val + 65536.0;
}

/// Extract the carry out of a low half.
pub fn overflow(val: f64) f64 {
    return @floatFromInt(std.math.lossyCast(i64, val) >> 16);
}

/// The GPU drops the upper 5 bits of a vertex coordinate when it parses a
/// command, so a precise position has to lose them too or it describes a
/// different pixel from the one the wire names. The fraction survives.
pub fn truncateVertexPosition(p: f32) f32 {
    const int_part = std.math.lossyCast(i32, p);
    const bits: u32 = @as(u32, @bitCast(int_part)) & 0x7FF;
    const sign_extended: u32 = if (bits & 0x400 != 0) bits | 0xFFFF_F800 else bits;
    const truncated: i32 = @bitCast(sign_extended);
    return @as(f32, @floatFromInt(truncated)) + (p - @as(f32, @floatFromInt(int_part)));
}
