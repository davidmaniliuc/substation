const std = @import("std");

pub const Vram = struct {
    data: [1024 * 512]u16 = [_]u16{0} ** (1024 * 512),

    // CPU -> VRAM state
    write_active: bool = false,
    write_x: usize = 0,
    write_y: usize = 0,
    write_w: usize = 0,
    write_h: usize = 0,
    write_curr_x: usize = 0,
    write_curr_y: usize = 0,
    write_remaining: usize = 0,

    // VRAM -> CPU state
    read_active: bool = false,
    read_x: usize = 0,
    read_y: usize = 0,
    read_w: usize = 0,
    read_h: usize = 0,
    read_curr_x: usize = 0,
    read_curr_y: usize = 0,
    read_remaining: usize = 0,

    pub fn setupWrite(self: *Vram, x: usize, y: usize, w: usize, h: usize) void {
        var width = w;
        var height = h;
        if (width == 0) width = 1024;
        if (height == 0) height = 512;

        self.write_x = x;
        self.write_y = y;
        self.write_w = width;
        self.write_h = height;
        self.write_curr_x = 0;
        self.write_curr_y = 0;
        self.write_remaining = (width * height + 1) / 2;
        self.write_active = self.write_remaining > 0;
    }

    pub fn setupRead(self: *Vram, x: usize, y: usize, w: usize, h: usize) void {
        var width = w;
        var height = h;
        if (width == 0) width = 1024;
        if (height == 0) height = 512;

        self.read_x = x;
        self.read_y = y;
        self.read_w = width;
        self.read_h = height;
        self.read_curr_x = 0;
        self.read_curr_y = 0;
        self.read_remaining = (width * height + 1) / 2;
        self.read_active = self.read_remaining > 0;
    }

    pub fn writePixel(self: *Vram, pix: u16) void {
        const px = self.write_x + self.write_curr_x;
        const py = self.write_y + self.write_curr_y;
        if (px < 1024 and py < 512) {
            self.data[py * 1024 + px] = pix;
        }
        self.write_curr_x += 1;
        if (self.write_curr_x >= self.write_w) {
            self.write_curr_x = 0;
            self.write_curr_y += 1;
        }
    }

    pub fn writeData(self: *Vram, value: u32) void {
        if (!self.write_active) return;

        const low: u16 = @intCast(value & 0xFFFF);
        const high: u16 = @intCast((value >> 16) & 0xFFFF);

        self.writePixel(low);
        if ((self.write_curr_y * self.write_w + self.write_curr_x) < (self.write_w * self.write_h)) {
            self.writePixel(high);
        }

        if (self.write_remaining > 0) self.write_remaining -= 1;
        if (self.write_remaining == 0) self.write_active = false;
    }

    pub fn readPixel(self: *Vram) u16 {
        const px = self.read_x + self.read_curr_x;
        const py = self.read_y + self.read_curr_y;
        var pix: u16 = 0;

        if (px < 1024 and py < 512) {
            pix = self.data[py * 1024 + px];
        }

        self.read_curr_x += 1;
        if (self.read_curr_x >= self.read_w) {
            self.read_curr_x = 0;
            self.read_curr_y += 1;
        }
        return pix;
    }

    pub fn readData(self: *Vram) u32 {
        if (!self.read_active) return 0;

        const low = self.readPixel();
        var high: u16 = 0;

        if ((self.read_curr_y * self.read_w + self.read_curr_x) < (self.read_w * self.read_h)) {
            high = self.readPixel();
        }

        if (self.read_remaining > 0) self.read_remaining -= 1;
        if (self.read_remaining == 0) self.read_active = false;

        return @as(u32, low) | (@as(u32, high) << 16);
    }

    pub fn copyRect(self: *Vram, sx: u16, sy: u16, dx: u16, dy: u16, w: u16, h: u16) void {
        var width = w;
        var height = h;
        if (width == 0) width = 1024;
        if (height == 0) height = 512;

        var yy: u16 = 0;
        while (yy < height) : (yy += 1) {
            var xx: u16 = 0;
            while (xx < width) : (xx += 1) {
                const src_x = (sx + xx) & 0x3FF;
                const src_y = (sy + yy) & 0x1FF;
                const dst_x = (dx + xx) & 0x3FF;
                const dst_y = (dy + yy) & 0x1FF;

                self.data[@as(usize, dst_y) * 1024 + @as(usize, dst_x)] = self.data[@as(usize, src_y) * 1024 + @as(usize, src_x)];
            }
        }
    }

    pub fn fillRectangle(self: *Vram, x: i16, y: i16, w: i16, h: i16, color: u16) void {
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
                    self.data[idx] = color;
                }
            }
        }
    }
};
