//! The seam between GP0 command decode and the renderer.
//!
//! gp0.zig no longer imports `Renderer` and no longer calls `Vram`'s mutators:
//! every VRAM-visible effect goes through a Sink method, which builds the
//! record and then executes it. That is a structural guarantee rather than a
//! convention — with the import gone, a new primitive CANNOT be added without
//! appearing in the recorded stream, which is the assumption every later phase
//! of the Metal renderer rests on.

const std = @import("std");
const gpu_options = @import("gpu_options");
const Vram = @import("vram.zig").Vram;
const DrawingEnv = @import("registers.zig").DrawingEnv;
const command = @import("command.zig");
const recorder = @import("recorder.zig");

pub const Sink = struct {
    /// Declared on the struct rather than at file scope so a frontend or a
    /// test can ask `ps1_core.gpu.Sink.kind` without a second re-export.
    pub const kind = gpu_options.gpu_sink;

    /// Zero-sized in a software build, so Bus does not grow by the recorder's
    /// several megabytes for the frontends that never ask for a stream.
    pub const Storage = if (kind == .software) struct {} else recorder.Recorder;

    rec: Storage = .{},

    /// The one place a command becomes an effect. Recording and rasterizing
    /// see the SAME record, so a field the sink forgets to fill is a field the
    /// rasterizer does not get either.
    fn submit(self: *Sink, vram: *Vram, env: *DrawingEnv, cmd: command.Command) void {
        if (comptime Sink.kind == .dual) self.rec.push(cmd);
        command.execute(cmd, &.{}, vram, env);
    }

    pub fn drawTriangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x0: i16,
        y0: i16,
        x1: i16,
        y1: i16,
        x2: i16,
        y2: i16,
        color: u16,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_triangle,
            .transparent = @intFromBool(is_transparent),
            .value = color,
            .v = .{
                .{ .x = x0, .y = y0 },
                .{ .x = x1, .y = y1 },
                .{ .x = x2, .y = y2 },
            },
        });
    }

    pub fn drawShadedTriangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x0: i16,
        y0: i16,
        c0: u32,
        x1: i16,
        y1: i16,
        c1: u32,
        x2: i16,
        y2: i16,
        c2: u32,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_shaded_triangle,
            .transparent = @intFromBool(is_transparent),
            .v = .{
                .{ .x = x0, .y = y0, .color = c0 },
                .{ .x = x1, .y = y1, .color = c1 },
                .{ .x = x2, .y = y2, .color = c2 },
            },
        });
    }

    pub fn drawTexturedTriangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
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
        self.submit(vram, env, .{
            .kind = .draw_textured_triangle,
            .opcode = opcode,
            .transparent = @intFromBool(allow_transparency),
            .value = color,
            .clut = clut,
            .tpage = tpage,
            .v = .{
                .{ .x = x0, .y = y0, .u = tu0, .v = tv0 },
                .{ .x = x1, .y = y1, .u = tu1, .v = tv1 },
                .{ .x = x2, .y = y2, .u = tu2, .v = tv2 },
            },
        });
    }

    pub fn drawRectangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: i16,
        y: i16,
        w: i32,
        h: i32,
        color: u16,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_rectangle,
            .transparent = @intFromBool(is_transparent),
            .value = color,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
        });
    }

    pub fn drawTexturedRectangle(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: i16,
        y: i16,
        w: i32,
        h: i32,
        tu: u8,
        tv: u8,
        color: u16,
        clut: u16,
        tpage: u16,
        allow_transparency: bool,
        opcode: u8,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_textured_rectangle,
            .opcode = opcode,
            .transparent = @intFromBool(allow_transparency),
            .value = color,
            .clut = clut,
            .tpage = tpage,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .v = .{ .{ .u = tu, .v = tv }, .{}, .{} },
        });
    }

    pub fn drawLine(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x0: i16,
        y0: i16,
        x1: i16,
        y1: i16,
        color: u16,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_line,
            .transparent = @intFromBool(is_transparent),
            .value = color,
            .v = .{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 }, .{} },
        });
    }

    pub fn drawShadedLine(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x0: i16,
        y0: i16,
        c0: u32,
        x1: i16,
        y1: i16,
        c1: u32,
        is_transparent: bool,
    ) void {
        self.submit(vram, env, .{
            .kind = .draw_shaded_line,
            .transparent = @intFromBool(is_transparent),
            .v = .{
                .{ .x = x0, .y = y0, .color = c0 },
                .{ .x = x1, .y = y1, .color = c1 },
                .{},
            },
        });
    }

    pub fn setDrawEnv(self: *Sink, vram: *Vram, env: *DrawingEnv, opcode: u8, value: u32) void {
        self.submit(vram, env, .{ .kind = .set_draw_env, .opcode = opcode, .value = value });
    }

    pub fn latchTexpage(self: *Sink, vram: *Vram, env: *DrawingEnv, tpage: u16) void {
        self.submit(vram, env, .{ .kind = .latch_texpage, .tpage = tpage });
    }

    pub fn setTextureDisableAllowed(self: *Sink, vram: *Vram, env: *DrawingEnv, allowed: bool) void {
        self.submit(vram, env, .{
            .kind = .set_texture_disable_allowed,
            .value = @intFromBool(allowed),
        });
    }

    pub fn resetDrawEnv(self: *Sink, vram: *Vram, env: *DrawingEnv) void {
        self.submit(vram, env, .{ .kind = .reset_draw_env });
    }

    pub fn fillRect(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: i16,
        y: i16,
        w: i16,
        h: i16,
        color: u16,
    ) void {
        self.submit(vram, env, .{
            .kind = .fill_rect,
            .value = color,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
        });
    }

    pub fn copyRect(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        sx: u16,
        sy: u16,
        dx: u16,
        dy: u16,
        w: u16,
        h: u16,
    ) void {
        self.submit(vram, env, .{
            .kind = .copy_rect,
            .x = sx,
            .y = sy,
            .x2 = dx,
            .y2 = dy,
            .w = w,
            .h = h,
        });
    }

    pub fn vramWriteSetup(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: usize,
        y: usize,
        w: usize,
        h: usize,
    ) void {
        self.submit(vram, env, .{
            .kind = .vram_write_setup,
            .x = @intCast(x),
            .y = @intCast(y),
            .w = @intCast(w),
            .h = @intCast(h),
        });
    }

    /// The payload word does not go through `submit`: the recorder's run
    /// coalescing and the one-word slice `execute` needs do not line up.
    pub fn vramWriteData(self: *Sink, vram: *Vram, env: *DrawingEnv, value: u32) void {
        if (comptime Sink.kind == .dual) self.rec.pushVramWriteData(value);
        const words = [_]u32{value};
        command.execute(.{ .kind = .vram_write_data, .x = 0, .y = 1 }, &words, vram, env);
    }

    pub fn vramWriteAbort(self: *Sink, vram: *Vram, env: *DrawingEnv) void {
        self.submit(vram, env, .{ .kind = .vram_write_abort });
    }

    pub fn vramReadSetup(
        self: *Sink,
        vram: *Vram,
        env: *DrawingEnv,
        x: usize,
        y: usize,
        w: usize,
        h: usize,
    ) void {
        self.submit(vram, env, .{
            .kind = .vram_read_setup,
            .x = @intCast(x),
            .y = @intCast(y),
            .w = @intCast(w),
            .h = @intCast(h),
        });
    }
};
