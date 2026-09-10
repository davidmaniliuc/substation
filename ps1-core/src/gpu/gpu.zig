const std = @import("std");
pub const Vram = @import("vram.zig").Vram;
pub const Regs = @import("registers.zig");
pub const Gp0Engine = @import("gp0.zig").Gp0Engine;
pub const Renderer = @import("renderer.zig").Renderer;
pub const Color = @import("color.zig");
pub const command = @import("command.zig");
pub const primitive = @import("primitive.zig");
pub const recorder = @import("recorder.zig");
pub const Sink = @import("sink.zig").Sink;
pub const Recorder = @import("recorder.zig").Recorder;
const Value = @import("../pgxp/pgxp.zig").Value;

pub const Gpu = struct {
    const Self = @This();

    pub const ntsc_cycles_per_scanline: u32 = 3413;
    pub const ntsc_scanlines_per_frame: u32 = 263;
    pub const ntsc_vblank_start_line: u32 = 240;

    pub const pal_cycles_per_scanline: u32 = 3406;
    pub const pal_scanlines_per_frame: u32 = 314;
    pub const pal_vblank_start_line: u32 = 288;

    pub const ReadMode = enum {
        Vram,
        Register,
    };

    vram: Vram = .{},
    draw_env: Regs.DrawingEnv = .{},
    disp_env: Regs.DisplayEnv = .{},
    gp0: Gp0Engine = .{},

    /// Zero-sized unless the core was built with `gpu_sink = .dual`.
    sink: Sink = .{},

    gpu_read_mode: ReadMode = .Vram,
    gpu_read_data: u32 = 0,

    // GP1 state
    dma_direction: u2 = 0,
    interrupt_flag: bool = false,
    is_vblank: bool = false,
    is_ntsc: bool = true,

    h_count: u32 = 0,
    v_count: u32 = 0,
    dotclock_count: u32 = 0,

    prev_interrupt_flag: bool = false,
    is_even_field: bool = false,

    fifo: [16]u32 = [_]u32{0} ** 16,
    /// Provenance, indexed by the same head/tail as `fifo`.
    ///
    /// A single pending slot on `Bus` is NOT enough and this is why: the FIFO
    /// is 16 words deep and drains against `cycle_debt`, so a word can sit
    /// here for thousands of cycles while fifteen more are pushed behind it.
    fifo_pgxp: [16]Value = [_]Value{.{}} ** 16,
    fifo_head: u4 = 0,
    fifo_tail: u4 = 0,
    fifo_count: u5 = 0,
    cycle_debt: i32 = 0,

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
            .trigger_vblank_irq = false,
            .trigger_gp0_irq = self.interrupt_flag and !self.prev_interrupt_flag,
        };

        self.cycle_debt -= @intCast(delta_cycles);

        while (self.cycle_debt <= 0 and self.fifo_count > 0) {
            self.processFifoWord();
        }

        if (self.cycle_debt < 0) self.cycle_debt = 0;

        self.dotclock_count +%= delta_cycles;
        // Divide and modulo by a *runtime* value are the most expensive
        // operations on a path that runs once per emulated instruction. The
        // divider only ever takes one of the five values GP1(08h) can select,
        // so switching on it first lets each arm compile to a constant
        // division. Same arithmetic, no divider in the instruction stream.
        switch (self.dotclockDivider()) {
            inline 4, 5, 7, 8, 10 => |d| {
                result.dotclock_ticks = self.dotclock_count / d;
                self.dotclock_count %= d;
            },
            else => |d| {
                result.dotclock_ticks = self.dotclock_count / d;
                self.dotclock_count %= d;
            },
        }

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
                self.is_even_field = !self.is_even_field;
                // The PGXP weld table describes this frame's geometry only.
                self.gp0.endFrame();
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

        // Bit 13 is the interlace field, and it is hardwired to 1 — it has
        // nothing to do with the video mode.
        stat |= (1 << 13);

        const disp_mode = self.disp_env.display_mode;
        const reverse_flag = (disp_mode >> 7) & 1;
        stat |= (reverse_flag << 14); // Bit 14

        // Bit 15 is the E1 texture-disable bit itself, not GP1(09)'s
        // "texture disable is allowed" latch.
        stat |= ((self.draw_env.draw_mode >> 11) & 1) << 15;

        const hres1 = disp_mode & 3;
        const vres = (disp_mode >> 2) & 1;
        const video_mode = (disp_mode >> 3) & 1;
        const color_depth = (disp_mode >> 4) & 1;
        const interlace = (disp_mode >> 5) & 1;
        const hres2 = (disp_mode >> 6) & 1;

        stat |= (hres2 << 16);
        stat |= (hres1 << 17);
        stat |= (vres << 19);
        stat |= (video_mode << 20);
        stat |= (color_depth << 21);
        stat |= (interlace << 22);

        if (self.disp_env.display_disabled) stat |= (1 << 23);
        if (self.interrupt_flag) stat |= (1 << 24);

        const vram_read_pending = self.vramReadPending();

        // Bit 25 is the DMA request line, and what it reports depends on the
        // programmed direction: off entirely for
        // direction 0, unconditional for 1 and 2, and a mirror of bit 27 for
        // direction 3.
        const data_request = switch (self.dma_direction) {
            0 => false,
            1, 2 => true,
            else => vram_read_pending,
        };
        if (data_request) stat |= (1 << 25);

        if (self.fifo_count < 16) stat |= (1 << 26); // Ready to receive GP0 Cmd
        if (vram_read_pending) stat |= (1 << 27); // Ready to send VRAM to CPU
        stat |= (1 << 28); // Ready to receive DMA block

        stat |= (@as(u32, self.dma_direction) << 29);

        // Bit 31: Drawing even/odd lines in interlaced mode (0=Even or Vblank, 1=Odd)
        if (self.is_even_field and interlace == 1 and !self.is_vblank) stat |= (1 << 31);

        return stat;
    }

    /// GPUREAD returns VRAM data only while a GP0(C0) transfer is actually
    /// in flight; draining it, a
    /// GP1(10h..1Fh) info request, and power-on all leave the register selected.
    fn vramReadPending(self: *const Self) bool {
        return self.gpu_read_mode == .Vram and self.vram.read_active;
    }

    pub fn readData(self: *Self) u32 {
        if (!self.vramReadPending()) {
            return self.gpu_read_data;
        }
        return self.vram.readData();
    }

    pub fn writeGp0(self: *Self, value: u32, p: Value) u32 {
        var stall_cycles: u32 = 0;

        if (self.fifo_count == 16) {
            if (self.cycle_debt > 0) {
                stall_cycles = @intCast(self.cycle_debt);
                self.cycle_debt = 0;
            }
            self.processFifoWord();
        }

        self.fifo[self.fifo_tail] = value;
        self.fifo_pgxp[self.fifo_tail] = p;
        self.fifo_tail = self.fifo_tail +% 1;
        self.fifo_count += 1;

        if (self.cycle_debt <= 0) {
            self.processFifoWord();
        }

        return stall_cycles;
    }

    fn processFifoWord(self: *Self) void {
        if (self.fifo_count == 0) return;

        const value = self.fifo[self.fifo_head];
        const p = self.fifo_pgxp[self.fifo_head];
        self.fifo_head = self.fifo_head +% 1;
        self.fifo_count -= 1;

        const debt = self.gp0.write(value, p, &self.sink, &self.vram, &self.draw_env, &self.interrupt_flag);
        self.cycle_debt += @intCast(debt);

        // GP0(C0) re-selects VRAM as GPUREAD's source, clearing any GP1(10h..1Fh)
        // latch. `gp0` only sees the VRAM and draw environment, so the mode
        // is picked up from the transfer it just armed.
        if (self.vram.read_active) self.gpu_read_mode = .Vram;
    }

    pub fn writeGp1(self: *Self, value: u32) void {
        const gp1_command = (value >> 24) & 0xFF;

        switch (gp1_command) {
            0x00 => {
                // Reset GPU
                self.gp0.words_remaining = 0;
                self.gp0.words_read = 0;
                self.sink.vramWriteAbort(&self.vram, &self.draw_env);
                self.disp_env.display_disabled = true;
                self.interrupt_flag = false;
                self.dma_direction = 0;
                self.disp_env.display_mode = 0;
                self.sink.resetDrawEnv(&self.vram, &self.draw_env);
                self.is_ntsc = true;
                self.is_vblank = false;
                self.h_count = 0;
                self.v_count = 0;
                self.dotclock_count = 0;
                self.prev_interrupt_flag = false;
                // A GPU reset deliberately leaves the GPUREAD source alone,
                // so a GP1(1xh) latch survives it.
                self.gpu_read_data = 0;
            },
            0x01 => {
                // Reset Command Buffer
                self.gp0.words_remaining = 0;
                self.gp0.words_read = 0;
                self.sink.vramWriteAbort(&self.vram, &self.draw_env);
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
            0x09 => self.sink.setTextureDisableAllowed(&self.vram, &self.draw_env, (value & 1) != 0),
            0x10...0x1F => {
                self.gpu_read_mode = .Register;
                const arg = value & 0xF;
                self.gpu_read_data = switch (arg) {
                    2 => self.draw_env.tex_window,
                    3 => self.draw_env.area_top_left,
                    4 => self.draw_env.area_bot_right,
                    5 => self.draw_env.offset,
                    7 => 2, // GPU Version
                    8 => 0,
                    else => self.gpu_read_data,
                };
            },
            else => {
                std.log.warn("Unhandled GP1 command: 0x{x:0>2}", .{gp1_command});
            },
        }
    }

    pub fn getDisplayWidth(self: *const Self) u32 {
        return self.disp_env.getVisibleWidth();
    }

    pub fn getDisplayHeight(self: *const Self) u32 {
        return self.disp_env.getVisibleHeight();
    }

    pub fn getColor16(self: *const Self, value: u32) u16 {
        _ = self;
        return Color.getColor16(value);
    }

    // The four helpers below are one branch each and are all called from
    // `step`, i.e. once per emulated instruction; `inline` keeps them out of
    // the call path where a profile found them.
    inline fn cyclesPerScanline(self: *const Self) u32 {
        return if (self.is_ntsc) ntsc_cycles_per_scanline else pal_cycles_per_scanline;
    }

    inline fn scanlinesPerFrame(self: *const Self) u32 {
        const base = if (self.is_ntsc) ntsc_scanlines_per_frame else pal_scanlines_per_frame;
        const interlace = (self.disp_env.display_mode >> 5) & 1;
        if (interlace == 1) {
            // An interlaced field alternates length — 263/262 lines NTSC,
            // 314/313 PAL. The base constant is the odd field; the even field
            // is one line shorter, which is the half-scanline offset.
            return if (self.is_even_field) base - 1 else base;
        }
        return base;
    }

    inline fn vblankStartLine(self: *const Self) u32 {
        return if (self.is_ntsc) ntsc_vblank_start_line else pal_vblank_start_line;
    }

    inline fn dotclockDivider(self: *const Self) u32 {
        return self.disp_env.getDotclockDivider();
    }
};
