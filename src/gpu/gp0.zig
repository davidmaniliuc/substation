const std = @import("std");
const Vram = @import("vram.zig").Vram;
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
    polyline_prev_color: u16 = 0,
    polyline_next_color: u16 = 0,

    pub fn write(self: *Gp0Engine, value: u32, vram: *Vram, draw_env: *Regs.DrawingEnv, interrupt_flag: *bool) void {
        if (vram.write_active) {
            vram.writeData(value);
            return;
        }

        if (self.polyline_active) {
            self.continuePolyline(value, vram, draw_env);
            return;
        }

        if (self.words_remaining == 0) {
            const opcode: u8 = @intCast((value >> 24) & 0xFF);

            // Catch Polyline commands
            if ((opcode & 0xF8) == 0x48 or (opcode & 0xF8) == 0x58) {
                self.startPolyline(value);
                return;
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
            self.execute(vram, draw_env, interrupt_flag);
        }
    }

    fn execute(self: *Gp0Engine, vram: *Vram, draw_env: *Regs.DrawingEnv, interrupt_flag: *bool) void {
        const opcode: u8 = @intCast((self.cmd_buffer[0] >> 24) & 0xFF);

        switch (opcode) {
            0x00, 0x01 => {}, // NOP / Clear Cache
            0x1F => interrupt_flag.* = true,
            0xE1...0xE6 => draw_env.update(opcode, self.cmd_buffer[0]),

            0x02 => {
                const color16 = getColor16(self.cmd_buffer[0]);
                const x = getX(self.cmd_buffer[1]);
                const y = getY(self.cmd_buffer[1]);
                const w: i16 = @intCast(self.cmd_buffer[2] & 0xFFFF);
                const h: i16 = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);
                vram.fillRectangle(x, y, w, h, color16);
            },
            0x80 => {
                const sx: u16 = @intCast(self.cmd_buffer[1] & 0xFFFF);
                const sy: u16 = @intCast((self.cmd_buffer[1] >> 16) & 0xFFFF);
                const dx: u16 = @intCast(self.cmd_buffer[2] & 0xFFFF);
                const dy: u16 = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);
                const w: u16 = @intCast(self.cmd_buffer[3] & 0xFFFF);
                const h: u16 = @intCast((self.cmd_buffer[3] >> 16) & 0xFFFF);
                vram.copyRect(sx, sy, dx, dy, w, h);
            },
            0xA0 => {
                const x: usize = @intCast(self.cmd_buffer[1] & 0xFFFF);
                const y: usize = @intCast((self.cmd_buffer[1] >> 16) & 0xFFFF);
                const w: usize = @intCast(self.cmd_buffer[2] & 0xFFFF);
                const h: usize = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);
                vram.setupWrite(x, y, w, h);
            },
            0xC0 => {
                const x: usize = @intCast(self.cmd_buffer[1] & 0xFFFF);
                const y: usize = @intCast((self.cmd_buffer[1] >> 16) & 0xFFFF);
                const w: usize = @intCast(self.cmd_buffer[2] & 0xFFFF);
                const h: usize = @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF);
                vram.setupRead(x, y, w, h);
            },

            0x20, 0x21, 0x22, 0x23 => {
                const is_transp = (opcode & 0x02) != 0;
                const c = getColor16(self.cmd_buffer[0]);
                Renderer.drawTriangle(vram, draw_env, getX(self.cmd_buffer[1]), getY(self.cmd_buffer[1]), getX(self.cmd_buffer[2]), getY(self.cmd_buffer[2]), getX(self.cmd_buffer[3]), getY(self.cmd_buffer[3]), c, is_transp);
            },
            0x28, 0x29, 0x2A, 0x2B => {
                const is_transp = (opcode & 0x02) != 0;
                const c = getColor16(self.cmd_buffer[0]);
                const x0 = getX(self.cmd_buffer[1]);
                const y0 = getY(self.cmd_buffer[1]);
                const x1 = getX(self.cmd_buffer[2]);
                const y1 = getY(self.cmd_buffer[2]);
                const x2 = getX(self.cmd_buffer[3]);
                const y2 = getY(self.cmd_buffer[3]);
                const x3 = getX(self.cmd_buffer[4]);
                const y3 = getY(self.cmd_buffer[4]);
                Renderer.drawTriangle(vram, draw_env, x0, y0, x1, y1, x2, y2, c, is_transp);
                Renderer.drawTriangle(vram, draw_env, x1, y1, x2, y2, x3, y3, c, is_transp);
            },
            0x30, 0x31, 0x32, 0x33 => {
                Renderer.drawShadedTriangle(vram, draw_env, getX(self.cmd_buffer[1]), getY(self.cmd_buffer[1]), getColor16(self.cmd_buffer[0]), getX(self.cmd_buffer[3]), getY(self.cmd_buffer[3]), getColor16(self.cmd_buffer[2]), getX(self.cmd_buffer[5]), getY(self.cmd_buffer[5]), getColor16(self.cmd_buffer[4]), (opcode & 0x02) != 0);
            },
            0x38, 0x39, 0x3A, 0x3B => {
                const is_transp = (opcode & 0x02) != 0;
                const c0 = getColor16(self.cmd_buffer[0]);
                const x0 = getX(self.cmd_buffer[1]);
                const y0 = getY(self.cmd_buffer[1]);
                const c1 = getColor16(self.cmd_buffer[2]);
                const x1 = getX(self.cmd_buffer[3]);
                const y1 = getY(self.cmd_buffer[3]);
                const c2 = getColor16(self.cmd_buffer[4]);
                const x2 = getX(self.cmd_buffer[5]);
                const y2 = getY(self.cmd_buffer[5]);
                const c3 = getColor16(self.cmd_buffer[6]);
                const x3 = getX(self.cmd_buffer[7]);
                const y3 = getY(self.cmd_buffer[7]);
                Renderer.drawShadedTriangle(vram, draw_env, x0, y0, c0, x1, y1, c1, x2, y2, c2, is_transp);
                Renderer.drawShadedTriangle(vram, draw_env, x1, y1, c1, x2, y2, c2, x3, y3, c3, is_transp);
            },
            0x24, 0x25, 0x26, 0x27 => {
                Renderer.drawTexturedTriangle(vram, draw_env, getX(self.cmd_buffer[1]), getY(self.cmd_buffer[1]), @truncate(self.cmd_buffer[2]), @truncate(self.cmd_buffer[2] >> 8), getX(self.cmd_buffer[3]), getY(self.cmd_buffer[3]), @truncate(self.cmd_buffer[4]), @truncate(self.cmd_buffer[4] >> 8), getX(self.cmd_buffer[5]), getY(self.cmd_buffer[5]), @truncate(self.cmd_buffer[6]), @truncate(self.cmd_buffer[6] >> 8), getColor16(self.cmd_buffer[0]), @truncate(self.cmd_buffer[2] >> 16), @truncate(self.cmd_buffer[4] >> 16), (opcode & 0x02) != 0, opcode);
            },
            0x2C, 0x2D, 0x2E, 0x2F => {
                const is_transp = (opcode & 0x02) != 0;
                const c0 = getColor16(self.cmd_buffer[0]);
                const clut: u16 = @truncate(self.cmd_buffer[2] >> 16);
                const tpage: u16 = @truncate(self.cmd_buffer[4] >> 16);

                const x0 = getX(self.cmd_buffer[1]);
                const y0 = getY(self.cmd_buffer[1]);
                const tu0: u8 = @truncate(self.cmd_buffer[2]);
                const tv0: u8 = @truncate(self.cmd_buffer[2] >> 8);
                const x1 = getX(self.cmd_buffer[3]);
                const y1 = getY(self.cmd_buffer[3]);
                const tu1: u8 = @truncate(self.cmd_buffer[4]);
                const tv1: u8 = @truncate(self.cmd_buffer[4] >> 8);
                const x2 = getX(self.cmd_buffer[5]);
                const y2 = getY(self.cmd_buffer[5]);
                const tu2: u8 = @truncate(self.cmd_buffer[6]);
                const tv2: u8 = @truncate(self.cmd_buffer[6] >> 8);
                const x3 = getX(self.cmd_buffer[7]);
                const y3 = getY(self.cmd_buffer[7]);
                const tu3: u8 = @truncate(self.cmd_buffer[8]);
                const tv3: u8 = @truncate(self.cmd_buffer[8] >> 8);

                Renderer.drawTexturedTriangle(vram, draw_env, x0, y0, tu0, tv0, x1, y1, tu1, tv1, x2, y2, tu2, tv2, c0, clut, tpage, is_transp, opcode);
                Renderer.drawTexturedTriangle(vram, draw_env, x1, y1, tu1, tv1, x2, y2, tu2, tv2, x3, y3, tu3, tv3, c0, clut, tpage, is_transp, opcode);
            },
            0x34, 0x35, 0x36, 0x37 => {
                Renderer.drawTexturedTriangle(vram, draw_env, getX(self.cmd_buffer[1]), getY(self.cmd_buffer[1]), @truncate(self.cmd_buffer[2]), @truncate(self.cmd_buffer[2] >> 8), getX(self.cmd_buffer[4]), getY(self.cmd_buffer[4]), @truncate(self.cmd_buffer[5]), @truncate(self.cmd_buffer[5] >> 8), getX(self.cmd_buffer[7]), getY(self.cmd_buffer[7]), @truncate(self.cmd_buffer[8]), @truncate(self.cmd_buffer[8] >> 8), getColor16(self.cmd_buffer[0]), @truncate(self.cmd_buffer[2] >> 16), @truncate(self.cmd_buffer[5] >> 16), (opcode & 0x02) != 0, opcode);
            },
            0x3C, 0x3D, 0x3E, 0x3F => {
                const is_transp = (opcode & 0x02) != 0;
                const c0 = getColor16(self.cmd_buffer[0]);
                const clut: u16 = @truncate(self.cmd_buffer[2] >> 16);
                const tpage: u16 = @truncate(self.cmd_buffer[5] >> 16);

                const x0 = getX(self.cmd_buffer[1]);
                const y0 = getY(self.cmd_buffer[1]);
                const tu0: u8 = @truncate(self.cmd_buffer[2]);
                const tv0: u8 = @truncate(self.cmd_buffer[2] >> 8);
                const x1 = getX(self.cmd_buffer[4]);
                const y1 = getY(self.cmd_buffer[4]);
                const tu1: u8 = @truncate(self.cmd_buffer[5]);
                const tv1: u8 = @truncate(self.cmd_buffer[5] >> 8);
                const x2 = getX(self.cmd_buffer[7]);
                const y2 = getY(self.cmd_buffer[7]);
                const tu2: u8 = @truncate(self.cmd_buffer[8]);
                const tv2: u8 = @truncate(self.cmd_buffer[8] >> 8);
                const x3 = getX(self.cmd_buffer[10]);
                const y3 = getY(self.cmd_buffer[10]);
                const tu3: u8 = @truncate(self.cmd_buffer[11]);
                const tv3: u8 = @truncate(self.cmd_buffer[11] >> 8);

                Renderer.drawTexturedTriangle(vram, draw_env, x0, y0, tu0, tv0, x1, y1, tu1, tv1, x2, y2, tu2, tv2, c0, clut, tpage, is_transp, opcode);
                Renderer.drawTexturedTriangle(vram, draw_env, x1, y1, tu1, tv1, x2, y2, tu2, tv2, x3, y3, tu3, tv3, c0, clut, tpage, is_transp, opcode);
            },
            0x40...0x47 => {
                Renderer.drawLine(vram, draw_env, getX(self.cmd_buffer[1]), getY(self.cmd_buffer[1]), getX(self.cmd_buffer[2]), getY(self.cmd_buffer[2]), getColor16(self.cmd_buffer[0]), (opcode & 0x02) != 0);
            },
            0x50...0x57 => {
                Renderer.drawShadedLine(vram, draw_env, getX(self.cmd_buffer[1]), getY(self.cmd_buffer[1]), getColor16(self.cmd_buffer[0]), getX(self.cmd_buffer[3]), getY(self.cmd_buffer[3]), getColor16(self.cmd_buffer[2]), (opcode & 0x02) != 0);
            },
            0x60, 0x61, 0x62, 0x63 => {
                Renderer.drawRectangle(vram, draw_env, getX(self.cmd_buffer[1]), getY(self.cmd_buffer[1]), @intCast(self.cmd_buffer[2] & 0xFFFF), @intCast((self.cmd_buffer[2] >> 16) & 0xFFFF), getColor16(self.cmd_buffer[0]), (opcode & 0x02) != 0);
            },
            0x70, 0x71, 0x72, 0x73 => {
                Renderer.drawRectangle(vram, draw_env, getX(self.cmd_buffer[1]), getY(self.cmd_buffer[1]), 8, 8, getColor16(self.cmd_buffer[0]), (opcode & 0x02) != 0);
            },
            0x78, 0x79, 0x7A, 0x7B => {
                Renderer.drawRectangle(vram, draw_env, getX(self.cmd_buffer[1]), getY(self.cmd_buffer[1]), 16, 16, getColor16(self.cmd_buffer[0]), (opcode & 0x02) != 0);
            },
            else => {},
        }

        self.words_remaining = 0;
        self.words_read = 0;
    }

    fn startPolyline(self: *Gp0Engine, value: u32) void {
        const opcode: u8 = @intCast((value >> 24) & 0xFF);
        self.polyline_active = true;
        self.polyline_shaded = (opcode & 0x10) != 0;
        self.polyline_transparent = (opcode & 0x02) != 0;
        self.polyline_count = 0;
        self.polyline_prev_color = getColor16(value);
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
                    Renderer.drawShadedLine(vram, draw_env, self.polyline_prev_x, self.polyline_prev_y, self.polyline_prev_color, x, y, self.polyline_next_color, self.polyline_transparent);
                }

                self.polyline_prev_x = x;
                self.polyline_prev_y = y;
                self.polyline_prev_color = if (self.polyline_count == 0) self.polyline_prev_color else self.polyline_next_color;
                self.polyline_count += 1;
            } else {
                // Color
                self.polyline_next_color = getColor16(value);
                self.polyline_count += 1;
            }
        } else {
            // Mono
            const x = getX(value);
            const y = getY(value);

            if (self.polyline_count > 0) {
                Renderer.drawLine(vram, draw_env, self.polyline_prev_x, self.polyline_prev_y, x, y, self.polyline_prev_color, self.polyline_transparent);
            }

            self.polyline_prev_x = x;
            self.polyline_prev_y = y;
            self.polyline_count += 1;
        }
    }
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

inline fn getColor16(value: u32) u16 {
    const r = (value & 0xFF) >> 3;
    const g = ((value >> 8) & 0xFF) >> 3;
    const b = ((value >> 16) & 0xFF) >> 3;
    return @as(u16, @intCast((b << 10) | (g << 5) | r));
}

inline fn getX(val: u32) i16 {
    const temp = @as(i16, @bitCast(@as(u16, @truncate(val))));
    return @as(i16, @truncate((@as(i32, temp) << 21) >> 21));
}

inline fn getY(val: u32) i16 {
    const temp = @as(i16, @bitCast(@as(u16, @truncate(val >> 16))));
    return @as(i16, @truncate((@as(i32, temp) << 21) >> 21));
}
