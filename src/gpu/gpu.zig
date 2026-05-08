const std = @import("std");
pub const Vram = @import("vram.zig").Vram;
pub const Regs = @import("registers.zig");
pub const Gp0Engine = @import("gp0.zig").Gp0Engine;

pub const Gpu = struct {
    const Self = @This();

    pub const ntsc_cycles_per_scanline: u32 = 3413;
    pub const ntsc_scanlines_per_frame: u32 = 263;
    pub const ntsc_vblank_start_line: u32 = 240;

    pub const pal_cycles_per_scanline: u32 = 3406;
    pub const pal_scanlines_per_frame: u32 = 314;
    pub const pal_vblank_start_line: u32 = 288;

    vram: Vram = .{},
    draw_env: Regs.DrawingEnv = .{},
    disp_env: Regs.DisplayEnv = .{},
    gp0: Gp0Engine = .{},

    // GP1 state
    dma_direction: u2 = 0,
    interrupt_flag: bool = false,
    is_vblank: bool = false,
    is_ntsc: bool = true,

    h_count: u32 = 0,
    v_count: u32 = 0,
    dotclock_count: u32 = 0,

    // --- NEW: Edge-trigger tracking ---
    prev_interrupt_flag: bool = false,

    pub const GpuStepResult = struct {
        trigger_vblank_irq: bool = false,
        trigger_gp0_irq: bool = false,
        tick_hblank_timer: bool = false,
        dotclock_ticks: u32 = 0,
    };

    pub fn init() Self {
        return .{};
    }

    pub fn getVramPtr(self: *Self) [*]const u16 {
        return @ptrCast(&self.vram.data);
    }

    pub fn step(self: *Self, delta_cycles: u32) GpuStepResult {
        var result = GpuStepResult{
            .trigger_gp0_irq = self.interrupt_flag and !self.prev_interrupt_flag,
        };

        self.dotclock_count +%= delta_cycles;
        const divider = self.dotclockDivider();
        result.dotclock_ticks = self.dotclock_count / divider;
        self.dotclock_count %= divider;

        self.h_count +%= delta_cycles;
        const cycles_per_scanline = self.cyclesPerScanline();
        while (self.h_count >= cycles_per_scanline) {
            self.h_count -= cycles_per_scanline;
            self.v_count += 1;
            result.tick_hblank_timer = true;

            if (self.v_count == self.vblankStartLine()) {
                result.trigger_vblank_irq = true;
            }

            if (self.v_count >= self.scanlinesPerFrame()) {
                self.v_count = 0;
            }
        }

        self.is_vblank = self.v_count >= self.vblankStartLine();
        self.prev_interrupt_flag = self.interrupt_flag;

        return result;
    }

    pub fn readStatus(self: *const Self) u32 {
        var stat: u32 = 0;

        stat |= (self.draw_env.draw_mode & 0x7FF); // Bits 0-10
        stat |= (self.draw_env.mask_bit & 0x3) << 11; // Bits 11-12
        stat |= ((self.draw_env.draw_mode >> 11) & 1) << 15; // Bit 15

        stat |= (self.disp_env.display_mode & 0x7F) << 16;

        if (self.disp_env.display_disabled) stat |= (1 << 23);
        if (self.interrupt_flag) stat |= (1 << 24);

        // --- MODIFIED: More accurate Ready bits ---
        if (self.gp0.words_remaining == 0) stat |= (1 << 26); // Ready to receive GP0 Cmd
        stat |= (1 << 27); // Ready to send VRAM to CPU
        stat |= (1 << 28); // Ready to receive DMA block

        stat |= (@as(u32, self.dma_direction) << 29);
        if (self.is_vblank) stat |= (1 << 19);
        if ((self.v_count & 1) != 0) stat |= (1 << 31);

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
                self.is_ntsc = true;
                self.is_vblank = false;
                self.h_count = 0;
                self.v_count = 0;
                self.dotclock_count = 0;
                self.prev_interrupt_flag = false;
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
                self.is_ntsc = ((self.disp_env.display_mode >> 3) & 1) == 0;
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

    fn cyclesPerScanline(self: *const Self) u32 {
        return if (self.is_ntsc) ntsc_cycles_per_scanline else pal_cycles_per_scanline;
    }

    fn scanlinesPerFrame(self: *const Self) u32 {
        return if (self.is_ntsc) ntsc_scanlines_per_frame else pal_scanlines_per_frame;
    }

    fn vblankStartLine(self: *const Self) u32 {
        return if (self.is_ntsc) ntsc_vblank_start_line else pal_vblank_start_line;
    }

    fn dotclockDivider(self: *const Self) u32 {
        const hres = (self.disp_env.display_mode & 0x3) |
            ((self.disp_env.display_mode >> 4) & 0x4);
        return switch (hres) {
            0 => 10, // 256 pixels
            1 => 8, // 320 pixels
            2 => 5, // 512 pixels
            3 => 4, // 640 pixels
            4 => 7, // 368 pixels
            else => 10,
        };
    }
};
