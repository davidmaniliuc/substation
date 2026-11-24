//! The widescreen hack: the GTE narrows every projected X so a game's 4:3
//! view fills a wider screen, and the display stretches the picture back
//! out to that screen's shape. The world comes out undistorted and more of
//! it is in view; what a game culls at its own 4:3 edges still pops in at
//! the new ones, and 2D drawn by the CPU (a HUD, a menu) is stretched.
//!
//! Host configuration like the overclock: never in a state, and `off` is
//! the zero value so `Bus.init`'s memset leaves it there.

pub const Widescreen = enum(u8) {
    off = 0,
    wide_16_10 = 1,
    wide_16_9 = 2,
    wide_21_9 = 3,

    /// The shape the display draws the picture at.
    pub fn aspect(self: Widescreen) struct { w: u32, h: u32 } {
        return switch (self) {
            .off => .{ .w = 4, .h = 3 },
            .wide_16_10 => .{ .w = 16, .h = 10 },
            .wide_16_9 => .{ .w = 16, .h = 9 },
            .wide_21_9 => .{ .w = 21, .h = 9 },
        };
    }

    /// `aspect` as one number, width over height.
    pub fn ratio(self: Widescreen) f64 {
        const a = self.aspect();
        return @as(f64, @floatFromInt(a.w)) / @as(f64, @floatFromInt(a.h));
    }

    /// What a projected X is multiplied by, reduced: `(4 * h) / (3 * w)`,
    /// so stretching the 4:3 picture to `w:h` gives back the game's own
    /// proportions.
    pub fn xScale(self: Widescreen) struct { num: i64, den: i64 } {
        return switch (self) {
            .off => .{ .num = 1, .den = 1 },
            .wide_16_10 => .{ .num = 5, .den = 6 },
            .wide_16_9 => .{ .num = 3, .den = 4 },
            .wide_21_9 => .{ .num = 4, .den = 7 },
        };
    }
};
