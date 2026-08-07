const std = @import("std");
const Vram = @import("vram.zig").Vram;
const VramMask = @import("vram.zig").Mask;
const Regs = @import("registers.zig");
const Renderer = @import("renderer.zig").Renderer;

pub const Gp0Engine = struct {
    cmd_buffer: [16]u32 = [_]u32{0} ** 16,
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

    pub fn write(self: *Gp0Engine, value: u32, vram: *Vram, draw_env: *Regs.DrawingEnv, interrupt_flag: *bool) u32 {
        if (vram.write_active) {
            vram.writeData(value, VramMask.fromE6(draw_env.mask_bit));
            return 1;
        }

        if (self.polyline_active) {
            self.continuePolyline(value, vram, draw_env);
            return 50; // Approximated cost per segment
        }

        if (self.words_remaining == 0) {
            const opcode: u8 = @intCast((value >> 24) & 0xFF);

            // Catch Polyline commands
            if ((opcode & 0xF8) == 0x48 or (opcode & 0xF8) == 0x58) {
                self.startPolyline(value);
                return 10;
            }

            const length = getCommandLength(opcode);
            self.cmd_buffer[0] = value;
            self.words_read = 1;
            self.words_remaining = if (length > 0) length - 1 else 0;
        } else {
            if (self.words_read < self.cmd_buffer.len) {
                self.cmd_buffer[self.words_read] = value;
            }
            self.words_read += 1;
            if (self.words_remaining > 0) self.words_remaining -= 1;
        }

        if (self.words_remaining == 0) {
            return self.execute(vram, draw_env, interrupt_flag);
        }
        return 0; // Just collecting command arguments
    }

    fn execute(self: *Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, interrupt_flag: *bool) u32 {
        const opcode: u8 = @intCast((self.cmd_buffer[0] >> 24) & 0xFF);
        var cost: u32 = 10; // Base cost

        switch (opcode) {
            0x00, 0x01 => {}, // NOP / Clear Cache
            0x1F => interrupt_flag.* = true,
            0xE1...0xE6 => draw_env.update(opcode, self.cmd_buffer[0]),

            0x02 => {
                self.fillRectangle(vram);
                cost = 200;
            },
            0x80 => {
                self.copyRectangle(vram, draw_env);
                cost = 200;
            },
            0xA0 => {
                self.setupVramWrite(vram);
                cost = 20;
            },
            0xC0 => {
                self.setupVramRead(vram);
                cost = 20;
            },

            0x20...0x23 => {
                self.drawFlatTriangle(vram, draw_env, opcode);
                cost = 100;
            },
            0x28...0x2B => {
                self.drawFlatQuad(vram, draw_env, opcode);
                cost = 200;
            },
            0x30...0x33 => {
                self.drawShadedTriangle(vram, draw_env, opcode);
                cost = 150;
            },
            0x38...0x3B => {
                self.drawShadedQuad(vram, draw_env, opcode);
                cost = 300;
            },
            0x24...0x27 => {
                self.drawTexturedTriangleCommand(vram, draw_env, opcode);
                cost = 150;
            },
            0x2C...0x2F => {
                self.drawTexturedQuadCommand(vram, draw_env, opcode);
                cost = 300;
            },
            0x34...0x37 => {
                self.drawShadedTexturedTriangle(vram, draw_env, opcode);
                cost = 200;
            },
            0x3C...0x3F => {
                self.drawShadedTexturedQuad(vram, draw_env, opcode);
                cost = 400;
            },
            0x40...0x47 => {
                self.drawLine(vram, draw_env, opcode);
                cost = 50;
            },
            0x50...0x57 => {
                self.drawShadedLine(vram, draw_env, opcode);
                cost = 75;
            },
            0x60...0x63 => {
                self.drawRectangle(vram, draw_env, opcode);
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
                self.drawTexturedRectangle(vram, draw_env, opcode);
                cost = 150;
            },
            0x70...0x73 => {
                self.drawFixedRectangle(vram, draw_env, opcode, 8);
                cost = 50;
            },
            0x78...0x7B => {
                self.drawFixedRectangle(vram, draw_env, opcode, 16);
                cost = 100;
            },
            else => {},
        }

        self.words_remaining = 0;
        self.words_read = 0;
        return cost;
    }

    fn fillRectangle(self: *const Gp0Engine, vram: *Vram) void {
        const color16 = getColor16(self.cmd_buffer[0]);
        const x = getX(self.cmd_buffer[1]);
        const y = getY(self.cmd_buffer[1]);
        const w: i16 = @intCast(self.cmd_buffer[2] & 0xFFFF);
        const h: i16 = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);

        vram.fillRectangle(x, y, w, h, color16);
    }

    fn copyRectangle(self: *const Gp0Engine, vram: *Vram, draw_env: *const Regs.DrawingEnv) void {
        const sx: u16 = @intCast(self.cmd_buffer[1] & 0xFFFF);
        const sy: u16 = @intCast((self.cmd_buffer[1] >> 16) & 0xFFFF);
        const dx: u16 = @intCast(self.cmd_buffer[2] & 0xFFFF);
        const dy: u16 = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);
        const w: u16 = @intCast(self.cmd_buffer[3] & 0xFFFF);
        const h: u16 = @intCast((self.cmd_buffer[3] >> 16) & 0xFFFF);

        vram.copyRect(sx, sy, dx, dy, w, h, VramMask.fromE6(draw_env.mask_bit));
    }

    fn setupVramWrite(self: *const Gp0Engine, vram: *Vram) void {
        const x: usize = @intCast(self.cmd_buffer[1] & 0xFFFF);
        const y: usize = @intCast((self.cmd_buffer[1] >> 16) & 0xFFFF);
        const w: usize = @intCast(self.cmd_buffer[2] & 0xFFFF);
        const h: usize = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);

        vram.setupWrite(x, y, w, h);
    }

    fn setupVramRead(self: *const Gp0Engine, vram: *Vram) void {
        const x: usize = @intCast(self.cmd_buffer[1] & 0xFFFF);
        const y: usize = @intCast((self.cmd_buffer[1] >> 16) & 0xFFFF);
        const w: usize = @intCast(self.cmd_buffer[2] & 0xFFFF);
        const h: usize = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);

        vram.setupRead(x, y, w, h);
    }

    fn drawFlatTriangle(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const p0 = getPoint(self.cmd_buffer[1]);
        const p1 = getPoint(self.cmd_buffer[2]);
        const p2 = getPoint(self.cmd_buffer[3]);

        Renderer.drawTriangle(vram, draw_env, p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, color, is_transp);
    }

    fn drawFlatQuad(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const p0 = getPoint(self.cmd_buffer[1]);
        const p1 = getPoint(self.cmd_buffer[2]);
        const p2 = getPoint(self.cmd_buffer[3]);
        const p3 = getPoint(self.cmd_buffer[4]);

        Renderer.drawTriangle(vram, draw_env, p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, color, is_transp);
        Renderer.drawTriangle(vram, draw_env, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, color, is_transp);
    }

    fn drawShadedTriangle(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const p0 = getPoint(self.cmd_buffer[1]);
        const p1 = getPoint(self.cmd_buffer[3]);
        const p2 = getPoint(self.cmd_buffer[5]);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[2] & 0xFFFFFF;
        const c2 = self.cmd_buffer[4] & 0xFFFFFF;

        Renderer.drawShadedTriangle(vram, draw_env, p0.x, p0.y, c0, p1.x, p1.y, c1, p2.x, p2.y, c2, is_transp);
    }

    fn drawShadedQuad(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const p0 = getPoint(self.cmd_buffer[1]);
        const p1 = getPoint(self.cmd_buffer[3]);
        const p2 = getPoint(self.cmd_buffer[5]);
        const p3 = getPoint(self.cmd_buffer[7]);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[2] & 0xFFFFFF;
        const c2 = self.cmd_buffer[4] & 0xFFFFFF;
        const c3 = self.cmd_buffer[6] & 0xFFFFFF;

        Renderer.drawShadedTriangle(vram, draw_env, p0.x, p0.y, c0, p1.x, p1.y, c1, p2.x, p2.y, c2, is_transp);
        Renderer.drawShadedTriangle(vram, draw_env, p1.x, p1.y, c1, p2.x, p2.y, c2, p3.x, p3.y, c3, is_transp);
    }

    fn drawTexturedTriangleCommand(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const v0 = getTexturedPoint(self.cmd_buffer[1], self.cmd_buffer[2]);
        const v1 = getTexturedPoint(self.cmd_buffer[3], self.cmd_buffer[4]);
        const v2 = getTexturedPoint(self.cmd_buffer[5], self.cmd_buffer[6]);
        const clut = getClut(self.cmd_buffer[2]);
        const tpage = getTpage(self.cmd_buffer[4]);

        drawTexturedTriangle(vram, draw_env, v0, v1, v2, color, clut, tpage, is_transp, opcode);
    }

    fn drawTexturedQuadCommand(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const clut = getClut(self.cmd_buffer[2]);
        const tpage = getTpage(self.cmd_buffer[4]);
        const v0 = getTexturedPoint(self.cmd_buffer[1], self.cmd_buffer[2]);
        const v1 = getTexturedPoint(self.cmd_buffer[3], self.cmd_buffer[4]);
        const v2 = getTexturedPoint(self.cmd_buffer[5], self.cmd_buffer[6]);
        const v3 = getTexturedPoint(self.cmd_buffer[7], self.cmd_buffer[8]);

        drawTexturedTriangle(vram, draw_env, v0, v1, v2, color, clut, tpage, is_transp, opcode);
        drawTexturedTriangle(vram, draw_env, v1, v2, v3, color, clut, tpage, is_transp, opcode);
    }

    fn drawShadedTexturedTriangle(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const clut = getClut(self.cmd_buffer[2]);
        const tpage = getTpage(self.cmd_buffer[5]);
        const v0 = getTexturedPoint(self.cmd_buffer[1], self.cmd_buffer[2]);
        const v1 = getTexturedPoint(self.cmd_buffer[4], self.cmd_buffer[5]);
        const v2 = getTexturedPoint(self.cmd_buffer[7], self.cmd_buffer[8]);

        drawTexturedTriangle(vram, draw_env, v0, v1, v2, color, clut, tpage, is_transp, opcode);
    }

    fn drawShadedTexturedQuad(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const clut = getClut(self.cmd_buffer[2]);
        const tpage = getTpage(self.cmd_buffer[5]);
        const v0 = getTexturedPoint(self.cmd_buffer[1], self.cmd_buffer[2]);
        const v1 = getTexturedPoint(self.cmd_buffer[4], self.cmd_buffer[5]);
        const v2 = getTexturedPoint(self.cmd_buffer[7], self.cmd_buffer[8]);
        const v3 = getTexturedPoint(self.cmd_buffer[10], self.cmd_buffer[11]);

        drawTexturedTriangle(vram, draw_env, v0, v1, v2, color, clut, tpage, is_transp, opcode);
        drawTexturedTriangle(vram, draw_env, v1, v2, v3, color, clut, tpage, is_transp, opcode);
    }

    fn drawLine(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const p0 = getPoint(self.cmd_buffer[1]);
        const p1 = getPoint(self.cmd_buffer[2]);

        Renderer.drawLine(vram, draw_env, p0.x, p0.y, p1.x, p1.y, color, is_transp);
    }

    fn drawShadedLine(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const p0 = getPoint(self.cmd_buffer[1]);
        const p1 = getPoint(self.cmd_buffer[3]);
        const c0 = self.cmd_buffer[0] & 0xFFFFFF;
        const c1 = self.cmd_buffer[2] & 0xFFFFFF;

        Renderer.drawShadedLine(vram, draw_env, p0.x, p0.y, c0, p1.x, p1.y, c1, is_transp);
    }

    fn drawRectangle(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const p = getPoint(self.cmd_buffer[1]);
        const size = getSize(self.cmd_buffer[2]);

        Renderer.drawRectangle(vram, draw_env, p.x, p.y, size.w, size.h, color, is_transp);
    }

    fn drawTexturedRectangle(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const p = getPoint(self.cmd_buffer[1]);
        const tex = getTexcoord(self.cmd_buffer[2]);
        const clut = getClut(self.cmd_buffer[2]);
        const tpage: u16 = @truncate(draw_env.draw_mode & 0x1FF);
        const size = getTexturedRectangleSize(opcode, self.cmd_buffer[3]);

        Renderer.drawTexturedRectangle(vram, draw_env, p.x, p.y, size.w, size.h, tex.u, tex.v, color, clut, tpage, is_transp, opcode);
    }

    fn drawFixedRectangle(self: *const Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, opcode: u8, size: i32) void {
        const is_transp = isTransparent(opcode);
        const color = getColor16(self.cmd_buffer[0]);
        const p = getPoint(self.cmd_buffer[1]);

        Renderer.drawRectangle(vram, draw_env, p.x, p.y, size, size, color, is_transp);
    }

    fn startPolyline(self: *Gp0Engine, value: u32) void {
        const opcode: u8 = @intCast((value >> 24) & 0xFF);
        self.polyline_active = true;
        self.polyline_shaded = (opcode & 0x10) != 0;
        self.polyline_transparent = (opcode & 0x02) != 0;
        self.polyline_count = 0;
        self.polyline_prev_color = value & 0xFFFFFF;
    }

    fn continuePolyline(self: *Gp0Engine, value: u32, vram: *Vram, draw_env: *Regs.DrawingEnv) void {
        if (value == 0x55555555) {
            self.polyline_active = false;
            return;
        }

        if (self.polyline_shaded) {
            if (self.polyline_count % 2 == 0) {
                // Vertex
                const x = getX(value);
                const y = getY(value);

                if (self.polyline_count > 0) {
                    Renderer.drawShadedLine(
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
            const x = getX(value);
            const y = getY(value);

            if (self.polyline_count > 0) {
                Renderer.drawLine(
                    vram,
                    draw_env,
                    self.polyline_prev_x,
                    self.polyline_prev_y,
                    x,
                    y,
                    getColor16(self.polyline_prev_color),
                    self.polyline_transparent,
                );
            }

            self.polyline_prev_x = x;
            self.polyline_prev_y = y;
            self.polyline_count += 1;
        }
    }
};

const Point = struct {
    x: i16,
    y: i16,
};

const Size = struct {
    w: i32,
    h: i32,
};

const Texcoord = struct {
    u: u8,
    v: u8,
};

const TexturedPoint = struct {
    point: Point,
    texcoord: Texcoord,
};

inline fn getCommandLength(opcode: u8) usize {
    return switch (opcode) {
        0x00, 0x01, 0x1F => 1,
        0x02 => 3,
        0x20...0x23 => 4,
        0x24...0x27 => 7,
        0x30...0x33 => 6,
        0x34...0x37 => 9,
        0x28...0x2B => 5,
        0x2C...0x2F => 9,
        0x38...0x3B => 8,
        0x3C...0x3F => 12,
        0x40...0x47 => 3,
        0x50...0x57 => 4,
        0x60...0x63 => 3,
        0x64...0x67 => 4,
        0x70...0x73 => 2,
        0x74...0x77 => 3,
        0x78...0x7B => 2,
        0x7C...0x7F => 3,
        0x80 => 4,
        0xA0, 0xC0 => 3,
        0xE1...0xE6 => 1,
        else => 1,
    };
}

inline fn getPoint(value: u32) Point {
    return .{
        .x = getX(value),
        .y = getY(value),
    };
}

inline fn getSize(value: u32) Size {
    return .{
        .w = @intCast(value & 0xFFFF),
        .h = @intCast((value >> 16) & 0xFFFF),
    };
}

inline fn getTexcoord(value: u32) Texcoord {
    return .{
        .u = @truncate(value),
        .v = @truncate(value >> 8),
    };
}

inline fn getTexturedPoint(point_word: u32, texcoord_word: u32) TexturedPoint {
    return .{
        .point = getPoint(point_word),
        .texcoord = getTexcoord(texcoord_word),
    };
}

inline fn getClut(value: u32) u16 {
    return @truncate(value >> 16);
}

inline fn getTpage(value: u32) u16 {
    return @truncate(value >> 16);
}

inline fn isTransparent(opcode: u8) bool {
    return (opcode & 0x02) != 0;
}

inline fn getTexturedRectangleSize(opcode: u8, size_word: u32) Size {
    return switch (opcode & 0x18) {
        0x00 => getSize(size_word),
        0x10 => .{ .w = 8, .h = 8 },
        0x18 => .{ .w = 16, .h = 16 },
        else => unreachable,
    };
}

fn drawTexturedTriangle(
    vram: *Vram,
    draw_env: *const Regs.DrawingEnv,
    v0: TexturedPoint,
    v1: TexturedPoint,
    v2: TexturedPoint,
    color: u16,
    clut: u16,
    tpage: u16,
    is_transp: bool,
    opcode: u8,
) void {
    Renderer.drawTexturedTriangle(
        vram,
        draw_env,
        v0.point.x,
        v0.point.y,
        v0.texcoord.u,
        v0.texcoord.v,
        v1.point.x,
        v1.point.y,
        v1.texcoord.u,
        v1.texcoord.v,
        v2.point.x,
        v2.point.y,
        v2.texcoord.u,
        v2.texcoord.v,
        color,
        clut,
        tpage,
        is_transp,
        opcode,
    );
}

inline fn getColor16(value: u32) u16 {
    const r = (value & 0xFF) >> 3;
    const g = ((value >> 8) & 0xFF) >> 3;
    const b = ((value >> 16) & 0xFF) >> 3;
    return @as(u16, @intCast((b << 10) | (g << 5) | r));
}

inline fn getX(val: u32) i16 {
    const bits = val & 0x7FF;
    const sign_extended = if ((bits & 0x400) != 0) bits | 0xF800 else bits;
    return @as(i16, @bitCast(@as(u16, @truncate(sign_extended))));
}

inline fn getY(val: u32) i16 {
    const bits = (val >> 16) & 0x7FF;
    const sign_extended = if ((bits & 0x400) != 0) bits | 0xF800 else bits;
    return @as(i16, @bitCast(@as(u16, @truncate(sign_extended))));
}
