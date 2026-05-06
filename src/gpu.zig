const std = @import("std");

pub const Gpu = struct {
    const Self = @This();

    // GP0: Data / Command
    // GP1: Control / Status

    // 1024 pixels wide * 512 pixels high.
    // PS1 uses 16-bit colors: 1 bit for transparency, 5 bits each for R, G, B.
    vram: [1024 * 512]u16 = [_]u16{0} ** (1024 * 512),

    // --- GP0 State ---
    gp0_cmd_buffer: [16]u32 = [_]u32{0} ** 16,
    gp0_words_remaining: usize = 0,
    gp0_words_read: usize = 0,

    vram_transfer_active: bool = false,
    vram_transfer_x: usize = 0,
    vram_transfer_y: usize = 0,
    vram_transfer_w: usize = 0,
    vram_transfer_h: usize = 0,
    vram_transfer_curr_x: usize = 0,
    vram_transfer_curr_y: usize = 0,
    vram_transfer_remaining: usize = 0,

    // --- VRAM to CPU state ---
    vram_read_active: bool = false,
    vram_read_x: usize = 0,
    vram_read_y: usize = 0,
    vram_read_w: usize = 0,
    vram_read_h: usize = 0,
    vram_read_curr_x: usize = 0,
    vram_read_curr_y: usize = 0,
    vram_read_remaining: usize = 0,

    env_regs: [6]u32 = [_]u32{0} ** 6,

    // --- Polyline State ---
    polyline_active: bool = false,
    polyline_shaded: bool = false,
    polyline_count: usize = 0,
    polyline_transparent: bool = false,
    polyline_prev_x: i16 = 0,
    polyline_prev_y: i16 = 0,
    polyline_prev_color: u16 = 0,
    polyline_next_color: u16 = 0,

    // --- GP1 State ---
    display_vram_x_start: u16 = 0,
    display_vram_y_start: u16 = 0,
    display_screen_x1: u16 = 0x200,
    display_screen_x2: u16 = 0xC00,
    display_screen_y1: u16 = 0x010,
    display_screen_y2: u16 = 0x100,

    display_disabled: bool = true, // GP1 0x03 (1 = Disabled, 0 = Enabled)
    dma_direction: u2 = 0, // GP1 0x04
    display_mode: u32 = 0, // GP1 0x08 (Resolutions, NTSC/PAL, etc)
    interrupt_flag: bool = false, // GP1 0x02

    // Hardware cycle tracking
    is_vblank: bool = false,

    pub fn init() Self {
        return .{};
    }

    // Provide a way for frontends to grab the framebuffer!
    pub fn getVramPtr(self: *Self) [*]const u16 {
        return @ptrCast(&self.vram);
    }

    pub fn readStatus(self: *const Self) u32 {
        var stat: u32 = 0;

        // Bits 0-10 are mirrored directly from the GP0 E1 register (Draw Mode)
        // Bits 11-12 are mirrored directly from the GP0 E6 register (Mask Bit)
        // Bit 15 is the Texture Disable bit from GP0 E1
        const draw_mode = self.env_regs[0];
        const mask_mode = self.env_regs[5];

        stat |= (draw_mode & 0x7FF); // Bits 0-10
        stat |= (mask_mode & 0x3) << 11; // Bits 11-12
        stat |= ((draw_mode >> 11) & 1) << 15; // Bit 15

        // Bits 16-22 are from GP1 0x08 (Display Mode)
        // GP1 stores this in the lower 24 bits, but the relevant ones map perfectly here
        stat |= (self.display_mode & 0x7F) << 16;

        // Bit 23: Display Enable
        if (self.display_disabled) stat |= (1 << 23);

        // Bit 24: Interrupt Flag
        if (self.interrupt_flag) stat |= (1 << 24);

        // Bits 26-28: Hardware Ready flags.
        // We set these to 1 (Ready) unless we are actively locking the bus with a VRAM transfer
        if (!self.vram_transfer_active) {
            stat |= (1 << 26); // Ready to receive GP0 Cmd
            stat |= (1 << 27); // Ready to send VRAM to CPU
            stat |= (1 << 28); // Ready to receive DMA block
        }

        // Bits 29-30: DMA Direction
        stat |= (@as(u32, self.dma_direction) << 29);

        // Bit 31: VBlank (Vertical Retrace)
        if (self.is_vblank) stat |= (1 << 31);

        return stat;
    }

    pub fn readData(self: *Self) u32 {
        if (!self.vram_read_active) return 0;

        const Closure = struct {
            inline fn read_pixel(s: *Self) u16 {
                const px = s.vram_read_x + s.vram_read_curr_x;
                const py = s.vram_read_y + s.vram_read_curr_y;
                var pix: u16 = 0;

                if (px < 1024 and py < 512) {
                    pix = s.vram[py * 1024 + px];
                }

                s.vram_read_curr_x += 1;
                if (s.vram_read_curr_x >= s.vram_read_w) {
                    s.vram_read_curr_x = 0;
                    s.vram_read_curr_y += 1;
                }
                return pix;
            }
        };

        const low = Closure.read_pixel(self);
        var high: u16 = 0;

        // Only read the high pixel if we haven't reached the end of the requested bounds
        if ((self.vram_read_curr_y * self.vram_read_w + self.vram_read_curr_x) < (self.vram_read_w * self.vram_read_h)) {
            high = Closure.read_pixel(self);
        }

        if (self.vram_read_remaining > 0) self.vram_read_remaining -= 1;
        if (self.vram_read_remaining == 0) self.vram_read_active = false;

        return @as(u32, low) | (@as(u32, high) << 16);
    }

    // Start/continue GP0 command buffering and execute when complete
    pub fn writeGp0(self: *Self, value: u32) void {
        // If a VRAM transfer is active, stream data directly into VRAM
        if (self.vram_transfer_active) {
            self.writeVramData(value);
            return;
        }

        if (self.polyline_active) {
            self.continuePolyline(value);
            return;
        }

        if (self.gp0_words_remaining == 0) {
            // Start of a new command
            const opcode: u8 = @intCast((value >> 24) & 0xFF);

            // Check for polyline opcodes: 0x48-0x4F, 0x58-0x5F
            if ((opcode & 0xF8) == 0x48 or (opcode & 0xF8) == 0x58) {
                self.startPolyline(value);
                return;
            }

            const length = self.getCommandLength(opcode);

            self.gp0_cmd_buffer[0] = value;
            self.gp0_words_read = 1;
            self.gp0_words_remaining = if (length > 0) length - 1 else 0;
        } else {
            // Continue buffering
            if (self.gp0_words_read < self.gp0_cmd_buffer.len) {
                self.gp0_cmd_buffer[self.gp0_words_read] = value;
            }
            self.gp0_words_read += 1;
            if (self.gp0_words_remaining > 0) self.gp0_words_remaining -= 1;
        }

        // Execute if we have all the words
        if (self.gp0_words_remaining == 0) {
            self.executeGp0Command();
        }
    }

    fn getCommandLength(self: *Self, opcode: u8) usize {
        _ = self;
        return switch (opcode) {
            0x00 => 1, // NOP
            0x01 => 1, // Clear Cache
            0x02 => 3, // Fill Rectangle
            0x1F => 1, // Interrupt Request

            // Triangles (3-point polygons)
            0x20, 0x21, 0x22, 0x23 => 4, // Mono Triangle
            0x24, 0x25, 0x26, 0x27 => 7, // Textured Triangle
            0x30, 0x31, 0x32, 0x33 => 6, // Shaded Triangle
            0x34, 0x35, 0x36, 0x37 => 9, // Shaded Textured Triangle

            // Quadrilaterals (4-point polygons)
            0x28, 0x29, 0x2A, 0x2B => 5, // Mono Quad
            0x2C, 0x2D, 0x2E, 0x2F => 9, // Textured Quad
            0x38, 0x39, 0x3A, 0x3B => 8, // Shaded Quad
            0x3C, 0x3D, 0x3E, 0x3F => 12, // Shaded Textured Quad

            // Lines
            0x40...0x47 => 3, // Mono Line
            0x50...0x57 => 4, // Shaded Line

            // Rectangles (Variable size)
            0x60, 0x61, 0x62, 0x63 => 3, // Mono Rectangle
            0x64, 0x65, 0x66, 0x67 => 4, // Textured Rectangle
            0x70, 0x71, 0x72, 0x73 => 2, // Mono Rectangle (8x8)
            0x74, 0x75, 0x76, 0x77 => 3, // Textured Rectangle (8x8)
            0x78, 0x79, 0x7A, 0x7B => 2, // Mono Rectangle (16x16)
            0x7C, 0x7D, 0x7E, 0x7F => 3, // Textured Rectangle (16x16)

            0x80 => 4, // VRAM -> VRAM copy (4 words)
            0xA0 => 3, // CPU -> VRAM (header only)
            0xC0 => 3, // VRAM -> CPU (header only)
            0xE1...0xE6 => 1, // Environment settings
            else => 1, // Default: treat as single-word command
        };
    }

    pub fn getColor16(self: *const Self, value: u32) u16 {
        _ = self;
        const r = (value & 0xFF) >> 3;
        const g = ((value >> 8) & 0xFF) >> 3;
        const b = ((value >> 16) & 0xFF) >> 3;
        return @as(u16, @intCast((b << 10) | (g << 5) | r));
    }

    inline fn getX(val: u32) i16 {
        // Cast to i16 by truncating and bitcasting (safe wrap)
        const temp = @as(i16, @bitCast(@as(u16, @truncate(val))));
        // Shift left and right by 5 to sign-extend the 11-bit coordinate
        return @as(i16, @truncate((@as(i32, temp) << 21) >> 21));
    }

    inline fn getY(val: u32) i16 {
        const temp = @as(i16, @bitCast(@as(u16, @truncate(val >> 16))));
        return @as(i16, @truncate((@as(i32, temp) << 21) >> 21));
    }

    fn putPixel(self: *Self, x: i16, y: i16, color: u16, is_transparent: bool) void {
        // 1. Hardware Clipping
        const draw_x0 = @as(i16, @intCast(self.env_regs[2] & 0x3FF));
        const draw_y0 = @as(i16, @intCast((self.env_regs[2] >> 10) & 0x3FF));
        const draw_x1 = @as(i16, @intCast(self.env_regs[3] & 0x3FF));
        const draw_y1 = @as(i16, @intCast((self.env_regs[3] >> 10) & 0x3FF));

        if (x < draw_x0 or x > draw_x1 or y < draw_y0 or y > draw_y1) return;
        if (x < 0 or x >= 1024 or y < 0 or y >= 512) return;

        const idx = @as(usize, @intCast(y)) * 1024 + @as(usize, @intCast(x));

        // 2. Mask Bit Evaluation (env_regs[5] is GP0 0xE6)
        const mask_ctrl = self.env_regs[5];
        const set_mask = (mask_ctrl & 1) != 0;
        const check_mask = (mask_ctrl & 2) != 0;

        const bg_pixel = self.vram[idx];

        // If "Check Mask" is on, we don't draw over pixels that have bit 15 set
        if (check_mask and (bg_pixel & 0x8000) != 0) return;

        var final_color = color;

        // 3. Semi-Transparency Blending
        if (is_transparent) {
            // Blending modes are stored in bits 5-6 of Draw Mode (env_regs[0] / GP0 0xE1)
            const blend_mode = (self.env_regs[0] >> 5) & 3;

            const fr = color & 0x1F;
            const fg = (color >> 5) & 0x1F;
            const fb = (color >> 10) & 0x1F;

            const br = bg_pixel & 0x1F;
            const bg = (bg_pixel >> 5) & 0x1F;
            const bb = (bg_pixel >> 10) & 0x1F;

            var rr: u16 = 0;
            var gg: u16 = 0;
            var bb_out: u16 = 0;

            switch (blend_mode) {
                0 => { // 0.5 * Back + 0.5 * Front
                    rr = (br + fr) / 2;
                    gg = (bg + fg) / 2;
                    bb_out = (bb + fb) / 2;
                },
                1 => { // 1.0 * Back + 1.0 * Front
                    rr = br + fr;
                    gg = bg + fg;
                    bb_out = bb + fb;
                },
                2 => { // 1.0 * Back - 1.0 * Front
                    rr = if (br > fr) br - fr else 0;
                    gg = if (bg > fg) bg - fg else 0;
                    bb_out = if (bb > fb) bb - fb else 0;
                },
                3 => { // 1.0 * Back + 0.25 * Front
                    rr = br + (fr / 4);
                    gg = bg + (fg / 4);
                    bb_out = bb + (fb / 4);
                },
                else => unreachable,
            }

            // Saturate to 5-bit max
            rr = @min(rr, 31);
            gg = @min(gg, 31);
            bb_out = @min(bb_out, 31);

            final_color = rr | (gg << 5) | (bb_out << 10);
        }

        // Apply Force Mask bit if needed, otherwise strip it
        if (set_mask) {
            final_color |= 0x8000;
        } else {
            final_color &= 0x7FFF;
        }

        self.vram[idx] = final_color;
    }

    fn drawRectangle(self: *Self, x: i16, y: i16, w: i16, h: i16, color: u16, is_transparent: bool) void {
        const offset_x = @as(i16, @intCast(self.env_regs[4] & 0x7FF));
        const offset_y = @as(i16, @intCast((self.env_regs[4] >> 11) & 0x7FF));

        // Sign-extend 11-bit values to 16-bit
        const ox = if (offset_x >= 0x400) offset_x - 0x800 else offset_x;
        const oy = if (offset_y >= 0x400) offset_y - 0x800 else offset_y;

        var yy: i16 = 0;
        while (yy < h) : (yy += 1) {
            var xx: i16 = 0;
            while (xx < w) : (xx += 1) {
                const px = x + xx + ox;
                const py = y + yy + oy;

                self.putPixel(px, py, color, is_transparent);
            }
        }
    }

    fn executeGp0Command(self: *Self) void {
        const opcode: u8 = @intCast((self.gp0_cmd_buffer[0] >> 24) & 0xFF);

        switch (opcode) {
            0x00 => {
                // NOP: do nothing
            },

            0x01 => {
                // Clear Cache: usually a no-op in high-level emulators
            },

            0x1F => {
                // Interrupt Request
                self.interrupt_flag = true;
            },

            // Environment settings 0xE1 - 0xE6: save to env_regs
            0xE1...0xE6 => {
                const idx: usize = @intCast(opcode - 0xE1);
                if (idx < self.env_regs.len) self.env_regs[idx] = self.gp0_cmd_buffer[0];
            },

            // Monochromatic Triangle
            0x20, 0x21, 0x22, 0x23 => {
                const is_transparent = (opcode & 0x02) != 0;
                const color16 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const x1 = getX(self.gp0_cmd_buffer[2]);
                const y1 = getY(self.gp0_cmd_buffer[2]);
                const x2 = getX(self.gp0_cmd_buffer[3]);
                const y2 = getY(self.gp0_cmd_buffer[3]);

                self.drawTriangle(x0, y0, x1, y1, x2, y2, color16, is_transparent);
            },

            // Monochromatic Quad
            0x28, 0x29, 0x2A, 0x2B => {
                const is_transparent = (opcode & 0x02) != 0;
                const color16 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const x1 = getX(self.gp0_cmd_buffer[2]);
                const y1 = getY(self.gp0_cmd_buffer[2]);
                const x2 = getX(self.gp0_cmd_buffer[3]);
                const y2 = getY(self.gp0_cmd_buffer[3]);
                const x3 = getX(self.gp0_cmd_buffer[4]);
                const y3 = getY(self.gp0_cmd_buffer[4]);

                self.drawTriangle(x0, y0, x1, y1, x2, y2, color16, is_transparent);
                self.drawTriangle(x1, y1, x2, y2, x3, y3, color16, is_transparent);
            },

            // Shaded Textured Triangle
            0x34, 0x35, 0x36, 0x37 => {
                const is_transparent = (opcode & 0x02) != 0;
                const c0 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const tu0: u8 = @intCast(self.gp0_cmd_buffer[2] & 0xFF);
                const tv0: u8 = @intCast((self.gp0_cmd_buffer[2] >> 8) & 0xFF);
                const clut: u16 = @intCast((self.gp0_cmd_buffer[2] >> 16) & 0xFFFF);

                // Note: buffer[3] is Color 1, skipped for flat texturing
                const x1 = getX(self.gp0_cmd_buffer[4]);
                const y1 = getY(self.gp0_cmd_buffer[4]);
                const tu1: u8 = @intCast(self.gp0_cmd_buffer[5] & 0xFF);
                const tv1: u8 = @intCast((self.gp0_cmd_buffer[5] >> 8) & 0xFF);
                const tpage: u16 = @intCast((self.gp0_cmd_buffer[5] >> 16) & 0xFFFF);

                // Note: buffer[6] is Color 2, skipped for flat texturing
                const x2 = getX(self.gp0_cmd_buffer[7]);
                const y2 = getY(self.gp0_cmd_buffer[7]);
                const tu2: u8 = @intCast(self.gp0_cmd_buffer[8] & 0xFF);
                const tv2: u8 = @intCast((self.gp0_cmd_buffer[8] >> 8) & 0xFF);

                self.drawTexturedTriangle(x0, y0, tu0, tv0, x1, y1, tu1, tv1, x2, y2, tu2, tv2, c0, clut, tpage, is_transparent, opcode);
            },

            // Shaded Textured Quad
            0x3C, 0x3D, 0x3E, 0x3F => {
                const is_transparent = (opcode & 0x02) != 0;
                const c0 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const tu0: u8 = @intCast(self.gp0_cmd_buffer[2] & 0xFF);
                const tv0: u8 = @intCast((self.gp0_cmd_buffer[2] >> 8) & 0xFF);
                const clut: u16 = @intCast((self.gp0_cmd_buffer[2] >> 16) & 0xFFFF);

                const x1 = getX(self.gp0_cmd_buffer[4]);
                const y1 = getY(self.gp0_cmd_buffer[4]);
                const tu1: u8 = @intCast(self.gp0_cmd_buffer[5] & 0xFF);
                const tv1: u8 = @intCast((self.gp0_cmd_buffer[5] >> 8) & 0xFF);
                const tpage: u16 = @intCast((self.gp0_cmd_buffer[5] >> 16) & 0xFFFF);

                const x2 = getX(self.gp0_cmd_buffer[7]);
                const y2 = getY(self.gp0_cmd_buffer[7]);
                const tu2: u8 = @intCast(self.gp0_cmd_buffer[8] & 0xFF);
                const tv2: u8 = @intCast((self.gp0_cmd_buffer[8] >> 8) & 0xFF);

                const x3 = getX(self.gp0_cmd_buffer[10]);
                const y3 = getY(self.gp0_cmd_buffer[10]);
                const tu3: u8 = @intCast(self.gp0_cmd_buffer[11] & 0xFF);
                const tv3: u8 = @intCast((self.gp0_cmd_buffer[11] >> 8) & 0xFF);

                self.drawTexturedTriangle(x0, y0, tu0, tv0, x1, y1, tu1, tv1, x2, y2, tu2, tv2, c0, clut, tpage, is_transparent, opcode);
                self.drawTexturedTriangle(x1, y1, tu1, tv1, x2, y2, tu2, tv2, x3, y3, tu3, tv3, c0, clut, tpage, is_transparent, opcode);
            },

            // Textured Triangle
            0x24, 0x25, 0x26, 0x27 => {
                const is_transparent = (opcode & 0x02) != 0;
                const c0 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const tu0: u8 = @intCast(self.gp0_cmd_buffer[2] & 0xFF);
                const tv0: u8 = @intCast((self.gp0_cmd_buffer[2] >> 8) & 0xFF);
                const clut: u16 = @intCast((self.gp0_cmd_buffer[2] >> 16) & 0xFFFF);

                const x1 = getX(self.gp0_cmd_buffer[3]);
                const y1 = getY(self.gp0_cmd_buffer[3]);
                const tu1: u8 = @intCast(self.gp0_cmd_buffer[4] & 0xFF);
                const tv1: u8 = @intCast((self.gp0_cmd_buffer[4] >> 8) & 0xFF);
                const tpage: u16 = @intCast((self.gp0_cmd_buffer[4] >> 16) & 0xFFFF);

                const x2 = getX(self.gp0_cmd_buffer[5]);
                const y2 = getY(self.gp0_cmd_buffer[5]);
                const tu2: u8 = @intCast(self.gp0_cmd_buffer[6] & 0xFF);
                const tv2: u8 = @intCast((self.gp0_cmd_buffer[6] >> 8) & 0xFF);

                self.drawTexturedTriangle(x0, y0, tu0, tv0, x1, y1, tu1, tv1, x2, y2, tu2, tv2, c0, clut, tpage, is_transparent, opcode);
            },

            // Textured Quad
            0x2C, 0x2D, 0x2E, 0x2F => {
                const is_transparent = (opcode & 0x02) != 0;
                const c0 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const tu0: u8 = @intCast(self.gp0_cmd_buffer[2] & 0xFF);
                const tv0: u8 = @intCast((self.gp0_cmd_buffer[2] >> 8) & 0xFF);
                const clut: u16 = @intCast((self.gp0_cmd_buffer[2] >> 16) & 0xFFFF);

                const x1 = getX(self.gp0_cmd_buffer[3]);
                const y1 = getY(self.gp0_cmd_buffer[3]);
                const tu1: u8 = @intCast(self.gp0_cmd_buffer[4] & 0xFF);
                const tv1: u8 = @intCast((self.gp0_cmd_buffer[4] >> 8) & 0xFF);
                const tpage: u16 = @intCast((self.gp0_cmd_buffer[4] >> 16) & 0xFFFF);

                const x2 = getX(self.gp0_cmd_buffer[5]);
                const y2 = getY(self.gp0_cmd_buffer[5]);
                const tu2: u8 = @intCast(self.gp0_cmd_buffer[6] & 0xFF);
                const tv2: u8 = @intCast((self.gp0_cmd_buffer[6] >> 8) & 0xFF);

                const x3 = getX(self.gp0_cmd_buffer[7]);
                const y3 = getY(self.gp0_cmd_buffer[7]);
                const tu3: u8 = @intCast(self.gp0_cmd_buffer[8] & 0xFF);
                const tv3: u8 = @intCast((self.gp0_cmd_buffer[8] >> 8) & 0xFF);

                self.drawTexturedTriangle(x0, y0, tu0, tv0, x1, y1, tu1, tv1, x2, y2, tu2, tv2, c0, clut, tpage, is_transparent, opcode);
                self.drawTexturedTriangle(x1, y1, tu1, tv1, x2, y2, tu2, tv2, x3, y3, tu3, tv3, c0, clut, tpage, is_transparent, opcode);
            },

            // Shaded Triangle
            0x30, 0x31, 0x32, 0x33 => {
                const is_transparent = (opcode & 0x02) != 0;
                const c0 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const c1 = self.getColor16(self.gp0_cmd_buffer[2]);
                const x1 = getX(self.gp0_cmd_buffer[3]);
                const y1 = getY(self.gp0_cmd_buffer[3]);
                const c2 = self.getColor16(self.gp0_cmd_buffer[4]);
                const x2 = getX(self.gp0_cmd_buffer[5]);
                const y2 = getY(self.gp0_cmd_buffer[5]);

                self.drawShadedTriangle(x0, y0, c0, x1, y1, c1, x2, y2, c2, is_transparent);
            },

            // Shaded Quad
            0x38, 0x39, 0x3A, 0x3B => {
                const is_transparent = (opcode & 0x02) != 0;
                const c0 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const c1 = self.getColor16(self.gp0_cmd_buffer[2]);
                const x1 = getX(self.gp0_cmd_buffer[3]);
                const y1 = getY(self.gp0_cmd_buffer[3]);
                const c2 = self.getColor16(self.gp0_cmd_buffer[4]);
                const x2 = getX(self.gp0_cmd_buffer[5]);
                const y2 = getY(self.gp0_cmd_buffer[5]);
                const c3 = self.getColor16(self.gp0_cmd_buffer[6]);
                const x3 = getX(self.gp0_cmd_buffer[7]);
                const y3 = getY(self.gp0_cmd_buffer[7]);

                self.drawShadedTriangle(x0, y0, c0, x1, y1, c1, x2, y2, c2, is_transparent);
                self.drawShadedTriangle(x1, y1, c1, x2, y2, c2, x3, y3, c3, is_transparent);
            },

            // Monochromatic Line
            0x40...0x47 => {
                const is_transparent = (opcode & 0x02) != 0;
                const color16 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const x1 = getX(self.gp0_cmd_buffer[2]);
                const y1 = getY(self.gp0_cmd_buffer[2]);

                self.drawLine(x0, y0, x1, y1, color16, is_transparent);
            },

            // Shaded Line
            0x50...0x57 => {
                const is_transparent = (opcode & 0x02) != 0;
                const c0 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x0 = getX(self.gp0_cmd_buffer[1]);
                const y0 = getY(self.gp0_cmd_buffer[1]);
                const c1 = self.getColor16(self.gp0_cmd_buffer[2]);
                const x1 = getX(self.gp0_cmd_buffer[3]);
                const y1 = getY(self.gp0_cmd_buffer[3]);

                self.drawShadedLine(x0, y0, c0, x1, y1, c1, is_transparent);
            },

            // Monochromatic Rectangle (Variable size)
            0x60, 0x61, 0x62, 0x63 => {
                const is_transparent = (opcode & 0x02) != 0;
                const color16 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x = getX(self.gp0_cmd_buffer[1]);
                const y = getY(self.gp0_cmd_buffer[1]);
                const w: i16 = @intCast(self.gp0_cmd_buffer[2] & 0xFFFF);
                const h: i16 = @intCast((self.gp0_cmd_buffer[2] >> 16) & 0xFFFF);

                self.drawRectangle(x, y, w, h, color16, is_transparent);
            },

            // Monochromatic Rectangle (8x8)
            0x70, 0x71, 0x72, 0x73 => {
                const is_transparent = (opcode & 0x02) != 0;
                const color16 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x = getX(self.gp0_cmd_buffer[1]);
                const y = getY(self.gp0_cmd_buffer[1]);

                self.drawRectangle(x, y, 8, 8, color16, is_transparent);
            },

            // Monochromatic Rectangle (16x16)
            0x78, 0x79, 0x7A, 0x7B => {
                const is_transparent = (opcode & 0x02) != 0;
                const color16 = self.getColor16(self.gp0_cmd_buffer[0]);
                const x = getX(self.gp0_cmd_buffer[1]);
                const y = getY(self.gp0_cmd_buffer[1]);

                self.drawRectangle(x, y, 16, 16, color16, is_transparent);
            },

            // Fill rectangle: expects 3 words: [opcode|B|G|R], [Y|X], [H|W]
            0x02 => {
                const color16 = self.getColor16(self.gp0_cmd_buffer[0]);

                const word1 = self.gp0_cmd_buffer[1];
                const x = getX(word1);
                const y = getY(word1);

                const word2 = self.gp0_cmd_buffer[2];
                const w: i16 = @intCast(word2 & 0xFFFF);
                const h: i16 = @intCast((word2 >> 16) & 0xFFFF);

                // Fill Rectangle (0x02) is a VRAM command, NOT affected by Offset or Drawing Area
                const max_w = 1024;
                const max_h = 512;
                var yy: i16 = 0;
                while (yy < h) : (yy += 1) {
                    var xx: i16 = 0;
                    while (xx < w) : (xx += 1) {
                        const px = x + xx;
                        const py = y + yy;
                        if (px >= 0 and px < max_w and py >= 0 and py < max_h) {
                            const idx = @as(usize, @intCast(py)) * max_w + @as(usize, @intCast(px));
                            self.vram[idx] = color16;
                        }
                    }
                }
            },

            // VRAM -> VRAM Copy
            0x80 => {
                const word1 = self.gp0_cmd_buffer[1];
                const sx: u16 = @intCast(word1 & 0xFFFF);
                const sy: u16 = @intCast((word1 >> 16) & 0xFFFF);

                const word2 = self.gp0_cmd_buffer[2];
                const dx: u16 = @intCast(word2 & 0xFFFF);
                const dy: u16 = @intCast((word2 >> 16) & 0xFFFF);

                const word3 = self.gp0_cmd_buffer[3];
                var w: u16 = @intCast(word3 & 0xFFFF);
                var h: u16 = @intCast((word3 >> 16) & 0xFFFF);

                if (w == 0) w = 1024;
                if (h == 0) h = 512;

                var yy: u16 = 0;
                while (yy < h) : (yy += 1) {
                    var xx: u16 = 0;
                    while (xx < w) : (xx += 1) {
                        const src_x = (sx + xx) & 0x3FF;
                        const src_y = (sy + yy) & 0x1FF;
                        const dst_x = (dx + xx) & 0x3FF;
                        const dst_y = (dy + yy) & 0x1FF;

                        const src_idx = @as(usize, src_y) * 1024 + @as(usize, src_x);
                        const dst_idx = @as(usize, dst_y) * 1024 + @as(usize, dst_x);

                        self.vram[dst_idx] = self.vram[src_idx];
                    }
                }
            },

            // CPU -> VRAM: header-only here — initialize streaming state
            0xA0 => {
                // Header: [opcode], [Y|X packed 16-bit], [H|W packed 16-bit]
                const word1 = self.gp0_cmd_buffer[1];
                const x: usize = @intCast(word1 & 0xFFFF);
                const y: usize = @intCast((word1 >> 16) & 0xFFFF);

                const word2 = self.gp0_cmd_buffer[2];
                var w: usize = @intCast(word2 & 0xFFFF);
                var h: usize = @intCast((word2 >> 16) & 0xFFFF);

                // Hardware quirk: 0 width or height means full size
                if (w == 0) w = 1024;
                if (h == 0) h = 512;

                self.vram_transfer_x = x;
                self.vram_transfer_y = y;
                self.vram_transfer_w = w;
                self.vram_transfer_h = h;
                self.vram_transfer_curr_x = 0;
                self.vram_transfer_curr_y = 0;

                const pixels = w * h;
                // two pixels per u32 word
                self.vram_transfer_remaining = (pixels + 1) / 2;
                if (self.vram_transfer_remaining > 0) self.vram_transfer_active = true;
            },

            // VRAM -> CPU Copy
            0xC0 => {
                const word1 = self.gp0_cmd_buffer[1];
                const x: usize = @intCast(word1 & 0xFFFF);
                const y: usize = @intCast((word1 >> 16) & 0xFFFF);

                const word2 = self.gp0_cmd_buffer[2];
                var w: usize = @intCast(word2 & 0xFFFF);
                var h: usize = @intCast((word2 >> 16) & 0xFFFF);

                if (w == 0) w = 1024;
                if (h == 0) h = 512;

                self.vram_read_x = x;
                self.vram_read_y = y;
                self.vram_read_w = w;
                self.vram_read_h = h;
                self.vram_read_curr_x = 0;
                self.vram_read_curr_y = 0;

                const pixels = w * h;
                self.vram_read_remaining = (pixels + 1) / 2;
                if (self.vram_read_remaining > 0) self.vram_read_active = true;
            },

            else => {
                // std.debug.print("Unhandled GP0 opcode: 0x{X}\n", .{opcode});
            },
        }

        // Reset buffering state (payload for A0 will be streamed via writeGp0)
        self.gp0_words_remaining = 0;
        self.gp0_words_read = 0;
    }

    // Stream a single u32 of pixel data into VRAM (two 16-bit pixels)
    fn writeVramData(self: *Self, value: u32) void {
        if (!self.vram_transfer_active) return;

        const low: u16 = @intCast(value & 0xFFFF);
        const high: u16 = @intCast((value >> 16) & 0xFFFF);

        const Closure = struct {
            inline fn write_pixel(s: *Self, pix: u16) void {
                const px = s.vram_transfer_x + s.vram_transfer_curr_x;
                const py = s.vram_transfer_y + s.vram_transfer_curr_y;
                if (px < 1024 and py < 512) {
                    const idx = py * 1024 + px;
                    s.vram[idx] = pix;
                }
                s.vram_transfer_curr_x += 1;
                if (s.vram_transfer_curr_x >= s.vram_transfer_w) {
                    s.vram_transfer_curr_x = 0;
                    s.vram_transfer_curr_y += 1;
                }
            }
        };

        // Write low pixel
        if (self.vram_transfer_remaining == 0) return; // nothing expected
        Closure.write_pixel(self, low);

        // If the transfer had an odd number of pixels and this is the final u32,
        // the high half may be padding; still safe to write if within bounds.
        // Only write high pixel if there are still pixels remaining after consuming low
        // Simpler: write high iff we still haven't filled all pixels
        if ((self.vram_transfer_curr_y * self.vram_transfer_w + self.vram_transfer_curr_x) < (self.vram_transfer_w * self.vram_transfer_h)) {
            Closure.write_pixel(self, high);
        }

        // One u32 consumed
        if (self.vram_transfer_remaining > 0) self.vram_transfer_remaining -= 1;
        if (self.vram_transfer_remaining == 0) self.vram_transfer_active = false;
    }

    pub fn writeGp1(self: *Self, value: u32) void {
        const command = (value >> 24) & 0xFF;

        switch (command) {
            0x00 => {
                // Reset GPU
                self.gp0_words_remaining = 0;
                self.gp0_words_read = 0;
                self.vram_transfer_active = false;
                self.display_disabled = true;
                self.interrupt_flag = false;
                self.dma_direction = 0;
                self.display_mode = 0;
                self.env_regs = [_]u32{0} ** 6;
            },
            0x01 => {
                // Reset Command Buffer
                self.gp0_words_remaining = 0;
                self.gp0_words_read = 0;
                self.vram_transfer_active = false;
            },
            0x02 => {
                // Acknowledge IRQ
                self.interrupt_flag = false;
            },
            0x03 => {
                // Display Enable (0 = On, 1 = Off)
                self.display_disabled = (value & 1) != 0;
            },
            0x04 => {
                // DMA Direction (0=Off, 1=FIFO, 2=CPUtoVRAM, 3=VRAMtoCPU)
                self.dma_direction = @truncate(value & 3);
            },
            0x05 => {
                // Display VRAM Start
                self.display_vram_x_start = @truncate(value & 0x3FF);
                self.display_vram_y_start = @truncate((value >> 10) & 0x1FF);
            },
            0x06 => {
                // Display Screen Horizontal Range
                self.display_screen_x1 = @truncate(value & 0xFFF);
                self.display_screen_x2 = @truncate((value >> 12) & 0xFFF);
            },
            0x07 => {
                // Display Screen Vertical Range
                self.display_screen_y1 = @truncate(value & 0x3FF);
                self.display_screen_y2 = @truncate((value >> 10) & 0x3FF);
            },
            0x08 => {
                // Display Mode
                self.display_mode = value & 0x00FFFFFF;
            },
            else => {
                std.log.warn("Unhandled GP1 command: 0x{X:0>2}", .{command});
            },
        }
    }

    pub fn step(self: *Self, cycles: u64) void {
        const frame_cycles = 563333;
        const vblank_start = 500000;

        const current_cycle = cycles % frame_cycles;

        self.is_vblank = current_cycle >= vblank_start;
    }

    pub fn getDisplayWidth(self: *const Self) u32 {
        // Bits 0-2 represent the horizontal resolution
        const hres = self.display_mode & 0x7;
        return switch (hres) {
            0 => 256,
            1 => 320,
            2 => 512,
            3 => 640,
            4 => 368,
            else => 256, // Fallback/Unused
        };
    }

    pub fn getDisplayHeight(self: *const Self) u32 {
        const vres = (self.display_mode >> 2) & 1; // Bit 2: Vertical Resolution
        const is_pal = (self.display_mode >> 3) & 1; // Bit 3: Video Standard

        const base_height: u32 = if (is_pal == 1) 288 else 240;
        return if (vres == 1) base_height * 2 else base_height;
    }

    fn getColorRGB(self: *Self, value: u32) [3]u8 {
        _ = self;
        return .{
            @intCast(value & 0xFF),
            @intCast((value >> 8) & 0xFF),
            @intCast((value >> 16) & 0xFF),
        };
    }

    fn drawShadedTriangle(
        self: *Self,
        x0: i16,
        y0: i16,
        c0: u16,
        x1: i16,
        y1: i16,
        c1: u16,
        x2: i16,
        y2: i16,
        c2: u16,
        is_transparent: bool,
    ) void {
        const offset_x = @as(i16, @intCast(self.env_regs[4] & 0x7FF));
        const offset_y = @as(i16, @intCast((self.env_regs[4] >> 11) & 0x7FF));
        const ox = if (offset_x >= 0x400) offset_x - 0x800 else offset_x;
        const oy = if (offset_y >= 0x400) offset_y - 0x800 else offset_y;

        const vx0 = x0 + ox;
        const vy0 = y0 + oy;
        const vx1 = x1 + ox;
        const vy1 = y1 + oy;
        const vx2 = x2 + ox;
        const vy2 = y2 + oy;

        const min_x = @max(@as(i16, 0), @min(vx0, @min(vx1, vx2)));
        const max_x = @min(@as(i16, 1023), @max(vx0, @max(vx1, vx2)));
        const min_y = @max(@as(i16, 0), @min(vy0, @min(vy1, vy2)));
        const max_y = @min(@as(i16, 511), @max(vy0, @max(vy1, vy2)));

        const area = (@as(i32, vx1) - vx0) * (@as(i32, vy2) - vy0) - (@as(i32, vy1) - vy0) * (@as(i32, vx2) - vx0);
        if (area == 0) return;

        const r0 = @as(f32, @floatFromInt(c0 & 0x1F));
        const g0 = @as(f32, @floatFromInt((c0 >> 5) & 0x1F));
        const b0 = @as(f32, @floatFromInt((c0 >> 10) & 0x1F));

        const r1 = @as(f32, @floatFromInt(c1 & 0x1F));
        const g1 = @as(f32, @floatFromInt((c1 >> 5) & 0x1F));
        const b1 = @as(f32, @floatFromInt((c1 >> 10) & 0x1F));

        const r2 = @as(f32, @floatFromInt(c2 & 0x1F));
        const g2 = @as(f32, @floatFromInt((c2 >> 5) & 0x1F));
        const b2 = @as(f32, @floatFromInt((c2 >> 10) & 0x1F));

        var py = min_y;
        while (py <= max_y) : (py += 1) {
            var px = min_x;
            while (px <= max_x) : (px += 1) {
                const w0 = (@as(i32, vx2) - vx1) * (@as(i32, py) - vy1) - (@as(i32, vy2) - vy1) * (@as(i32, px) - vx1);
                const w1 = (@as(i32, vx0) - vx2) * (@as(i32, py) - vy2) - (@as(i32, vy0) - vy2) * (@as(i32, px) - vx2);
                const w2 = (@as(i32, vx1) - vx0) * (@as(i32, py) - vy0) - (@as(i32, vy1) - vy0) * (@as(i32, px) - vx0);

                const inside = if (area > 0) (w0 >= 0 and w1 >= 0 and w2 >= 0) else (w0 <= 0 and w1 <= 0 and w2 <= 0);

                if (inside) {
                    const f0 = @as(f32, @floatFromInt(w0)) / @as(f32, @floatFromInt(area));
                    const f1 = @as(f32, @floatFromInt(w1)) / @as(f32, @floatFromInt(area));
                    const f2 = @as(f32, @floatFromInt(w2)) / @as(f32, @floatFromInt(area));

                    const r = @as(u16, @intFromFloat(@abs(f0 * r0 + f1 * r1 + f2 * r2)));
                    const g = @as(u16, @intFromFloat(@abs(f0 * g0 + f1 * g1 + f2 * g2)));
                    const b = @as(u16, @intFromFloat(@abs(f0 * b0 + f1 * b1 + f2 * b2)));

                    const color = (b << 10) | (g << 5) | r;
                    self.putPixel(px, py, color, is_transparent);
                }
            }
        }
    }

    fn drawTexturedTriangle(
        self: *Self,
        x0: i16,
        y0: i16,
        tu0: u8,
        tv0: u8,
        x1: i16,
        y1: i16,
        tu1: u8,
        tv1: u8,
        x2: i16,
        y2: i16,
        tu2: u8,
        tv2: u8,
        color: u16,
        clut: u16,
        tpage: u16,
        allow_transparency: bool,
        opcode: u8,
    ) void {
        const offset_x = @as(i16, @intCast(self.env_regs[4] & 0x7FF));
        const offset_y = @as(i16, @intCast((self.env_regs[4] >> 11) & 0x7FF));
        const ox = if (offset_x >= 0x400) offset_x - 0x800 else offset_x;
        const oy = if (offset_y >= 0x400) offset_y - 0x800 else offset_y;

        const vx0 = x0 + ox;
        const vy0 = y0 + oy;
        const vx1 = x1 + ox;
        const vy1 = y1 + oy;
        const vx2 = x2 + ox;
        const vy2 = y2 + oy;

        const min_x = @max(@as(i16, 0), @min(vx0, @min(vx1, vx2)));
        const max_x = @min(@as(i16, 1023), @max(vx0, @max(vx1, vx2)));
        const min_y = @max(@as(i16, 0), @min(vy0, @min(vy1, vy2)));
        const max_y = @min(@as(i16, 511), @max(vy0, @max(vy1, vy2)));

        const area = (@as(i32, vx1) - vx0) * (@as(i32, vy2) - vy0) - (@as(i32, vy1) - vy0) * (@as(i32, vx2) - vx0);
        if (area == 0) return;

        // Decode Texture Page (TPage)
        const tex_depth = (tpage >> 7) & 0x3;
        const tpage_x = (tpage & 0xF) * 64;
        const tpage_y = if ((tpage & 0x10) != 0) @as(u16, 256) else @as(u16, 0);

        // Decode Color Lookup Table (CLUT)
        const clut_x = (clut & 0x3F) * 16;
        const clut_y = (clut >> 6) & 0x1FF;

        var py = min_y;
        while (py <= max_y) : (py += 1) {
            var px = min_x;
            while (px <= max_x) : (px += 1) {
                const w0 = (@as(i32, vx2) - vx1) * (@as(i32, py) - vy1) - (@as(i32, vy2) - vy1) * (@as(i32, px) - vx1);
                const w1 = (@as(i32, vx0) - vx2) * (@as(i32, py) - vy2) - (@as(i32, vy0) - vy2) * (@as(i32, px) - vx2);
                const w2 = (@as(i32, vx1) - vx0) * (@as(i32, py) - vy0) - (@as(i32, vy1) - vy0) * (@as(i32, px) - vx0);

                const inside = if (area > 0) (w0 >= 0 and w1 >= 0 and w2 >= 0) else (w0 <= 0 and w1 <= 0 and w2 <= 0);

                if (inside) {
                    // Barycentric interpolation for Affine Texture mapping
                    const f0 = @as(f32, @floatFromInt(w0)) / @as(f32, @floatFromInt(area));
                    const f1 = @as(f32, @floatFromInt(w1)) / @as(f32, @floatFromInt(area));
                    const f2 = @as(f32, @floatFromInt(w2)) / @as(f32, @floatFromInt(area));

                    const u = @as(u16, @intFromFloat(@abs(f0 * @as(f32, @floatFromInt(tu0)) + f1 * @as(f32, @floatFromInt(tu1)) + f2 * @as(f32, @floatFromInt(tu2)))));
                    const v = @as(u16, @intFromFloat(@abs(f0 * @as(f32, @floatFromInt(tv0)) + f1 * @as(f32, @floatFromInt(tv1)) + f2 * @as(f32, @floatFromInt(tv2)))));

                    var texel_color: u16 = 0;

                    if (tex_depth == 0) {
                        // 4-bit Texture (4 pixels packed into 1 u16)
                        const tex_x = tpage_x + (u / 4);
                        const tex_y = tpage_y + v;
                        const tex_val = self.vram[@as(usize, tex_y) * 1024 + @as(usize, tex_x)];

                        // Extract the exact 4-bit nibble
                        const shift = @as(u4, @truncate((u % 4) * 4));
                        const index = (tex_val >> shift) & 0xF;

                        // Look up the actual 15-bit color in the CLUT
                        texel_color = self.vram[@as(usize, clut_y) * 1024 + @as(usize, clut_x + index)];
                    } else if (tex_depth == 1) {
                        // 8-bit Texture (2 pixels packed into 1 u16)
                        const tex_x = tpage_x + (u / 2);
                        const tex_y = tpage_y + v;
                        const tex_val = self.vram[@as(usize, tex_y) * 1024 + @as(usize, tex_x)];

                        const shift = @as(u4, @truncate((u % 2) * 8));
                        const index = (tex_val >> shift) & 0xFF;

                        texel_color = self.vram[@as(usize, clut_y) * 1024 + @as(usize, clut_x + index)];
                    } else {
                        // 15-bit Direct Texture
                        const tex_x = tpage_x + u;
                        const tex_y = tpage_y + v;
                        texel_color = self.vram[@as(usize, tex_y) * 1024 + @as(usize, tex_x)];
                    }

                    // In PS1, 0x0000 is absolute transparent black. Do not draw it!
                    if (texel_color != 0) {
                        var final_texel = texel_color;

                        // If Bit 0 of the opcode is 0, we modulate!
                        if ((opcode & 1) == 0) {
                            // Extract texture RGB
                            const tr = texel_color & 0x1F;
                            const tg = (texel_color >> 5) & 0x1F;
                            const tb = (texel_color >> 10) & 0x1F;

                            // Extract primitive base color RGB
                            const cr = color & 0x1F;
                            const cg = (color >> 5) & 0x1F;
                            const cb = (color >> 10) & 0x1F;

                            // Modulate: (Texture * Color) / 16
                            var r = (tr * cr) >> 4;
                            var g = (tg * cg) >> 4;
                            var b = (tb * cb) >> 4;

                            // Clamp to 31
                            r = @min(r, 31);
                            g = @min(g, 31);
                            b = @min(b, 31);

                            // Preserve the texture's original MSB (transparency bit)
                            const msb = texel_color & 0x8000;
                            final_texel = r | (g << 5) | (b << 10) | msb;
                        }

                        const is_pixel_transparent = allow_transparency and ((final_texel & 0x8000) != 0);
                        self.putPixel(px, py, final_texel, is_pixel_transparent);
                    }
                }
            }
        }
    }

    fn startPolyline(self: *Self, value: u32) void {
        const opcode: u8 = @intCast((value >> 24) & 0xFF);
        self.polyline_active = true;
        self.polyline_shaded = (opcode & 0x10) != 0;
        self.polyline_transparent = (opcode & 0x02) != 0;
        self.polyline_count = 0;
        self.polyline_prev_color = self.getColor16(value);
    }

    fn continuePolyline(self: *Self, value: u32) void {
        if (value == 0x55555555) {
            self.polyline_active = false;
            return;
        }

        if (self.polyline_shaded) {
            if (self.polyline_count % 2 == 0) {
                // Vertex
                const x: i16 = @intCast(value & 0xFFFF);
                const y: i16 = @intCast((value >> 16) & 0xFFFF);

                if (self.polyline_count > 0) {
                    self.drawShadedLine(self.polyline_prev_x, self.polyline_prev_y, self.polyline_prev_color, x, y, self.polyline_next_color, self.polyline_transparent);
                }

                self.polyline_prev_x = x;
                self.polyline_prev_y = y;
                self.polyline_prev_color = if (self.polyline_count == 0) self.polyline_prev_color else self.polyline_next_color;
                self.polyline_count += 1;
            } else {
                // Color
                self.polyline_next_color = self.getColor16(value);
                self.polyline_count += 1;
            }
        } else {
            // Mono
            const x: i16 = @intCast(value & 0xFFFF);
            const y: i16 = @intCast((value >> 16) & 0xFFFF);

            if (self.polyline_count > 0) {
                self.drawLine(self.polyline_prev_x, self.polyline_prev_y, x, y, self.polyline_prev_color, self.polyline_transparent);
            }

            self.polyline_prev_x = x;
            self.polyline_prev_y = y;
            self.polyline_count += 1;
        }
    }

    fn drawLine(self: *Self, x0: i16, y0: i16, x1: i16, y1: i16, color: u16, is_transparent: bool) void {
        const offset_x = @as(i16, @intCast(self.env_regs[4] & 0x7FF));
        const offset_y = @as(i16, @intCast((self.env_regs[4] >> 11) & 0x7FF));
        const ox = if (offset_x >= 0x400) offset_x - 0x800 else offset_x;
        const oy = if (offset_y >= 0x400) offset_y - 0x800 else offset_y;

        var cx = x0 + ox;
        var cy = y0 + oy;
        const target_x = x1 + ox;
        const target_y = y1 + oy;

        const dx = @abs(target_x - cx);
        const dy = @abs(target_y - cy);
        const sx: i16 = if (cx < target_x) 1 else -1;
        const sy: i16 = if (cy < target_y) 1 else -1;
        var err = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));

        while (true) {
            self.putPixel(cx, cy, color, is_transparent);

            if (cx == target_x and cy == target_y) break;

            const e2 = 2 * err;
            if (e2 > -@as(i32, @intCast(dy))) {
                err -= @as(i32, @intCast(dy));
                cx += sx;
            }
            if (e2 < @as(i32, @intCast(dx))) {
                err += @as(i32, @intCast(dx));
                cy += sy;
            }
        }
    }

    fn drawShadedLine(self: *Self, x0: i16, y0: i16, c0: u16, x1: i16, y1: i16, c1: u16, is_transparent: bool) void {
        const offset_x = @as(i16, @intCast(self.env_regs[4] & 0x7FF));
        const offset_y = @as(i16, @intCast((self.env_regs[4] >> 11) & 0x7FF));
        const ox = if (offset_x >= 0x400) offset_x - 0x800 else offset_x;
        const oy = if (offset_y >= 0x400) offset_y - 0x800 else offset_y;

        var cx = x0 + ox;
        var cy = y0 + oy;
        const target_x = x1 + ox;
        const target_y = y1 + oy;

        const dx = @abs(target_x - cx);
        const dy = @abs(target_y - cy);
        const sx: i16 = if (cx < target_x) 1 else -1;
        const sy: i16 = if (cy < target_y) 1 else -1;
        var err = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));

        const r0 = @as(f32, @floatFromInt(c0 & 0x1F));
        const g0 = @as(f32, @floatFromInt((c0 >> 5) & 0x1F));
        const b0 = @as(f32, @floatFromInt((c0 >> 10) & 0x1F));

        const r1 = @as(f32, @floatFromInt(c1 & 0x1F));
        const g1 = @as(f32, @floatFromInt((c1 >> 5) & 0x1F));
        const b1 = @as(f32, @floatFromInt((c1 >> 10) & 0x1F));

        const steps = @as(f32, @floatFromInt(@max(dx, dy)));
        if (steps == 0) {
            self.putPixel(cx, cy, c0, is_transparent);
            return;
        }

        const dr = (r1 - r0) / steps;
        const dg = (g1 - g0) / steps;
        const db = (b1 - b0) / steps;

        var curr_r = r0;
        var curr_g = g0;
        var curr_b = b0;

        while (true) {
            const r = @as(u16, @intFromFloat(@abs(curr_r)));
            const g = @as(u16, @intFromFloat(@abs(curr_g)));
            const b = @as(u16, @intFromFloat(@abs(curr_b)));
            const color = (b << 10) | (g << 5) | r;
            self.putPixel(cx, cy, color, is_transparent);

            if (cx == target_x and cy == target_y) break;

            const e2 = 2 * err;
            if (e2 > -@as(i32, @intCast(dy))) {
                err -= @as(i32, @intCast(dy));
                cx += sx;
            }
            if (e2 < @as(i32, @intCast(dx))) {
                err += @as(i32, @intCast(dx));
                cy += sy;
            }

            curr_r += dr;
            curr_g += dg;
            curr_b += db;
        }
    }

    fn drawTriangle(self: *Self, x0: i16, y0: i16, x1: i16, y1: i16, x2: i16, y2: i16, color: u16, is_transparent: bool) void {
        const offset_x = @as(i16, @intCast(self.env_regs[4] & 0x7FF));
        const offset_y = @as(i16, @intCast((self.env_regs[4] >> 11) & 0x7FF));
        const ox = if (offset_x >= 0x400) offset_x - 0x800 else offset_x;
        const oy = if (offset_y >= 0x400) offset_y - 0x800 else offset_y;

        const vx0 = x0 + ox;
        const vy0 = y0 + oy;
        const vx1 = x1 + ox;
        const vy1 = y1 + oy;
        const vx2 = x2 + ox;
        const vy2 = y2 + oy;

        const min_x = @max(@as(i16, 0), @min(vx0, @min(vx1, vx2)));
        const max_x = @min(@as(i16, 1023), @max(vx0, @max(vx1, vx2)));
        const min_y = @max(@as(i16, 0), @min(vy0, @min(vy1, vy2)));
        const max_y = @min(@as(i16, 511), @max(vy0, @max(vy1, vy2)));

        const area = (@as(i32, vx1) - vx0) * (@as(i32, vy2) - vy0) - (@as(i32, vy1) - vy0) * (@as(i32, vx2) - vx0);
        if (area == 0) return;

        var py = min_y;
        while (py <= max_y) : (py += 1) {
            var px = min_x;
            while (px <= max_x) : (px += 1) {
                const w0 = (@as(i32, vx2) - vx1) * (@as(i32, py) - vy1) - (@as(i32, vy2) - vy1) * (@as(i32, px) - vx1);
                const w1 = (@as(i32, vx0) - vx2) * (@as(i32, py) - vy2) - (@as(i32, vy0) - vy2) * (@as(i32, px) - vx2);
                const w2 = (@as(i32, vx1) - vx0) * (@as(i32, py) - vy0) - (@as(i32, vy1) - vy0) * (@as(i32, px) - vx0);

                const inside = if (area > 0) (w0 >= 0 and w1 >= 0 and w2 >= 0) else (w0 <= 0 and w1 <= 0 and w2 <= 0);

                if (inside) {
                    self.putPixel(px, py, color, is_transparent);
                }
            }
        }
    }
};
