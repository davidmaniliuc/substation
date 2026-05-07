const std = @import("std");
pub const Vram = @import("vram.zig").Vram;
pub const Regs = @import("registers.zig");
pub const Gp0Engine = @import("gp0.zig").Gp0Engine;

pub const Gpu = struct {
    const Self = @This();

    vram: Vram = .{},
    draw_env: Regs.DrawingEnv = .{},
    disp_env: Regs.DisplayEnv = .{},
    gp0: Gp0Engine = .{},

    // GP1 state
    dma_direction: u2 = 0,
    interrupt_flag: bool = false,
    is_vblank: bool = false,

    pub fn init() Self {
        return .{};
    }

    pub fn getVramPtr(self: *Self) [*]const u16 {
        return @ptrCast(&self.vram.data);
    }

    pub fn step(self: *Self, cycles: u64) void {
        const frame_cycles = 563333;
        const vblank_start = 500000;
        const current_cycle = cycles % frame_cycles;
        self.is_vblank = current_cycle >= vblank_start;
    }

    pub fn readStatus(self: *const Self) u32 {
        var stat: u32 = 0;

        stat |= (self.draw_env.draw_mode & 0x7FF); // Bits 0-10
        stat |= (self.draw_env.mask_bit & 0x3) << 11; // Bits 11-12
        stat |= ((self.draw_env.draw_mode >> 11) & 1) << 15; // Bit 15

        stat |= (self.disp_env.display_mode & 0x7F) << 16;

        if (self.disp_env.display_disabled) stat |= (1 << 23);
        if (self.interrupt_flag) stat |= (1 << 24);

        if (!self.vram.write_active) {
            stat |= (1 << 26); // Ready to receive GP0 Cmd
            stat |= (1 << 27); // Ready to send VRAM to CPU
            stat |= (1 << 28); // Ready to receive DMA block
        }

        stat |= (@as(u32, self.dma_direction) << 29);
        if (self.is_vblank) stat |= (1 << 31);

        return stat;
    }

    pub fn readData(self: *Self) u32 {
        return self.vram.readData();
    }

    pub fn writeGp0(self: *Self, value: u32) void {
        self.gp0.write(value, &self.vram, &self.draw_env, &self.interrupt_flag);
    }

    pub fn writeGp1(self: *Self, value: u32) void {
        const command = (value >> 24) & 0xFF;

        switch (command) {
            0x00 => {
                // Reset GPU
                self.gp0.words_remaining = 0;
                self.gp0.words_read = 0;
                self.vram.write_active = false;
                self.disp_env.display_disabled = true;
                self.interrupt_flag = false;
                self.dma_direction = 0;
                self.disp_env.display_mode = 0;
                self.draw_env = .{};
            },
            0x01 => {
                // Reset Command Buffer
                self.gp0.words_remaining = 0;
                self.gp0.words_read = 0;
                self.vram.write_active = false;
            },
            0x02 => {
                self.interrupt_flag = false;
            },
            0x03 => {
                self.disp_env.display_disabled = (value & 1) != 0;
            },
            0x04 => {
                self.dma_direction = @truncate(value & 3);
            },
            0x05 => {
                self.disp_env.vram_x_start = @truncate(value & 0x3FF);
                self.disp_env.vram_y_start = @truncate((value >> 10) & 0x1FF);
            },
            0x06 => {
                self.disp_env.screen_x1 = @truncate(value & 0xFFF);
                self.disp_env.screen_x2 = @truncate((value >> 12) & 0xFFF);
            },
            0x07 => {
                self.disp_env.screen_y1 = @truncate(value & 0x3FF);
                self.disp_env.screen_y2 = @truncate((value >> 10) & 0x3FF);
            },
            0x08 => {
                self.disp_env.display_mode = value & 0x00FFFFFF;
            },
            else => {
                std.log.warn("Unhandled GP1 command: 0x{X:0>2}", .{command});
            },
        }
    }

    pub fn getDisplayWidth(self: *const Self) u32 {
        return self.disp_env.getWidth();
    }

    pub fn getDisplayHeight(self: *const Self) u32 {
        return self.disp_env.getHeight();
    }

    pub fn getColor16(self: *const Self, value: u32) u16 {
        _ = self;
        const r = (value & 0xFF) >> 3;
        const g = ((value >> 8) & 0xFF) >> 3;
        const b = ((value >> 16) & 0xFF) >> 3;
        return @as(u16, @intCast((b << 10) | (g << 5) | r));
    }
};
