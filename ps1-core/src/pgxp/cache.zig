//! PGXP's second lookup: a table keyed on a vertex's INTEGER screen position
//! rather than on where in memory its word lives.
//!
//! The address path answers "what was the precise value of the word at this
//! address" and misses whenever a game moved the vertex somewhere the hooks do
//! not follow — through a DMA the shadow does not cover, or through arithmetic
//! CPU mode is not on for. This answers the weaker question "what was the last
//! precise value ANY vertex had at this integer position", which is enough to
//! take the jitter out of a static scene and is wrong the moment two vertices
//! share a position.
//!
//! That weakness is why it ships off, and why a hit reports no depth: the
//! position is a guess that the word check cannot police, and a depth taken
//! from a guessed vertex would reach Phase 3's texturing.

const std = @import("std");
const pgxp = @import("pgxp.zig");
const Value = pgxp.Value;

/// The SXY range a projected vertex can occupy, one slot per integer position.
const span = 2048;
const half_span = span / 2;

/// 2048x2048 entries at 20 bytes is 83 MB. That is the reference's size and
/// not a number worth inventing a different one for, but it is far too large
/// to sit in `Bus` unconditionally, so the table is heap-allocated when the
/// setting is turned on and freed when it is turned off.
pub const VertexCache = struct {
    entries: [span * span]Value,

    pub fn init(allocator: std.mem.Allocator) !*VertexCache {
        const self = try allocator.create(VertexCache);
        // Zero is `Value.none`: every slot starts as a miss.
        @memset(std.mem.asBytes(self), 0);
        return self;
    }

    pub fn deinit(self: *VertexCache, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    /// The slot a packed SXY occupies, or null when either half is outside the
    /// range a projection can produce. The two halves ARE the key, so a slot
    /// belongs to exactly one word and no per-entry key check is needed.
    fn slot(word: u32) ?usize {
        const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(word))));
        const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(word >> 16))));
        if (x < -half_span or x >= half_span) return null;
        if (y < -half_span or y >= half_span) return null;
        return @intCast((y + half_span) * span + (x + half_span));
    }

    /// Record a projected vertex against its own position.
    ///
    /// A value with nothing valid in it is DROPPED rather than stored: a
    /// saturated projection has no precise position to cache, and letting it
    /// clear the slot would throw away a usable entry for a position the game
    /// is still drawing.
    pub fn put(self: *VertexCache, word: u32, v: Value) void {
        if (v.flags & Value.valid_xy != Value.valid_xy) return;
        const i = slot(word) orelse return;
        self.entries[i] = v;
    }

    /// The last precise value recorded at this position, without its depth.
    pub fn get(self: *const VertexCache, word: u32) ?Value {
        const i = slot(word) orelse return null;
        var v = self.entries[i];
        if (v.flags & Value.valid_xy != Value.valid_xy) return null;
        v.flags &= ~@as(u32, Value.valid_z);
        return v;
    }
};
