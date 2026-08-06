const std = @import("std");

pub const DrawingEnv = struct {
    // Mirroring GP0 E1-E6 registers
    draw_mode: u32 = 0, // E1
    tex_window: u32 = 0, // E2
    area_top_left: u32 = 0, // E3
    area_bot_right: u32 = 0, // E4
    offset: u32 = 0, // E5
    mask_bit: u32 = 0, // E6

    pub fn update(self: *DrawingEnv, opcode: u8, val: u32) void {
        switch (opcode) {
            0xE1 => self.draw_mode = val,
            0xE2 => self.tex_window = val,
            0xE3 => self.area_top_left = val,
            0xE4 => self.area_bot_right = val,
            0xE5 => self.offset = val,
            0xE6 => self.mask_bit = val,
            else => {},
        }
    }

    pub fn getOffsetX(self: DrawingEnv) i16 {
        const off_x = @as(i16, @intCast(self.offset & 0x7FF));
        return if (off_x >= 0x400) off_x - 0x800 else off_x;
    }

    pub fn getOffsetY(self: DrawingEnv) i16 {
        const off_y = @as(i16, @intCast((self.offset >> 11) & 0x7FF));
        return if (off_y >= 0x400) off_y - 0x800 else off_y;
    }
};

pub const DisplayEnv = struct {
    vram_x_start: u16 = 0,
    vram_y_start: u16 = 0,
    screen_x1: u16 = 0x200,
    screen_x2: u16 = 0xC00,
    screen_y1: u16 = 0x010,
    screen_y2: u16 = 0x100,
    display_mode: u32 = 0,
    display_disabled: bool = true,

    pub fn getWidth(self: DisplayEnv) u32 {
        const hres = (self.display_mode & 0x3) | ((self.display_mode >> 4) & 0x4);
        return switch (hres) {
            0 => 256,
            1 => 320,
            2 => 512,
            3 => 640,
            4 => 368,
            else => 256,
        };
    }

    pub fn getHeight(self: DisplayEnv) u32 {
        const vres = (self.display_mode >> 2) & 1;
        const is_pal = (self.display_mode >> 3) & 1;
        const base_height: u32 = if (is_pal == 1) 288 else 240;
        return if (vres == 1) base_height * 2 else base_height;
    }

    /// GPU cycles per displayed dot, i.e. the dotclock divider.
    pub fn getDotclockDivider(self: DisplayEnv) u32 {
        const hres = (self.display_mode & 0x3) | ((self.display_mode >> 4) & 0x4);
        return switch (hres) {
            0 => 10, // 256 pixels
            1 => 8, // 320 pixels
            2 => 5, // 512 pixels
            3 => 4, // 640 pixels
            4 => 7, // 368 pixels
            else => 10,
        };
    }

    /// Dots actually scanned out per line, derived from the horizontal display
    /// range (GP1(06h)). getWidth() is only the mode's nominal maximum; games
    /// routinely program a narrower range, and reading the full nominal width
    /// pulls in VRAM the game never drew.
    pub fn getVisibleWidth(self: DisplayEnv) u32 {
        const nominal = self.getWidth();
        if (self.screen_x2 <= self.screen_x1) return nominal;
        const cycles: u32 = @as(u32, self.screen_x2) - @as(u32, self.screen_x1);
        const dots = cycles / self.getDotclockDivider();
        if (dots == 0) return nominal;
        return @min(dots, nominal);
    }

    /// Scanlines actually scanned out, derived from the vertical display range
    /// (GP1(07h)). In 480-line mode the range covers both interlaced fields, so
    /// it spans twice as many VRAM rows.
    pub fn getVisibleHeight(self: DisplayEnv) u32 {
        const nominal = self.getHeight();
        if (self.screen_y2 <= self.screen_y1) return nominal;
        var lines: u32 = @as(u32, self.screen_y2) - @as(u32, self.screen_y1);
        if ((self.display_mode >> 2) & 1 == 1) lines *= 2;
        return @min(lines, nominal);
    }
};
