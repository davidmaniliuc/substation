const Vram = @import("vram.zig").Vram;

/// The CPU->VRAM (GP0(A0)) transfer cursor, planned a batch of words at a
/// time. `Vram.writeData` is the reference: this owns the cursor and nothing
/// else, so a backend that does not write through `Vram` still agrees with it
/// on which pixels a run of words covers. Bounds checks and the E6 mask belong
/// to whoever does the writing.
pub const WriteCursor = struct {
    active: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    /// After `Vram.axisExtent`: 0 means the whole axis.
    w: usize = 0,
    h: usize = 0,
    /// Transfer pixel index of the next word's low half.
    cursor: usize = 0,
    remaining: usize = 0,

    pub const Run = struct { first: usize, last: usize, consumed: usize };

    pub fn setup(x: i32, y: i32, w: i32, h: i32) WriteCursor {
        const wu: usize = @intCast(w);
        const hu: usize = @intCast(h);
        const remaining = Vram.transferWords(wu, hu);
        return .{
            .active = remaining > 0,
            .x = x,
            .y = y,
            .w = Vram.axisExtent(wu, 1024),
            .h = Vram.axisExtent(hu, 512),
            .remaining = remaining,
        };
    }

    pub fn abort(self: *WriteCursor) void {
        self.active = false;
    }

    pub fn pixelCount(self: WriteCursor) usize {
        return self.w * self.h;
    }

    /// Advances by up to `words` words and reports the contiguous slice of
    /// transfer PIXEL indices they cover. `first` is always even, because
    /// every word writes two pixels, which lets a shader recover the word
    /// from the pixel with a single shift.
    pub fn plan(self: *WriteCursor, words: usize) ?Run {
        if (!self.active or words == 0) return null;
        const first = self.cursor;
        const consumed = @min(words, self.remaining);
        const after = @min(first + 2 * consumed, self.pixelCount());
        self.cursor = after;
        self.remaining -= consumed;
        if (self.remaining == 0) self.active = false;
        if (after <= first) return null;
        return .{ .first = first, .last = after - 1, .consumed = consumed };
    }
};
