const std = @import("std");
pub const Vram = @import("vram.zig").Vram;
pub const Regs = @import("registers.zig");
pub const Gp0Engine = @import("gp0.zig").Gp0Engine;
pub const Renderer = @import("renderer.zig").Renderer;
pub const Color = @import("color.zig");
pub const command = @import("command.zig");
pub const depth = @import("depth.zig");
pub const primitive = @import("primitive.zig");
pub const recorder = @import("recorder.zig");
pub const Sink = @import("sink.zig").Sink;
pub const Recorder = @import("recorder.zig").Recorder;
pub const RasterWorker = @import("worker.zig").RasterWorker;
pub const raster_worker_available = @import("worker.zig").available;
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

    fifo: [16]u32 = @splat(0),
    /// Provenance, indexed by the same head/tail as `fifo`.
    ///
    /// A single pending slot on `Bus` is NOT enough and this is why: the FIFO
    /// is 16 words deep and drains against `cycle_debt`, so a word can sit
    /// here for thousands of cycles while fifteen more are pushed behind it.
    fifo_pgxp: [16]Value = @splat(.{}),
    fifo_head: u4 = 0,
    fifo_tail: u4 = 0,
    fifo_count: u5 = 0,
    cycle_debt: i32 = 0,

    /// Video cycles stepped past without applying them, and the video cycles
    /// until the earliest thing `stepEvents` does — the guard `cdrom.zig`
    /// carries, for the same reason; its `pending_cycles` holds the rules.
    ///
    /// The GPU is safe to defer because `is_vblank`, `v_count` and
    /// `is_even_field` change ONLY at a scanline boundary and `nextDeadline`
    /// never reaches past one. `ps1_run_frame` and the wasm frame loop poll
    /// `is_vblank` directly, never through MMIO, and need no `catchUp`.
    pending_cycles: u32 = 0,
    event_countdown: i64 = 0,

    /// Suspends the guard while timer 0 counts the dotclock. `step` RETURNS
    /// the dotclock ticks it consumes, and a batched count is not
    /// interchangeable with a stream of small ones once the timer crosses
    /// its target. Maintained by the timer-mode write in `memory.zig`, the
    /// only thing that can change it.
    ///
    /// Timer 1 on the hblank clock does NOT need it, and must not have it:
    /// libetc's VSync runs timer 1 that way, so nearly every game would keep
    /// the GPU eager forever. The hblank tick is raised only on the step
    /// that crosses a scanline boundary, and the deadline stops on exactly
    /// that step, so a deferred GPU hands timer 1 the identical sequence.
    eager: bool = false,

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

    /// Moves the software rasterizer onto a worker. Draws, fills, copies and
    /// uploads then land when the worker gets to them, and everything that
    /// reads `vram` on this thread must `syncRaster` first.
    pub fn attachRasterWorker(self: *Self, allocator: std.mem.Allocator, io: std.Io, mode: RasterWorker.Mode) !void {
        std.debug.assert(self.sink.worker == null);
        self.sink.worker = try RasterWorker.create(allocator, io, &self.vram, self.draw_env, mode);
    }

    /// Drains and stops the worker. A no-op without one.
    pub fn detachRasterWorker(self: *Self) void {
        const w = self.sink.worker orelse return;
        w.destroy();
        self.sink.worker = null;
    }

    /// Waits until the worker has executed everything queued. A no-op
    /// without one, so callers need not ask.
    pub fn syncRaster(self: *Self) void {
        const w = self.sink.worker orelse return;
        w.sync();
        if (std.debug.runtime_safety) std.debug.assert(self.sink.transfer.matches(&self.vram));
    }

    /// Three instructions in the steady state; the body runs once per
    /// scanline, or every step while the GP0 FIFO holds a word.
    pub inline fn step(self: *Self, delta_cycles: u32) GpuStepResult {
        self.pending_cycles += delta_cycles;
        self.event_countdown -= delta_cycles;
        if (self.event_countdown > 0) return .{};
        return self.stepEvents(delta_cycles);
    }

    /// Advances the free-running counters by `elapsed` and fires nothing.
    ///
    /// Sound only because no scanline boundary falls inside the skipped
    /// window and the FIFO was empty throughout it — `nextDeadline` refuses
    /// to defer otherwise. `cycle_debt` still drains: a large draw leaves
    /// debt behind an empty FIFO, and `writeGp0` reads it directly. The
    /// dotclock is reduced by the divider in force across the window, which
    /// a GP1(08h) write may change the moment `catchUp` returns.
    fn applyElapsed(self: *Self, elapsed: u32) void {
        if (elapsed == 0) return;
        self.cycle_debt = @max(self.cycle_debt - @as(i32, @intCast(elapsed)), 0);
        self.dotclock_count = (self.dotclock_count + elapsed) % self.dotclockDivider();
        self.h_count += elapsed;
    }

    fn nextDeadline(self: *const Self) i64 {
        if (self.eager or self.fifo_count > 0) return 1;
        return @max(@as(i64, self.cyclesPerScanline()) - @as(i64, self.h_count), 1);
    }

    /// Applies everything `step` deferred, without firing anything. Re-arms
    /// FIRST and unconditionally: the caller is about to touch a register,
    /// and a deadline derived from the state before that write would stand.
    ///
    /// `readData`, `writeGp0` and `writeGp1` call it themselves, so every
    /// caller — the bus, DMA, a test driving a bare `Gpu` — is covered.
    /// `readStatus` is `const` and is settled by the bus.
    pub fn catchUp(self: *Self) void {
        self.event_countdown = 0;
        self.applyElapsed(self.pending_cycles);
        self.pending_cycles = 0;
    }

    /// The per-instruction body, run once a deadline comes due.
    /// `delta_cycles` is THIS step's cycles, not the batch.
    fn stepEvents(self: *Self, delta_cycles: u32) GpuStepResult {
        @branchHint(.cold);
        self.applyElapsed(self.pending_cycles - delta_cycles);
        self.pending_cycles = 0;

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
            }
        }

        self.is_vblank = self.v_count >= self.vblankStartLine();
        self.prev_interrupt_flag = self.interrupt_flag;

        self.event_countdown = self.nextDeadline();
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

        // Bit 26 is "idle", not "FIFO has room": it stays clear while a draw
        // is still being paid for. A game that waits to SEE the GPU busy after
        // queuing a primitive spins forever on a GPU that never is.
        if (self.fifo_count == 0 and self.cycle_debt <= 0) stat |= (1 << 26);
        if (vram_read_pending) stat |= (1 << 27); // Ready to send VRAM to CPU

        // Bit 28: words wait in the FIFO only behind an unpaid draw, and the
        // GPU takes no more commands while they do. An upload streams until
        // the FIFO is full.
        const dma_ready = if (self.sink.transfer.writeActive()) self.fifo_count < 16 else self.fifo_count == 0;
        if (dma_ready) stat |= (1 << 28);

        stat |= (@as(u32, self.dma_direction) << 29);

        // Bit 31: Drawing even/odd lines in interlaced mode (0=Even or Vblank, 1=Odd)
        if (self.is_even_field and interlace == 1 and !self.is_vblank) stat |= (1 << 31);

        return stat;
    }

    /// GPUREAD returns VRAM data only while a GP0(C0) transfer is actually
    /// in flight; draining it, a
    /// GP1(10h..1Fh) info request, and power-on all leave the register selected.
    fn vramReadPending(self: *const Self) bool {
        return self.gpu_read_mode == .Vram and self.sink.transfer.readActive();
    }

    pub fn readData(self: *Self) u32 {
        self.catchUp();
        if (!self.vramReadPending()) {
            return self.gpu_read_data;
        }
        self.syncRaster();
        self.sink.transfer.wordRead();
        const word = self.vram.readData();
        self.sink.checkSettled(&self.vram);
        return word;
    }

    pub fn writeGp0(self: *Self, value: u32, p: Value) u32 {
        self.catchUp();
        var stall_cycles: u32 = 0;

        if (self.fifo_count == 16) {
            if (self.cycle_debt > 0) {
                // The debt is video cycles; the caller bills CPU cycles.
                stall_cycles = @intCast(@divTrunc(self.cycle_debt * 7, 11));
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
        if (self.sink.transfer.readActive()) self.gpu_read_mode = .Vram;
    }

    pub fn writeGp1(self: *Self, value: u32) void {
        self.catchUp();
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
