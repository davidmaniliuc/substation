//! PGXP's one shared type: a screen position kept at the precision the GTE
//! actually computed it with.
//!
//! Every consumer — `cop2/`, `cpu/`, `memory.zig`, `dma.zig`, `gpu/` — imports
//! this and nothing else of PGXP's, so the representation is decided in one
//! place.

const std = @import("std");

/// A projected screen position in 16.16.
///
/// The value is the raw MAC0 the projection produced, BEFORE the `>> 16` that
/// `cop2/opcodes.zig` applies to derive SX2/SY2. Keeping it unshifted is what
/// makes `resolves` exact: the shift there is literally the same operation,
/// so it reproduces the integer coordinate bit for bit, including for the
/// negative values off-screen geometry produces constantly.
///
/// `extern struct` because it travels in `Bus`'s shadow tables and in the GP0
/// FIFO alongside data the C ABI already sees; 16 bytes rather than a packed
/// 12 plus a side validity bitmap, which would save 4 MB and cost a second
/// dependent load on the hottest lookup in the feature.
pub const Precise = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    valid: u32 = 0,
    _pad: u32 = 0,

    pub const none: Precise = .{};

    /// Takes the wide accumulator values. MAC0 is a 32-bit register but
    /// `setMac0` returns the unnarrowed sum, and a projection that overflows
    /// it has already saturated its SXY beyond anything `resolves` would
    /// accept — so an out-of-range value is recorded as invalid rather than
    /// truncated into a plausible-looking one.
    pub fn make(x: i64, y: i64) Precise {
        const lo = -(1 << 31);
        const hi = (1 << 31) - 1;
        if (x < lo or x > hi or y < lo or y > hi) return none;
        return .{ .x = @intCast(x), .y = @intCast(y), .valid = 1 };
    }

    /// The identity predicate, and the reason invalidation only has to be good
    /// enough for coverage rather than for correctness: a shadow entry that
    /// outlived the value it described either fails this and is discarded, or
    /// passes it and therefore agrees with the integer vertex to within a
    /// pixel.
    pub fn resolves(self: Precise, ix: i16, iy: i16) bool {
        return self.valid != 0 and
            (self.x >> 16) == @as(i32, ix) and
            (self.y >> 16) == @as(i32, iy);
    }
};

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
