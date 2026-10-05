//! The GPU section: VRAM, the transfer windows, both environments, the GP0
//! command engine, the 16-word FIFO and the deferred-tick bookkeeping.
//!
//! The deferral fields are saved as they are rather than settled first, so a
//! state can be taken at any instruction and resumed bit-for-bit. Absent on
//! purpose: the PGXP depth plane and every `pgxp`/weld/vertex-cache field
//! (caches, rebuilt within a frame or two), and `sink` (host capture state —
//! the app re-adopts core VRAM into Metal when a new display claims the
//! stream). The transfer mirror on `sink` is not saved either: it is rebuilt
//! from the `Vram` fields it mirrors.

const std = @import("std");
const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Gpu = @import("../gpu/gpu.zig").Gpu;

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveGpu(cpu: *const Cpu, w: *Writer) Error!void {
    const g = &cpu.bus.gpu;
    const v = &g.vram;
    try w.array(&v.data);
    try w.flag(v.write_active);
    try w.int(v.write_x);
    try w.int(v.write_y);
    try w.int(v.write_w);
    try w.int(v.write_h);
    try w.int(v.write_curr_x);
    try w.int(v.write_curr_y);
    try w.int(v.write_remaining);
    try w.flag(v.read_active);
    try w.int(v.read_x);
    try w.int(v.read_y);
    try w.int(v.read_w);
    try w.int(v.read_h);
    try w.int(v.read_curr_x);
    try w.int(v.read_curr_y);
    try w.int(v.read_remaining);

    try w.int(g.draw_env.draw_mode);
    try w.int(g.draw_env.tex_window);
    try w.int(g.draw_env.area_top_left);
    try w.int(g.draw_env.area_bot_right);
    try w.int(g.draw_env.offset);
    try w.int(g.draw_env.mask_bit);
    try w.flag(g.draw_env.texture_disable_allowed);

    try w.int(g.disp_env.vram_x_start);
    try w.int(g.disp_env.vram_y_start);
    try w.int(g.disp_env.screen_x1);
    try w.int(g.disp_env.screen_x2);
    try w.int(g.disp_env.screen_y1);
    try w.int(g.disp_env.screen_y2);
    try w.int(g.disp_env.display_mode);
    try w.flag(g.disp_env.display_disabled);

    try w.array(&g.gp0.cmd_buffer);
    try w.int(g.gp0.words_remaining);
    try w.int(g.gp0.words_read);
    try w.flag(g.gp0.polyline_active);
    try w.flag(g.gp0.polyline_shaded);
    try w.int(g.gp0.polyline_count);
    try w.flag(g.gp0.polyline_transparent);
    try w.int(g.gp0.polyline_prev_x);
    try w.int(g.gp0.polyline_prev_y);
    try w.int(g.gp0.polyline_prev_color);
    try w.int(g.gp0.polyline_next_color);

    try w.tag(g.gpu_read_mode);
    try w.int(g.gpu_read_data);
    try w.int(g.dma_direction);
    try w.flag(g.interrupt_flag);
    try w.flag(g.is_vblank);
    try w.flag(g.is_ntsc);
    try w.int(g.h_count);
    try w.int(g.v_count);
    try w.int(g.dotclock_count);
    try w.flag(g.prev_interrupt_flag);
    try w.flag(g.is_even_field);
    try w.array(&g.fifo);
    try w.int(g.fifo_head);
    try w.int(g.fifo_tail);
    try w.int(g.fifo_count);
    try w.int(g.cycle_debt);
    try w.int(g.pending_cycles);
    try w.int(g.event_countdown);
    try w.flag(g.eager);
}

pub fn loadGpu(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const g = &cpu.bus.gpu;
    const v = &g.vram;
    try r.array(&v.data);
    v.write_active = try r.flag();
    v.write_x = try r.int(usize);
    v.write_y = try r.int(usize);
    v.write_w = try r.int(usize);
    v.write_h = try r.int(usize);
    v.write_curr_x = try r.int(usize);
    v.write_curr_y = try r.int(usize);
    v.write_remaining = try r.int(usize);
    v.read_active = try r.flag();
    v.read_x = try r.int(usize);
    v.read_y = try r.int(usize);
    v.read_w = try r.int(usize);
    v.read_h = try r.int(usize);
    v.read_curr_x = try r.int(usize);
    v.read_curr_y = try r.int(usize);
    v.read_remaining = try r.int(usize);
    g.sink.transfer = .fromVram(v);

    g.draw_env.draw_mode = try r.int(u32);
    g.draw_env.tex_window = try r.int(u32);
    g.draw_env.area_top_left = try r.int(u32);
    g.draw_env.area_bot_right = try r.int(u32);
    g.draw_env.offset = try r.int(u32);
    g.draw_env.mask_bit = try r.int(u32);
    g.draw_env.texture_disable_allowed = try r.flag();

    g.disp_env.vram_x_start = try r.int(u16);
    g.disp_env.vram_y_start = try r.int(u16);
    g.disp_env.screen_x1 = try r.int(u16);
    g.disp_env.screen_x2 = try r.int(u16);
    g.disp_env.screen_y1 = try r.int(u16);
    g.disp_env.screen_y2 = try r.int(u16);
    g.disp_env.display_mode = try r.int(u32);
    g.disp_env.display_disabled = try r.flag();

    try r.array(&g.gp0.cmd_buffer);
    g.gp0.words_remaining = try r.int(usize);
    g.gp0.words_read = try r.int(usize);
    g.gp0.polyline_active = try r.flag();
    g.gp0.polyline_shaded = try r.flag();
    g.gp0.polyline_count = try r.int(usize);
    g.gp0.polyline_transparent = try r.flag();
    g.gp0.polyline_prev_x = try r.int(i16);
    g.gp0.polyline_prev_y = try r.int(i16);
    g.gp0.polyline_prev_color = try r.int(u32);
    g.gp0.polyline_next_color = try r.int(u32);

    g.gpu_read_mode = try r.tag(Gpu.ReadMode);
    g.gpu_read_data = try r.int(u32);
    g.dma_direction = try r.int(u2);
    g.interrupt_flag = try r.flag();
    g.is_vblank = try r.flag();
    g.is_ntsc = try r.flag();
    g.h_count = try r.int(u32);
    g.v_count = try r.int(u32);
    g.dotclock_count = try r.int(u32);
    g.prev_interrupt_flag = try r.flag();
    g.is_even_field = try r.flag();
    try r.array(&g.fifo);
    g.fifo_head = try r.int(u4);
    g.fifo_tail = try r.int(u4);
    g.fifo_count = try r.int(u5);
    if (g.fifo_count > g.fifo.len) return error.StateCorrupt;
    g.cycle_debt = try r.int(i32);
    g.pending_cycles = try r.int(u32);
    g.event_countdown = try r.int(i64);
    g.eager = try r.flag();
}
