//! PGXP's one shared type: a screen position kept at the precision the GTE
//! actually computed it with.
//!
//! Every consumer — `cop2/`, `cpu/`, `memory.zig`, `dma.zig`, `gpu/` — imports
//! this and nothing else of PGXP's, so the representation is decided in one
//! place.

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
