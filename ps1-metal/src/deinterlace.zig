//! How a 480i frame drawn as fields becomes the picture the window shows.
//!
//! Under interlaced rendering the core skips the displayed field's rows, so
//! at the end of a frame the render texture holds the newest field and the
//! one before it, interleaved: woven. Weave is the texture as drawn, and
//! Single Field and Blend pick lines of it in the display shader. Only
//! Adaptive needs the past: the woven picture two back holds fields n-2 and
//! n-3 at exactly the rows n and n-1 occupy now. That history lives here,
//! keyed by `Shown.id`, so it advances once per picture shown, never per
//! present, and it is kept at native resolution: it only decides motion.

const std = @import("std");
const mtl = @import("mtl.zig");
const display = @import("display.zig");
const Shown = @import("live_renderer.zig").Shown;
const Rows = @import("ps1_core").gpu.Rows;

/// The player's setting. The raw values are the C ABI's `PS1_DEINTERLACE_*`;
/// Progressive is 0, so a zeroed setting is the picture as it always was.
pub const Mode = enum(u32) {
    progressive = 0,
    adaptive = 1,
    blend = 2,
    weave = 3,
    single_field = 4,

    /// Whether the core draws fields: the one place the mode becomes
    /// `Gpu.interlaced_rendering`.
    pub fn drawsFields(self: Mode) bool {
        return self != .progressive;
    }
};

/// `p` with the reconstruction `mode` asks for, given the rows the shown
/// picture's newest frame drew. Weave, Progressive, a display that is off or
/// one field tall, and a picture not drawn as a field all keep `deint` 0:
/// the texture as drawn.
pub fn picture(mode: Mode, p: display.Params, rows: Rows) display.Params {
    var q = p;
    q.deint = 0;
    q.newest = 0;
    q.has_reference = 0;
    switch (mode) {
        .progressive, .weave => return q,
        .adaptive, .blend, .single_field => {},
    }
    if (p.enabled == 0 or p.width == 0 or p.height <= 256) return q;
    const parity: u32 = switch (rows) {
        .all => return q,
        .even => 0,
        .odd => 1,
    };
    q.deint = @backingInt(mode);
    // Relative to the display's first row, which is where the shader counts.
    q.newest = (parity ^ p.vram_y) & 1;
    return q;
}

/// Which woven picture sits in which texture slot.
pub const History = struct {
    pub const len = 3;
    pub const Tag = struct {
        id: u64,
        /// `Params.newest` of that picture.
        newest: u32,
        /// Its native width and height.
        size: [2]u32,
    };
    pub const Admit = struct { slot: usize, draw: bool };

    tags: [len]?Tag = @splat(null),
    /// The slot holding the newest tag.
    head: usize = 0,

    /// Records `t` as the picture shown now. The same picture again (a
    /// pause, a 120 Hz display, a screenshot after a present) moves nothing
    /// and draws nothing. Another picture takes the oldest slot and must be
    /// drawn into it; one of another size first empties the ring.
    pub fn admit(self: *History, t: Tag) Admit {
        if (self.tags[self.head]) |h| if (std.meta.eql(h, t)) return .{ .slot = self.head, .draw = false };
        for (self.tags) |tag| if (tag) |o| if (!std.meta.eql(o.size, t.size)) {
            self.clear();
            break;
        };
        self.head = (self.head + 1) % len;
        self.tags[self.head] = t;
        return .{ .slot = self.head, .draw = true };
    }

    /// Adaptive's reference: the newest older picture whose newest field has
    /// the head's parity. Its rows of that parity then hold an earlier field
    /// of it (n-2 in steady play) and its other rows an earlier field of the
    /// other (n-3). After a gap it is whatever older picture still lines up,
    /// or none, never one that does not.
    pub fn reference(self: *const History) ?usize {
        const h = self.tags[self.head] orelse return null;
        for (1..len) |back| {
            const slot = (self.head + len - back) % len;
            const t = self.tags[slot] orelse continue;
            if (t.newest == h.newest) return slot;
        }
        return null;
    }

    pub fn clear(self: *History) void {
        self.tags = @splat(null);
    }
};

/// The textures behind `History`, on the render thread. Only Adaptive holds
/// any.
pub const Deinterlacer = struct {
    history: History = .{},
    /// Native `bgra8Unorm` pictures of `size`, by `History` slot.
    woven: [History.len]?mtl.Texture = @splat(null),
    size: [2]u32 = .{ 0, 0 },

    /// Sets `p`'s reconstruction for the picture `shown` and returns what to
    /// draw it from: `src`, with Adaptive's reference when one lines up.
    /// Called by every present and screenshot pass; for the same picture
    /// again it draws nothing.
    pub fn prepare(self: *Deinterlacer, cmd: mtl.CommandBuffer, pass: *display.DisplayPass, mode: Mode, src: display.Source, p: *display.Params, shown: Shown) display.Source {
        p.* = picture(mode, p.*, shown.rows);
        if (mode != .adaptive) {
            self.release();
            return src;
        }
        // Nothing reconstructed now: the next reconstruction compares
        // against nothing older than itself.
        if (p.deint == 0) {
            self.history.clear();
            return src;
        }
        const size: [2]u32 = .{ p.width, p.height };
        if (!std.meta.eql(size, self.size)) {
            self.release();
            self.size = size;
        }
        const a = self.history.admit(.{ .id = shown.id, .newest = p.newest, .size = size });
        if (a.draw and !self.weave(cmd, pass, a.slot, src, p.*)) {
            self.history.clear();
            return src;
        }
        const r = self.history.reference() orelse return src;
        p.has_reference = 1;
        var out = src;
        out.reference = self.woven[r];
        return out;
    }

    fn weave(self: *Deinterlacer, cmd: mtl.CommandBuffer, pass: *display.DisplayPass, slot: usize, src: display.Source, p: display.Params) bool {
        if (self.woven[slot] == null) {
            self.woven[slot] = cmd.device().newTexture2D(.{
                .format = .bgra8Unorm,
                .width = p.width,
                .height = p.height,
                .storage = .private,
                .usage = .{ .renderTarget = true, .shaderRead = true },
            }) catch return false;
        }
        return pass.encodeWoven(cmd, self.woven[slot].?, src, p);
    }

    /// Frees the pictures and forgets them.
    pub fn release(self: *Deinterlacer) void {
        for (&self.woven) |*t| {
            if (t.*) |w| w.release();
            t.* = null;
        }
        self.history.clear();
        self.size = .{ 0, 0 };
    }
};
