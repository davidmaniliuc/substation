const std = @import("std");
const constants = @import("../constants.zig");

/// GP0(E6) mask settings, as they apply to a VRAM write.
pub const Mask = struct {
    /// bit0: OR bit15 into every pixel written.
    set: bool = false,
    /// bit1: skip pixels whose existing bit15 is set.
    check: bool = false,

    pub fn fromE6(mask_bit: u32) Mask {
        return .{ .set = (mask_bit & 1) != 0, .check = (mask_bit & 2) != 0 };
    }
};

pub const Vram = struct {
    data: [constants.vram_width * constants.vram_height]u16 = [_]u16{0} ** (constants.vram_width * constants.vram_height),

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

    /// VRAM is row-major, 1024 pixels per row. Callers pass unsigned coordinates
    /// already known in range — clipping happens before this.
    pub inline fn index(x: usize, y: usize) usize {
        return y * constants.vram_width + x;
    }

    pub fn setupWrite(self: *Vram, x: usize, y: usize, w: usize, h: usize) void {
        var width = w;
        var height = h;
        if (width == 0) width = constants.vram_width;
        if (height == 0) height = constants.vram_height;

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
        if (width == 0) width = constants.vram_width;
        if (height == 0) height = constants.vram_height;

        self.read_x = x;
        self.read_y = y;
        self.read_w = width;
        self.read_h = height;
        self.read_curr_x = 0;
        self.read_curr_y = 0;
        self.read_remaining = (width * height + 1) / 2;
        self.read_active = self.read_remaining > 0;
    }

    /// The single masked store shared by CPU->VRAM and VRAM->VRAM transfers.
    /// Mirrors Avocado's GPU::maskedWrite (gpu.cpp:437). Note that Fill
    /// Rectangle (GP0(02)) deliberately does NOT come through here — hardware
    /// ignores GP0(E6) for fills.
    fn maskedWrite(self: *Vram, x: usize, y: usize, value: u16, mask: Mask) void {
        const idx = Vram.index(x, y);
        if (mask.check and (self.data[idx] & 0x8000) != 0) return;
        self.data[idx] = value | (@as(u16, @intFromBool(mask.set)) << 15);
    }

    pub fn writePixel(self: *Vram, pix: u16, mask: Mask) void {
        const px = self.write_x + self.write_curr_x;
        const py = self.write_y + self.write_curr_y;
        if (px < constants.vram_width and py < constants.vram_height) {
            self.maskedWrite(px, py, pix, mask);
        }
        self.write_curr_x += 1;
        if (self.write_curr_x >= self.write_w) {
            self.write_curr_x = 0;
            self.write_curr_y += 1;
        }
    }

    pub fn writeData(self: *Vram, value: u32, mask: Mask) void {
        if (!self.write_active) return;

        const low: u16 = @intCast(value & 0xFFFF);
        const high: u16 = @intCast((value >> 16) & 0xFFFF);

        self.writePixel(low, mask);
        if ((self.write_curr_y * self.write_w + self.write_curr_x) < (self.write_w * self.write_h)) {
            self.writePixel(high, mask);
        }

        if (self.write_remaining > 0) self.write_remaining -= 1;
        if (self.write_remaining == 0) self.write_active = false;
    }

    pub fn readPixel(self: *Vram) u16 {
        const px = self.read_x + self.read_curr_x;
        const py = self.read_y + self.read_curr_y;
        var pix: u16 = 0;

        if (px < constants.vram_width and py < constants.vram_height) {
            pix = self.data[Vram.index(px, py)];
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

    pub fn copyRect(self: *Vram, sx: u16, sy: u16, dx: u16, dy: u16, w: u16, h: u16, mask: Mask) void {
        var width = w;
        var height = h;
        if (width == 0) width = constants.vram_width;
        if (height == 0) height = constants.vram_height;

        const backwards = (dy > sy) or (dy == sy and dx > sx);

        if (backwards) {
            var yy: i32 = @intCast(height - 1);
            while (yy >= 0) : (yy -= 1) {
                var xx: i32 = @intCast(width - 1);
                while (xx >= 0) : (xx -= 1) {
                    const src_x = (sx + @as(u16, @intCast(xx))) & 0x3FF;
                    const src_y = (sy + @as(u16, @intCast(yy))) & 0x1FF;
                    const dst_x = (dx + @as(u16, @intCast(xx))) & 0x3FF;
                    const dst_y = (dy + @as(u16, @intCast(yy))) & 0x1FF;
                    self.maskedWrite(dst_x, dst_y, self.data[Vram.index(@as(usize, src_x), @as(usize, src_y))], mask);
                }
            }
        } else {
            var yy: u16 = 0;
            while (yy < height) : (yy += 1) {
                var xx: u16 = 0;
                while (xx < width) : (xx += 1) {
                    const src_x = (sx + xx) & 0x3FF;
                    const src_y = (sy + yy) & 0x1FF;
                    const dst_x = (dx + xx) & 0x3FF;
                    const dst_y = (dy + yy) & 0x1FF;
                    self.maskedWrite(dst_x, dst_y, self.data[Vram.index(@as(usize, src_x), @as(usize, src_y))], mask);
                }
            }
        }
    }

    pub fn fillRectangle(self: *Vram, x: i16, y: i16, w: i16, h: i16, color: u16) void {
        const max_w = constants.vram_width;
        const max_h = constants.vram_height;
        var yy: i16 = 0;
        while (yy < h) : (yy += 1) {
            var xx: i16 = 0;
            while (xx < w) : (xx += 1) {
                const px = x + xx;
                const py = y + yy;
                if (px >= 0 and px < max_w and py >= 0 and py < max_h) {
                    const idx = Vram.index(@as(usize, @intCast(px)), @as(usize, @intCast(py)));
                    self.data[idx] = color;
                }
            }
        }
    }
};
