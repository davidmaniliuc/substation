/// The Bresenham walk both line paths share: every pixel from the first
/// endpoint to the second, inclusive, in the order hardware draws them.
pub const LineWalk = struct {
    pub const Step = struct { x: i32, y: i32, k: i32 };

    /// max(|dx|, |dy|): drawShadedLine's denominator.
    steps: i32,
    cx: i32,
    cy: i32,
    target_x: i32,
    target_y: i32,
    dx: i32,
    dy: i32,
    sx: i32,
    sy: i32,
    err: i32,
    k: i32 = 0,
    done: bool = false,

    /// Null for a line hardware refuses: |dx| >= 1024 or |dy| >= 512, the same
    /// refusal the triangle rasterizer applies. Coordinates arrive with
    /// GP0(E5)'s offset ALREADY applied.
    pub fn init(x0: i32, y0: i32, x1: i32, y1: i32) ?LineWalk {
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));
        if (dx >= 1024 or dy >= 512) return null;
        return .{
            .steps = @max(dx, dy),
            .cx = x0,
            .cy = y0,
            .target_x = x1,
            .target_y = y1,
            .dx = dx,
            .dy = dy,
            .sx = if (x0 < x1) 1 else -1,
            .sy = if (y0 < y1) 1 else -1,
            .err = dx - dy,
        };
    }

    /// Yields every pixel from (x0, y0) to (x1, y1) inclusive, then null.
    pub fn next(self: *LineWalk) ?Step {
        if (self.done) return null;
        const step: Step = .{ .x = self.cx, .y = self.cy, .k = self.k };
        if (self.cx == self.target_x and self.cy == self.target_y) {
            self.done = true;
            return step;
        }
        const e2 = 2 * self.err;
        if (e2 > -self.dy) {
            self.err -= self.dy;
            self.cx += self.sx;
        }
        if (e2 < self.dx) {
            self.err += self.dx;
            self.cy += self.sy;
        }
        self.k += 1;
        return step;
    }
};
