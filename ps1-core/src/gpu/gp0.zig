const std = @import("std");
const Vram = @import("vram.zig").Vram;
const Regs = @import("registers.zig");
const Sink = @import("sink.zig").Sink;
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
        const p0 = self.point(1);
        const p1 = self.point(2);
        const p2 = self.point(3);

        sink.drawTriangle(vram, draw_env, p0, p1, p2, color, is_transp);
    }

    fn drawFlatQuad(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const p0 = self.point(1);
        const p1 = self.point(2);
        const p2 = self.point(3);
        const p3 = self.point(4);

        sink.drawTriangle(vram, draw_env, p0, p1, p2, color, is_transp);
        sink.drawTriangle(vram, draw_env, p1, p2, p3, color, is_transp);
    }

    fn drawShadedTriangle(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const p0 = self.point(1);
        const p1 = self.point(3);
        const p2 = self.point(5);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[2] & 0xFFFFFF;
        const c2 = self.cmd_buffer[4] & 0xFFFFFF;

        sink.drawShadedTriangle(vram, draw_env, p0, c0, p1, c1, p2, c2, is_transp);
    }

    fn drawShadedQuad(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const p0 = self.point(1);
        const p1 = self.point(3);
        const p2 = self.point(5);
        const p3 = self.point(7);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[2] & 0xFFFFFF;
        const c2 = self.cmd_buffer[4] & 0xFFFFFF;
        const c3 = self.cmd_buffer[6] & 0xFFFFFF;

        sink.drawShadedTriangle(vram, draw_env, p0, c0, p1, c1, p2, c2, is_transp);
        sink.drawShadedTriangle(vram, draw_env, p1, c1, p2, c2, p3, c3, is_transp);
    }

    fn drawTexturedTriangleCommand(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const v0 = self.texturedPoint(1, 2);
        const v1 = self.texturedPoint(3, 4);
        const v2 = self.texturedPoint(5, 6);
        const clut = Primitive.getClut(self.cmd_buffer[2]);
        const tpage = Primitive.getTpage(self.cmd_buffer[4]);
        sink.latchTexpage(vram, draw_env, tpage);

        sink.drawTexturedTriangle(vram, draw_env, v0, v1, v2, color, clut, tpage, is_transp, opcode);
    }

    fn drawTexturedQuadCommand(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const clut = Primitive.getClut(self.cmd_buffer[2]);
        const tpage = Primitive.getTpage(self.cmd_buffer[4]);
        sink.latchTexpage(vram, draw_env, tpage);
        const v0 = self.texturedPoint(1, 2);
        const v1 = self.texturedPoint(3, 4);
        const v2 = self.texturedPoint(5, 6);
        const v3 = self.texturedPoint(7, 8);

        sink.drawTexturedTriangle(vram, draw_env, v0, v1, v2, color, clut, tpage, is_transp, opcode);
        sink.drawTexturedTriangle(vram, draw_env, v1, v2, v3, color, clut, tpage, is_transp, opcode);
    }

    fn drawShadedTexturedTriangle(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const clut = Primitive.getClut(self.cmd_buffer[2]);
        const tpage = Primitive.getTpage(self.cmd_buffer[5]);
        sink.latchTexpage(vram, draw_env, tpage);
        const v0 = self.texturedPoint(1, 2);
        const v1 = self.texturedPoint(4, 5);
        const v2 = self.texturedPoint(7, 8);

        sink.drawTexturedTriangle(vram, draw_env, v0, v1, v2, color, clut, tpage, is_transp, opcode);
    }

    fn drawShadedTexturedQuad(self: *Gp0Engine, sink: *Sink, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = Primitive.isTransparent(opcode);
        const color = Color.getColor16(self.cmd_buffer[0]);
        const clut = Primitive.getClut(self.cmd_buffer[2]);
        const tpage = Primitive.getTpage(self.cmd_buffer[5]);
        sink.latchTexpage(vram, draw_env, tpage);
        const v0 = self.texturedPoint(1, 2);
        const v1 = self.texturedPoint(4, 5);
        const v2 = self.texturedPoint(7, 8);
        const v3 = self.texturedPoint(10, 11);

        sink.drawTexturedTriangle(vram, draw_env, v0, v1, v2, color, clut, tpage, is_transp, opcode);
        sink.drawTexturedTriangle(vram, draw_env, v1, v2, v3, color, clut, tpage, is_transp, opcode);
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
