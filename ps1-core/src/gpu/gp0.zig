const std = @import("std");
const Vram = @import("vram.zig").Vram;
const Regs = @import("registers.zig");
const Sink = @import("sink.zig").Sink;

/// Entries in `Gp0Engine.weld`. A power of two so the index is a mask.
const weld_size = 1 << 14;

const WeldSlot = struct {
    /// Packed integer (x, y) plus one; 0 means empty. Compared before the
    /// position is used, so a collision costs a weld and never a wrong vertex.
    key: u32 = 0,
    px: i32 = 0,
    py: i32 = 0,
    resolved: bool = false,
};
const Primitive = @import("primitive.zig");
const Color = @import("color.zig");
const Precise = @import("../pgxp.zig").Precise;

pub const Gp0Engine = struct {
    /// Host-side instrumentation, read by `ps1-golden --pgxp`. Not machine
    /// state: excluded from the trace hash for the same reason
    /// `cdrom.pending_cycles` is.
    pub const PgxpStats = struct {
        vertices: u64 = 0,
        resolved: u64 = 0,
        /// A candidate that was present but disagreed with the wire — the
        /// coverage diagnostic. Never an error: the vertex simply falls back.
        identity_fail: u64 = 0,
        /// Displacement in 16.16 units, summed and peak.
        disp_sum: u64 = 0,
        disp_max: u32 = 0,
        /// Primitives whose vertices did NOT all resolve and were therefore
        /// snapped back onto the integer grid — see `unify`. Not a failure
        /// count: it is how much of the hit-rate above does not reach the
        /// screen, which is the number to read next to it.
        mixed_primitives: u64 = 0,
        /// Primitives whose integer geometry is thinner than a pixel somewhere,
        /// and which therefore keep their integer vertices — see `thinPrimitive`.
        thin_primitives: u64 = 0,
        /// Vertices moved onto the position already established for their
        /// integer coordinate this frame — see `weldPoint`. Counts both
        /// directions: an unresolved vertex adopting a sub-pixel position, and
        /// a resolved one giving its up.
        welded: u64 = 0,
        /// Vertices left unwelded because another integer position held the
        /// table slot. A missed weld is a surviving crack, never a wrong
        /// position — the key is compared before the value is used.
        weld_collisions: u64 = 0,
    };

    cmd_buffer: [16]u32 = [_]u32{0} ** 16,
    /// Provenance for the words in `cmd_buffer`, same indices.
    cmd_buffer_pgxp: [16]Precise = [_]Precise{.{}} ** 16,
    words_remaining: usize = 0,
    words_read: usize = 0,

    // Polyline State
    polyline_active: bool = false,
    polyline_shaded: bool = false,
    polyline_count: usize = 0,
    polyline_transparent: bool = false,
    polyline_prev_x: i16 = 0,
    polyline_prev_y: i16 = 0,
    polyline_prev_color: u32 = 0,
    polyline_next_color: u32 = 0,

    pgxp: PgxpStats = .{},

    /// Mirrors `Bus.pgxp_enabled`. Only the weld reads it, and only to skip
    /// itself: with PGXP off every vertex would publish `x << 16` and every
    /// weld would be a no-op, so the table would be filled and cleared once a
    /// frame to decide nothing.
    pgxp_enabled: bool = false,

    /// One entry per integer screen position touched this frame — see
    /// `weldPoint`. 16,384 entries is about 8x the vertex count of a busy PS1
    /// frame, which keeps collisions rare without putting a megabyte in `Bus`.
    weld: [weld_size]WeldSlot = [_]WeldSlot{.{}} ** weld_size,

    pub fn write(self: *Gp0Engine, value: u32, p: Precise, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, interrupt_flag: *bool) u32 {
        if (vram.write_active) {
            sink.vramWriteData(vram, draw_env, value);
            return 1;
        }

        if (self.polyline_active) {
            self.continuePolyline(value, sink, vram, draw_env);
            return 50; // Approximated cost per segment
        }

        if (self.words_remaining == 0) {
            const opcode: u8 = @intCast((value >> 24) & 0xFF);

            // Catch Polyline commands
            if ((opcode & 0xF8) == 0x48 or (opcode & 0xF8) == 0x58) {
                self.startPolyline(value);
                return 10;
            }

            const length = Primitive.getCommandLength(opcode);
            self.cmd_buffer[0] = value;
            self.cmd_buffer_pgxp[0] = p;
            self.words_read = 1;
            self.words_remaining = if (length > 0) length - 1 else 0;
        } else {
            if (self.words_read < self.cmd_buffer.len) {
                self.cmd_buffer[self.words_read] = value;
                self.cmd_buffer_pgxp[self.words_read] = p;
            }
            self.words_read += 1;
            if (self.words_remaining > 0) self.words_remaining -= 1;
        }

        if (self.words_remaining == 0) {
            return self.execute(sink, vram, draw_env, interrupt_flag);
        }
        return 0; // Just collecting command arguments
    }

    /// Decode a vertex word together with its provenance, counting the outcome.
    fn point(self: *Gp0Engine, idx: usize) Primitive.Point {
        const word = self.cmd_buffer[idx];
        const cand = self.cmd_buffer_pgxp[idx];
        const pt = Primitive.getPointPrecise(word, cand);

        self.pgxp.vertices += 1;
        if (cand.resolves(pt.x, pt.y)) {
            // Accepted: the candidate is valid and agrees with the wire's
            // integer coordinate. Counted as resolved even when the
            // sub-pixel happens to land exactly on the integer grid (d == 0)
            // -- that displacement is trivially zero, so it is absorbed by
            // disp_sum/disp_max without a special case, and "resolved" keeps
            // its one meaning: PGXP found and accepted an entry for this
            // vertex.
            self.pgxp.resolved += 1;
            const dx: u32 = @abs(pt.px - (@as(i32, pt.x) << 16));
            const dy: u32 = @abs(pt.py - (@as(i32, pt.y) << 16));
            const d = @max(dx, dy);
            self.pgxp.disp_sum += d;
            if (d > self.pgxp.disp_max) self.pgxp.disp_max = d;
        } else if (cand.valid != 0) {
            // A candidate was present and disagreed with the wire: a stale
            // entry, correctly discarded. Counted, never logged and never
            // fatal — a busy frame carries tens of thousands of vertices.
            self.pgxp.identity_fail += 1;
        }
        return pt;
    }

    /// A primitive's vertices must come from ONE coordinate space.
    ///
    /// PGXP resolves per vertex; coverage is decided per primitive. A triangle
    /// holding one sub-pixel corner and two integer ones is not a refinement
    /// of the shape hardware drew — it is a third shape, with one corner
    /// displaced by up to a whole pixel. On a large polygon that reads as a
    /// seam against its neighbour; on a 25-pixel character model, whose
    /// triangles are a few pixels each, it destroys the triangle.
    ///
    /// So a mixed primitive drops back to integers entirely, and the feature
    /// degrades to "off" exactly where it cannot be applied consistently.
    ///
    /// No `pgxp_enabled` gate is needed: with PGXP off no vertex is ever
    /// marked resolved, so `any` stays false and nothing is touched.
    /// Minimum altitude, below which a primitive keeps its integer vertices,
    /// expressed as `thin_den / thin_num > altitude^2` to stay in integers.
    ///
    /// 1.5 px. The measured boundary is 1.25: over 3,678 random small
    /// triangles that paint at least one pixel at integer positions, a
    /// sub-pixel TRANSLATION deleted 35 of them with no rule at all, 3 at a
    /// threshold of 1.0, and none at 1.25 or above. 1.5 is that boundary plus
    /// margin, and the margin is nearly free: everything between 1.25 and 1.5
    /// is geometry thinner than a pixel and a half, where a sub-pixel
    /// refinement of the position is worth nothing that can be seen.
    const thin_num: i64 = 4;
    const thin_den: i64 = 9;

    /// Whether the INTEGER triangle is thinner than `thin_den/thin_num` of a
    /// pixel anywhere — i.e. whether a sub-pixel translation of it could slip
    /// between the sample points and paint nothing at all.
    ///
    /// This is the one place PGXP can DELETE geometry rather than merely move
    /// it, and deleting what hardware draws is a regression, not a refinement.
    /// Sampling is at whole-pixel positions, and the integer vertices are what
    /// guarantee hardware hits one; once the shape is translated by a fraction
    /// a thin triangle can miss every sample point. Measured: a 2x1 triangle
    /// that hardware paints with 2 pixels paints ZERO at 7 of the 15 sub-pixel
    /// offsets, with all three vertices resolved consistently.
    ///
    /// The criterion is thinness, and neither of the two cheaper guesses
    /// works: area does not (a right isoceles triangle survives from leg 2 up,
    /// twice-area 4) and neither does the bounding box (a diagonal sliver in
    /// an 8x8 box still vanishes at 8 of 255 offsets).
    ///
    /// It is decided on the INTEGER geometry and inside `gp0`, before the
    /// sink, so the record a Metal replay consumes is already unified and the
    /// two rasterizers cannot disagree about it.
    fn thinIntegerTriangle(a: Primitive.Point, b: Primitive.Point, c: Primitive.Point) bool {
        const ax: i64 = a.x;
        const ay: i64 = a.y;
        const bx: i64 = b.x;
        const by: i64 = b.y;
        const cx: i64 = c.x;
        const cy: i64 = c.y;
        const twice_area = @abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax));
        const e0 = (bx - ax) * (bx - ax) + (by - ay) * (by - ay);
        const e1 = (cx - bx) * (cx - bx) + (cy - by) * (cy - by);
        const e2 = (ax - cx) * (ax - cx) + (ay - cy) * (ay - cy);
        const longest = @max(e0, @max(e1, e2));
        const ta: i64 = @intCast(twice_area);
        // min altitude = twice_area / longest_side, so
        //   altitude < t  <=>  twice_area^2 < t^2 * longest_side^2.
        return thin_num * ta * ta < thin_den * longest;
    }

    fn thinPrimitive(pts: []const Primitive.Point) bool {
        if (pts.len < 3) return false;
        if (thinIntegerTriangle(pts[0], pts[1], pts[2])) return true;
        if (pts.len == 4 and thinIntegerTriangle(pts[1], pts[2], pts[3])) return true;
        return false;
    }

    /// A primitive's vertices come from one coordinate space; so do a FRAME's.
    ///
    /// `unify` makes each primitive internally consistent, and that is not
    /// enough. Two primitives sharing an edge are judged separately, so one can
    /// be fully resolved and the other fully unresolved — each internally
    /// consistent, `mixed_primitives` counting neither — and the shared edge is
    /// then drawn in two places up to a pixel apart. The pixels between the two
    /// positions are painted by neither: a crack.
    ///
    /// Measured on the BIOS logo, which is the cheapest reproduction this
    /// feature has (no disc, no game, `bios-only`): of 32,043 shared integer
    /// edges, 372 were placed differently by their two primitives, and EVERY
    /// one of those was a resolved vertex meeting an unresolved one — none was
    /// a disagreement between two accepted sub-pixel values. Those 372 edges
    /// opened 434 unpainted pixels, and 426 of them had no newly-painted pixel
    /// within a pixel, so they were cracks rather than edges moving.
    ///
    /// The rule: the FIRST vertex at an integer position fixes the position
    /// every later vertex there is drawn at. Whichever arrived first wins, so
    /// an unresolved vertex can adopt a sub-pixel position and a resolved one
    /// can lose its own; both directions are welds, and the point is only that
    /// the frame agrees with itself. Two distinct model vertices that happen to
    /// share an integer pixel are welded too — they are then drawn within a
    /// pixel of each other, which is exactly where hardware drew both.
    ///
    /// It runs AFTER `unify`, so the table records what is actually drawn: a
    /// primitive snapped back to integers by the thin or mixed rule must
    /// publish its integers, not the sub-pixels it was denied.
    ///
    /// Like the other two rules this is decided in `gp0` on the way to the
    /// sink, so a Metal replay consumes an already-welded record. It needs no
    /// `pgxp_enabled` gate: with PGXP off every vertex stores `x << 16` and
    /// every weld is a no-op that cannot move a pixel.
    fn weldPoint(self: *Gp0Engine, pt: *Primitive.Point) void {
        if (!self.pgxp_enabled) return;
        // +1 so that an all-zero slot reads as empty rather than as the
        // position (0, 0), which is a real coordinate games draw at.
        const key: u32 = (@as(u32, @as(u16, @bitCast(pt.x))) << 16 |
            @as(u32, @as(u16, @bitCast(pt.y)))) +% 1;
        var h: u32 = key *% 0x9E3779B1;
        h ^= h >> 15;
        const slot = &self.weld[h & (weld_size - 1)];

        if (slot.key == key) {
            if (slot.px != pt.px or slot.py != pt.py) {
                pt.px = slot.px;
                pt.py = slot.py;
                pt.resolved = slot.resolved;
                self.pgxp.welded += 1;
            }
            return;
        }
        // An occupied slot belonging to a different position is left alone
        // rather than evicted: whichever position keeps it stays consistent for
        // the whole frame, where trading them back and forth would make both
        // inconsistent.
        if (slot.key != 0) {
            self.pgxp.weld_collisions += 1;
            return;
        }
        slot.* = .{ .key = key, .px = pt.px, .py = pt.py, .resolved = pt.resolved };
    }

    fn weldPrimitive(self: *Gp0Engine, pts: []Primitive.Point) void {
        for (pts) |*pt| self.weldPoint(pt);
    }

    /// The table describes one frame's geometry and nothing else: the same
    /// integer position means a different model vertex in the next frame, and a
    /// surviving entry would pin it to where it was last time.
    pub fn endFrame(self: *Gp0Engine) void {
        if (!self.pgxp_enabled) return;
        @memset(&self.weld, .{});
    }

    /// `endFrame` without the gate, for the one caller that has just changed
    /// the gate and must clear what the old setting left behind.
    pub fn endFrameForced(self: *Gp0Engine) void {
        @memset(&self.weld, .{});
    }

    fn unify(self: *Gp0Engine, pts: []Primitive.Point) void {
        self.unifySpace(pts);
        self.weldPrimitive(pts);
    }

    fn unifySpace(self: *Gp0Engine, pts: []Primitive.Point) void {
        var any = false;
        var all = true;
        for (pts) |pt| {
            if (pt.resolved) any = true else all = false;
        }
        if (any and thinPrimitive(pts)) {
            self.pgxp.thin_primitives += 1;
            for (pts) |*pt| {
                pt.px = @as(i32, pt.x) << 16;
                pt.py = @as(i32, pt.y) << 16;
                pt.resolved = false;
            }
            return;
        }
        if (!any or all) return;
        self.pgxp.mixed_primitives += 1;
        for (pts) |*pt| {
            pt.px = @as(i32, pt.x) << 16;
            pt.py = @as(i32, pt.y) << 16;
            pt.resolved = false;
        }
    }

    /// `unify` for the textured paths, which carry the point inside a
    /// `TexturedPoint`. Separate rather than generic because the alternative is
    /// a scratch array of pointers per primitive on the hottest path in gp0.
    fn unifyTextured(self: *Gp0Engine, vs: []Primitive.TexturedPoint) void {
        self.unifyTexturedSpace(vs);
        for (vs) |*v| self.weldPoint(&v.point);
    }

    fn unifyTexturedSpace(self: *Gp0Engine, vs: []Primitive.TexturedPoint) void {
        var any = false;
        var all = true;
        for (vs) |v| {
            if (v.point.resolved) any = true else all = false;
        }
        var pts: [4]Primitive.Point = undefined;
        for (vs, 0..) |v, i| pts[i] = v.point;
        if (any and thinPrimitive(pts[0..vs.len])) {
            self.pgxp.thin_primitives += 1;
            for (vs) |*v| {
                v.point.px = @as(i32, v.point.x) << 16;
                v.point.py = @as(i32, v.point.y) << 16;
                v.point.resolved = false;
            }
            return;
        }
        if (!any or all) return;
        self.pgxp.mixed_primitives += 1;
        for (vs) |*v| {
            v.point.px = @as(i32, v.point.x) << 16;
            v.point.py = @as(i32, v.point.y) << 16;
            v.point.resolved = false;
        }
    }

    /// `point` plus the texcoord half, for the textured paths.
    fn texturedPoint(self: *Gp0Engine, point_idx: usize, texcoord_idx: usize) Primitive.TexturedPoint {
        return .{
            .point = self.point(point_idx),
            .texcoord = Primitive.getTexcoord(self.cmd_buffer[texcoord_idx]),
        };
    }

    fn execute(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, interrupt_flag: *bool) u32 {
        const opcode: u8 = @intCast((self.cmd_buffer[0] >> 24) & 0xFF);
        var cost: u32 = 10; // Base cost

        switch (opcode) {
            0x00, 0x01 => {}, // NOP / Clear Cache
            0x1F => interrupt_flag.* = true,
            0xE1...0xE6 => sink.setDrawEnv(vram, draw_env, opcode, self.cmd_buffer[0]),

            0x02 => {
                self.fillRectangle(sink, vram, draw_env);
                cost = 200;
            },
            0x80 => {
                self.copyRectangle(sink, vram, draw_env);
                cost = 200;
            },
            0xA0 => {
                self.setupVramWrite(sink, vram, draw_env);
                cost = 20;
            },
            0xC0 => {
                self.setupVramRead(sink, vram, draw_env);
                cost = 20;
            },

            0x20...0x23 => {
                self.drawFlatTriangle(sink, vram, draw_env, opcode);
                cost = 100;
            },
            0x28...0x2B => {
                self.drawFlatQuad(sink, vram, draw_env, opcode);
                cost = 200;
            },
            0x30...0x33 => {
                self.drawShadedTriangle(sink, vram, draw_env, opcode);
                cost = 150;
            },
            0x38...0x3B => {
                self.drawShadedQuad(sink, vram, draw_env, opcode);
                cost = 300;
            },
            0x24...0x27 => {
                self.drawTexturedTriangleCommand(sink, vram, draw_env, opcode);
                cost = 150;
            },
            0x2C...0x2F => {
                self.drawTexturedQuadCommand(sink, vram, draw_env, opcode);
                cost = 300;
            },
            0x34...0x37 => {
                self.drawShadedTexturedTriangle(sink, vram, draw_env, opcode);
                cost = 200;
            },
            0x3C...0x3F => {
                self.drawShadedTexturedQuad(sink, vram, draw_env, opcode);
                cost = 400;
            },
            0x40...0x47 => {
                self.drawLine(sink, vram, draw_env, opcode);
                cost = 50;
            },
            0x50...0x57 => {
                self.drawShadedLine(sink, vram, draw_env, opcode);
                cost = 75;
            },
            0x60...0x63 => {
                self.drawRectangle(sink, vram, draw_env, opcode);
                cost = 100;
            },
            0x64,
            0x65,
            0x66,
            0x67, // Variable size
            0x74,
            0x75,
            0x76,
            0x77, // 8x8
            0x7C,
            0x7D,
            0x7E,
            0x7F,
            => {
                self.drawTexturedRectangle(sink, vram, draw_env, opcode);
                cost = 150;
            },
            0x70...0x73 => {
                self.drawFixedRectangle(sink, vram, draw_env, opcode, 8);
                cost = 50;
            },
            0x78...0x7B => {
                self.drawFixedRectangle(sink, vram, draw_env, opcode, 16);
                cost = 100;
            },
            else => {},
        }

        self.words_remaining = 0;
        self.words_read = 0;
        return cost;
    }

    fn fillRectangle(self: *const Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv) void {
        const color16 = Color.getColor16(self.cmd_buffer[0]);
        const x = Primitive.getX(self.cmd_buffer[1]);
        const y = Primitive.getY(self.cmd_buffer[1]);
        const w: i16 = @intCast(self.cmd_buffer[2] & 0xFFFF);
        const h: i16 = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);

        sink.fillRect(vram, draw_env, x, y, w, h, color16);
    }

    fn copyRectangle(self: *const Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv) void {
        const sx: u16 = @intCast(self.cmd_buffer[1] & 0xFFFF);
        const sy: u16 = @intCast((self.cmd_buffer[1] >> 16) & 0xFFFF);
        const dx: u16 = @intCast(self.cmd_buffer[2] & 0xFFFF);
        const dy: u16 = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);
        const w: u16 = @intCast(self.cmd_buffer[3] & 0xFFFF);
        const h: u16 = @intCast((self.cmd_buffer[3] >> 16) & 0xFFFF);

        sink.copyRect(vram, draw_env, sx, sy, dx, dy, w, h);
    }

    fn setupVramWrite(self: *const Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv) void {
        const x: usize = @intCast(self.cmd_buffer[1] & 0xFFFF);
        const y: usize = @intCast((self.cmd_buffer[1] >> 16) & 0xFFFF);
        const w: usize = @intCast(self.cmd_buffer[2] & 0xFFFF);
        const h: usize = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);

        sink.vramWriteSetup(vram, draw_env, x, y, w, h);
    }

    fn setupVramRead(self: *const Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv) void {
        const x: usize = @intCast(self.cmd_buffer[1] & 0xFFFF);
        const y: usize = @intCast((self.cmd_buffer[1] >> 16) & 0xFFFF);
        const w: usize = @intCast(self.cmd_buffer[2] & 0xFFFF);
        const h: usize = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);

        sink.vramReadSetup(vram, draw_env, x, y, w, h);
    }

    fn drawFlatTriangle(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        var pts = [3]Primitive.Point{ self.point(1), self.point(2), self.point(3) };
        self.unify(&pts);

        sink.drawTriangle(vram, draw_env, pts[0], pts[1], pts[2], color, is_transp);
    }

    fn drawFlatQuad(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        var pts = [4]Primitive.Point{ self.point(1), self.point(2), self.point(3), self.point(4) };
        self.unify(&pts);

        sink.drawTriangle(vram, draw_env, pts[0], pts[1], pts[2], color, is_transp);
        sink.drawTriangle(vram, draw_env, pts[1], pts[2], pts[3], color, is_transp);
    }

    fn drawShadedTriangle(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        var pts = [3]Primitive.Point{ self.point(1), self.point(3), self.point(5) };
        self.unify(&pts);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[2] & 0xFFFFFF;
        const c2 = self.cmd_buffer[4] & 0xFFFFFF;

        sink.drawShadedTriangle(vram, draw_env, pts[0], c0, pts[1], c1, pts[2], c2, is_transp);
    }

    fn drawShadedQuad(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        var pts = [4]Primitive.Point{ self.point(1), self.point(3), self.point(5), self.point(7) };
        self.unify(&pts);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[2] & 0xFFFFFF;
        const c2 = self.cmd_buffer[4] & 0xFFFFFF;
        const c3 = self.cmd_buffer[6] & 0xFFFFFF;

        sink.drawShadedTriangle(vram, draw_env, pts[0], c0, pts[1], c1, pts[2], c2, is_transp);
        sink.drawShadedTriangle(vram, draw_env, pts[1], c1, pts[2], c2, pts[3], c3, is_transp);
    }

    fn drawTexturedTriangleCommand(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        // One modulation colour, repeated: the interpolation in the renderer
        // is exact for three equal values, so a flat-shaded textured polygon
        // reproduces the single-colour result bit for bit.
        const color = self.cmd_buffer[0] & 0xFFFFFF;
        var vs = [3]Primitive.TexturedPoint{ self.texturedPoint(1, 2), self.texturedPoint(3, 4), self.texturedPoint(5, 6) };
        self.unifyTextured(&vs);
        const clut = Primitive.getClut(self.cmd_buffer[2]);
        const tpage = Primitive.getTpage(self.cmd_buffer[4]);
        sink.latchTexpage(vram, draw_env, tpage);

        sink.drawTexturedTriangle(vram, draw_env, vs[0], vs[1], vs[2], color, color, color, clut, tpage, is_transp, opcode);
    }

    fn drawTexturedQuadCommand(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = self.cmd_buffer[0] & 0xFFFFFF;
        const clut = Primitive.getClut(self.cmd_buffer[2]);
        const tpage = Primitive.getTpage(self.cmd_buffer[4]);
        sink.latchTexpage(vram, draw_env, tpage);
        var vs = [4]Primitive.TexturedPoint{ self.texturedPoint(1, 2), self.texturedPoint(3, 4), self.texturedPoint(5, 6), self.texturedPoint(7, 8) };
        self.unifyTextured(&vs);

        sink.drawTexturedTriangle(vram, draw_env, vs[0], vs[1], vs[2], color, color, color, clut, tpage, is_transp, opcode);
        sink.drawTexturedTriangle(vram, draw_env, vs[1], vs[2], vs[3], color, color, color, clut, tpage, is_transp, opcode);
    }

    fn drawShadedTexturedTriangle(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        // Each vertex carries its OWN modulation colour, and the texel is
        // modulated by the colour interpolated between them. Taking word 0's
        // colour for the whole primitive is what flattened Crash Warped's
        // title glow into hard shards with holes between them.
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[3] & 0xFFFFFF;
        const c2 = self.cmd_buffer[6] & 0xFFFFFF;
        const clut = Primitive.getClut(self.cmd_buffer[2]);
        const tpage = Primitive.getTpage(self.cmd_buffer[5]);
        sink.latchTexpage(vram, draw_env, tpage);
        var vs = [3]Primitive.TexturedPoint{ self.texturedPoint(1, 2), self.texturedPoint(4, 5), self.texturedPoint(7, 8) };
        self.unifyTextured(&vs);

        sink.drawTexturedTriangle(vram, draw_env, vs[0], vs[1], vs[2], c0, c1, c2, clut, tpage, is_transp, opcode);
    }

    fn drawShadedTexturedQuad(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[3] & 0xFFFFFF;
        const c2 = self.cmd_buffer[6] & 0xFFFFFF;
        const c3 = self.cmd_buffer[9] & 0xFFFFFF;
        const clut = Primitive.getClut(self.cmd_buffer[2]);
        const tpage = Primitive.getTpage(self.cmd_buffer[5]);
        sink.latchTexpage(vram, draw_env, tpage);
        var vs = [4]Primitive.TexturedPoint{ self.texturedPoint(1, 2), self.texturedPoint(4, 5), self.texturedPoint(7, 8), self.texturedPoint(10, 11) };
        self.unifyTextured(&vs);

        // The quad's halves take the colours of the vertices they are built
        // from, exactly as the untextured Gouraud quad does.
        sink.drawTexturedTriangle(vram, draw_env, vs[0], vs[1], vs[2], c0, c1, c2, clut, tpage, is_transp, opcode);
        sink.drawTexturedTriangle(vram, draw_env, vs[1], vs[2], vs[3], c1, c2, c3, clut, tpage, is_transp, opcode);
    }

    fn drawLine(self: *const Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const p0 = Primitive.getPoint(self.cmd_buffer[1]);
        const p1 = Primitive.getPoint(self.cmd_buffer[2]);

        sink.drawLine(vram, draw_env, p0.x, p0.y, p1.x, p1.y, color, is_transp);
    }

    fn drawShadedLine(self: *const Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const p0 = Primitive.getPoint(self.cmd_buffer[1]);
        const p1 = Primitive.getPoint(self.cmd_buffer[3]);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[2] & 0xFFFFFF;

        sink.drawShadedLine(vram, draw_env, p0.x, p0.y, c0, p1.x, p1.y, c1, is_transp);
    }

    fn drawRectangle(self: *const Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const p = Primitive.getPoint(self.cmd_buffer[1]);
        const size = Primitive.getSize(self.cmd_buffer[2]);

        sink.drawRectangle(vram, draw_env, p.x, p.y, size.w, size.h, color, is_transp);
    }

    fn drawTexturedRectangle(self: *const Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const p = Primitive.getPoint(self.cmd_buffer[1]);
        const tex = Primitive.getTexcoord(self.cmd_buffer[2]);
        const clut = Primitive.getClut(self.cmd_buffer[2]);
        const tpage: u16 = @truncate(draw_env.draw_mode & 0x1FF);
        const size = Primitive.getTexturedRectangleSize(opcode, self.cmd_buffer[3]);

        sink.drawTexturedRectangle(vram, draw_env, p.x, p.y, size.w, size.h, tex.u, tex.v, color, clut, tpage, is_transp, opcode);
    }

    fn drawFixedRectangle(self: *const Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8, size: i32) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const p = Primitive.getPoint(self.cmd_buffer[1]);

        sink.drawRectangle(vram, draw_env, p.x, p.y, size, size, color, is_transp);
    }

    fn startPolyline(self: *Gp0Engine, value: u32) void {
        const opcode: u8 = @intCast((value >> 24) & 0xFF);
        self.polyline_active = true;
        self.polyline_shaded = (opcode & 0x10) != 0;
        self.polyline_transparent = (opcode & 0x02) != 0;
        self.polyline_count = 0;
        self.polyline_prev_color = value & 0xFFFFFF;
    }

    fn continuePolyline(self: *Gp0Engine, value: u32, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv) void {
        if (value == 0x55555555) {
            self.polyline_active = false;
            return;
        }

        if (self.polyline_shaded) {
            if (self.polyline_count % 2 == 0) {
                // Vertex
                const x = Primitive.getX(value);
                const y = Primitive.getY(value);

                if (self.polyline_count > 0) {
                    sink.drawShadedLine(
                        vram,
                        draw_env,
                        self.polyline_prev_x,
                        self.polyline_prev_y,
                        self.polyline_prev_color,
                        x,
                        y,
                        self.polyline_next_color,
                        self.polyline_transparent,
                    );
                }

                self.polyline_prev_x = x;
                self.polyline_prev_y = y;
                self.polyline_prev_color = if (self.polyline_count == 0) self.polyline_prev_color else self.polyline_next_color;
                self.polyline_count += 1;
            } else {
                // Color
                self.polyline_next_color = value & 0xFFFFFF;
                self.polyline_count += 1;
            }
        } else {
            // Mono
            const x = Primitive.getX(value);
            const y = Primitive.getY(value);

            if (self.polyline_count > 0) {
                sink.drawLine(
                    vram,
                    draw_env,
                    self.polyline_prev_x,
                    self.polyline_prev_y,
                    x,
                    y,
                    Color.getColor16(self.polyline_prev_color),
                    self.polyline_transparent,
                );
            }

            self.polyline_prev_x = x;
            self.polyline_prev_y = y;
            self.polyline_count += 1;
        }
    }
};
