//! What a GP0 drawing command costs the GPU, in video cycles.
//!
//! The cost is what `Gpu.cycle_debt` is charged, and GPUSTAT bit 26 stays
//! clear until it is paid. That makes it observable: a game that queues a
//! large primitive and then polls to SEE the GPU busy (Hot Wheels Turbo
//! Racing's loading screen does exactly this) spins forever on a GPU that
//! finishes every draw within a couple of hundred cycles. Hardware is bound
//! by fill rate, so the cost scales with the pixels a primitive covers.
//!
//! Every formula is in GPU command ticks, which run at twice the CPU clock,
//! and `toVideo` converts once at the end: video cycles are 11/7 of the CPU's.

const Regs = @import("registers.zig");
const Primitive = @import("primitive.zig");

/// Per-polygon setup, indexed [quad][shaded][textured].
const polygon_setup = [2][2][2]u32{
    .{ .{ 46, 226 }, .{ 334, 496 } },
    .{ .{ 82, 262 }, .{ 370, 532 } },
};
const rectangle_setup: u32 = 16;
const line_setup: u32 = 16;

/// The drawing area as a clamp, in the same screen space as an offset vertex.
const Clamp = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn of(env: *const Regs.DrawingEnv) Clamp {
        const a = env.area();
        return .{ .x0 = a.x0, .y0 = a.y0, .x1 = a.x1, .y1 = a.y1 };
    }

    fn x(self: Clamp, v: i32) i32 {
        return @min(@max(v, self.x0), self.x1);
    }

    fn y(self: Clamp, v: i32) i32 {
        return @min(@max(v, self.y0), self.y1);
    }

    /// The pixels a [x0,x1) x [y0,y1) span covers inside the area.
    fn span(self: Clamp, x0: i32, y0: i32, x1: i32, y1: i32) struct { w: u32, h: u32 } {
        const l = @max(x0, self.x0);
        const t = @max(y0, self.y0);
        const r = @min(x1, self.x1 + 1);
        const b = @min(y1, self.y1 + 1);
        return .{ .w = @intCast(@max(r - l, 0)), .h = @intCast(@max(b - t, 0)) };
    }
};

pub fn toVideo(ticks: u32) u32 {
    return ticks * 11 / 14;
}

fn offsetX(env: *const Regs.DrawingEnv, p: Primitive.Point) i32 {
    return @as(i32, p.x) + env.getOffsetX();
}

fn offsetY(env: *const Regs.DrawingEnv, p: Primitive.Point) i32 {
    return @as(i32, p.y) + env.getOffsetY();
}

/// Blending and the mask test both read the destination first.
fn readsDestination(env: *const Regs.DrawingEnv, transparent: bool) bool {
    return transparent or (env.mask_bit & 2) != 0;
}

pub fn polygon(quad: bool, shaded: bool, textured: bool) u32 {
    return polygon_setup[@intFromBool(quad)][@intFromBool(shaded)][@intFromBool(textured)];
}

/// One triangle's fill. A triangle the renderer drops for its span fills
/// nothing and costs nothing past its polygon's setup.
pub fn triangle(env: *const Regs.DrawingEnv, a: Primitive.Point, b: Primitive.Point, c: Primitive.Point, textured: bool, transparent: bool) u32 {
    const xs = [3]i32{ offsetX(env, a), offsetX(env, b), offsetX(env, c) };
    const ys = [3]i32{ offsetY(env, a), offsetY(env, b), offsetY(env, c) };
    if (@max(xs[0], @max(xs[1], xs[2])) - @min(xs[0], @min(xs[1], xs[2])) >= 1024) return 0;
    if (@max(ys[0], @max(ys[1], ys[2])) - @min(ys[0], @min(ys[1], ys[2])) >= 512) return 0;

    // The area of the clamped triangle undershoots one that straddles the
    // area's edge, which is the safe direction to be wrong in.
    const k = Clamp.of(env);
    const x0 = k.x(xs[0]);
    const x1 = k.x(xs[1]);
    const x2 = k.x(xs[2]);
    const y0 = k.y(ys[0]);
    const y1 = k.y(ys[1]);
    const y2 = k.y(ys[2]);
    const twice = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
    var pixels: u32 = @intCast(@divTrunc(@as(i32, @intCast(@abs(twice))), 2));
    if (textured) pixels += pixels;
    if (readsDestination(env, transparent)) pixels += (pixels + 1) / 2;
    return pixels;
}

/// A rectangle's fill. Textured rows pay for texture-cache reloads, which
/// depend on the texel depth and, past 128 pixels, on the width alone.
pub fn rectangle(env: *const Regs.DrawingEnv, p: Primitive.Point, w: i32, h: i32, textured: bool, transparent: bool) u32 {
    if (w >= 1024 or h >= 512) return rectangle_setup;
    const x = offsetX(env, p);
    const y = offsetY(env, p);
    const s = Clamp.of(env).span(x, y, x + w, y + h);

    var per_row = s.w;
    if (textured) {
        const area = s.w * s.h;
        per_row += switch ((env.draw_mode >> 7) & 3) {
            0 => s.w,
            1 => if (s.w > 128) (s.w / 4) * 8 else if (area > 2048) (s.w / 4) * (4 * (128 / s.w)) else s.w,
            else => if (s.w > 128) (s.w / 2) * 8 else if (area > 1024) (s.w / 4) * (8 * (128 / s.w)) else s.w,
        };
    }
    if (readsDestination(env, transparent)) per_row += (s.w + 1) / 2;
    return rectangle_setup + per_row * s.h;
}

/// A line costs its longer axis.
pub fn line(env: *const Regs.DrawingEnv, x0: i32, y0: i32, x1: i32, y1: i32) u32 {
    const ox = env.getOffsetX();
    const oy = env.getOffsetY();
    const s = Clamp.of(env).span(@min(x0, x1) + ox, @min(y0, y1) + oy, @max(x0, x1) + ox + 1, @max(y0, y1) + oy + 1);
    if (s.w == 0 or s.h == 0) return line_setup;
    return line_setup + @max(s.w, s.h);
}

/// GP0(02): unmasked and unclipped, eight pixels a tick plus a per-row cost.
pub fn fill(w: u32, h: u32) u32 {
    return 46 + (w / 8 + 9) * h;
}

/// GP0(80): every pixel is a read and a write.
pub fn copy(w: u32, h: u32) u32 {
    return w * h * 2;
}
