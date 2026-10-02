const std = @import("std");
const ps1 = @import("ps1_core");
const savestate = ps1.savestate;
const stream = savestate.stream;
const cpu_state = savestate.cpu_state;
const io_state = savestate.io_state;
const gpu_state = savestate.gpu_state;
const spu_state = savestate.spu_state;
const cdrom_state = savestate.cdrom_state;

test "ints round-trip at their wire width, little-endian" {
    var buf: [64]u8 = undefined;
    var w = stream.Writer{ .buf = &buf };
    try w.int(@as(u5, 17));
    try w.int(@as(i16, -2));
    try w.int(@as(u32, 0xDEADBEEF));
    try w.int(@as(i64, -5));
    try w.int(@as(usize, 7));
    // u5 -> 1 byte, i16 -> 2, u32 -> 4, i64 -> 8, usize -> 8 (always u64 on the wire)
    try std.testing.expectEqual(@as(usize, 1 + 2 + 4 + 8 + 8), w.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, buf[3..7]);

    var r = stream.Reader{ .buf = buf[0..w.len] };
    try std.testing.expectEqual(@as(u5, 17), try r.int(u5));
    try std.testing.expectEqual(@as(i16, -2), try r.int(i16));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.int(u32));
    try std.testing.expectEqual(@as(i64, -5), try r.int(i64));
    try std.testing.expectEqual(@as(usize, 7), try r.int(usize));
    try r.end();
}

test "a counting writer measures without writing" {
    var w = stream.Writer{};
    try w.int(@as(u32, 1));
    try w.array(&[_]i16{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 4 + 6), w.len);
}

test "a full buffer is NoSpace, not an overrun" {
    var buf: [3]u8 = undefined;
    var w = stream.Writer{ .buf = &buf };
    try std.testing.expectError(error.NoSpace, w.int(@as(u32, 1)));
}

test "out-of-range narrow ints, bools and enums are StateCorrupt" {
    const E = enum(u8) { a = 0, b = 5 };
    var r = stream.Reader{ .buf = &.{0x20} }; // 32 does not fit a u5
    try std.testing.expectError(error.StateCorrupt, r.int(u5));
    r = .{ .buf = &.{2} };
    try std.testing.expectError(error.StateCorrupt, r.flag());
    r = .{ .buf = &.{ 3, 0, 0, 0 } }; // 3 is not a value of E
    try std.testing.expectError(error.StateCorrupt, r.tag(E));
    r = .{ .buf = &.{ 5, 0, 0, 0 } };
    try std.testing.expectEqual(E.b, try r.tag(E));
}

test "reading past the end, or stopping short of it, is StateCorrupt" {
    var r = stream.Reader{ .buf = &.{ 1, 2 } };
    try std.testing.expectError(error.StateCorrupt, r.int(u32));
    r = .{ .buf = &.{ 1, 2 } };
    _ = try r.int(u8);
    try std.testing.expectError(error.StateCorrupt, r.end());
}

test "arrays of wide elements round-trip" {
    const src = [_]f32{ 1.5, -2.25, 0 };
    var buf: [12]u8 = undefined;
    var w = stream.Writer{ .buf = &buf };
    try w.array(&src);
    var dst: [3]f32 = undefined;
    var r = stream.Reader{ .buf = &buf };
    try r.array(&dst);
    try std.testing.expectEqualSlices(f32, &src, &dst);
}

test "patchU32 rewrites in place and is a no-op when counting" {
    var buf: [8]u8 = [_]u8{0} ** 8;
    var w = stream.Writer{ .buf = &buf };
    try w.int(@as(u32, 0));
    try w.int(@as(u32, 9));
    w.patchU32(0, 0x01020304);
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, buf[0..4]);
    var counting = stream.Writer{};
    try counting.int(@as(u32, 0));
    counting.patchU32(0, 5); // must not crash
}
const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;

const Machine = struct {
    bus: *Bus,
    cpu: Cpu,

    fn init() !Machine {
        const bus = try Bus.init(std.testing.allocator);
        return .{ .bus = bus, .cpu = Cpu.init(bus) };
    }

    fn deinit(m: *Machine) void {
        m.bus.deinit(std.testing.allocator);
    }
};

fn roundTrip(
    src: *Machine,
    dst: *Machine,
    comptime save: fn (*const Cpu, *stream.Writer) stream.Error!void,
    comptime load: fn (*Cpu, *stream.Reader, u32) stream.Error!void,
) !void {
    var counter = stream.Writer{};
    try save(&src.cpu, &counter);
    const buf = try std.testing.allocator.alloc(u8, counter.len);
    defer std.testing.allocator.free(buf);
    var w = stream.Writer{ .buf = buf };
    try save(&src.cpu, &w);
    var r = stream.Reader{ .buf = buf };
    try load(&dst.cpu, &r, 1);
    try r.end();
}

test "cpu section restores registers, pipeline, load delay, icache, cop0 and cop2" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    a.cpu.regs[5] = 0x12345678;
    a.cpu.pipeline.pc = 0x80010000;
    a.cpu.pipeline.next_pc = 0x80010004;
    a.cpu.pipeline.current_pc = 0x8000FFFC;
    a.cpu.pipeline.is_delay_slot = true;
    a.cpu.pipeline.next_is_delay_slot = true;
    a.cpu.load_delay.load_r = 7;
    a.cpu.load_delay.load_v = 0xAA;
    a.cpu.load_delay.delay_r = 9;
    a.cpu.load_delay.delay_v = 0xBB;
    a.cpu.hi = 1;
    a.cpu.lo = 2;
    a.cpu.cycles = 123456789;
    a.cpu.gpu_clock_frac = 5;
    a.cpu.icache[3].tag = 0x40;
    a.cpu.icache[3].data[2] = 0x99;
    a.cpu.cop0.regs[12] = 0x10000;
    a.cpu.cop2.data_regs[1] = 77;
    a.cpu.cop2.ctrl_regs[31] = 0x80000000;
    a.cpu.cop2.macs[2] = -40000000000;

    try roundTrip(&a, &b, cpu_state.saveCpu, cpu_state.loadCpu);

    try std.testing.expectEqualDeep(a.cpu.regs, b.cpu.regs);
    try std.testing.expectEqualDeep(a.cpu.pipeline, b.cpu.pipeline);
    try std.testing.expectEqualDeep(a.cpu.load_delay, b.cpu.load_delay);
    try std.testing.expectEqual(a.cpu.hi, b.cpu.hi);
    try std.testing.expectEqual(a.cpu.lo, b.cpu.lo);
    try std.testing.expectEqual(a.cpu.cycles, b.cpu.cycles);
    try std.testing.expectEqual(a.cpu.gpu_clock_frac, b.cpu.gpu_clock_frac);
    try std.testing.expectEqualDeep(a.cpu.icache, b.cpu.icache);
    try std.testing.expectEqualDeep(a.cpu.cop0.regs, b.cpu.cop0.regs);
    try std.testing.expectEqualDeep(a.cpu.cop2.data_regs, b.cpu.cop2.data_regs);
    try std.testing.expectEqualDeep(a.cpu.cop2.ctrl_regs, b.cpu.cop2.ctrl_regs);
    try std.testing.expectEqualDeep(a.cpu.cop2.macs, b.cpu.cop2.macs);
}

test "bus section restores RAM, scratchpad, io ports, expansion 2/3 and the clocks" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    a.bus.ram[0x1234] = 0x5A;
    a.bus.scratchpad[10] = 0x11;
    a.bus.io_ports[0x100] = 0x22;
    a.bus.expansion_2[3] = 0x33;
    a.bus.expansion_3[4] = 0x44;
    a.bus.expansion_3_last_write_width = 2;
    a.bus.cache_control[0] = 0x55;
    a.bus.wait_cycles = 6;
    a.bus.sys_clock = 987654321;

    try roundTrip(&a, &b, io_state.saveBus, io_state.loadBus);

    try std.testing.expectEqualSlices(u8, &a.bus.ram, &b.bus.ram);
    try std.testing.expectEqualSlices(u8, &a.bus.scratchpad, &b.bus.scratchpad);
    try std.testing.expectEqualSlices(u8, &a.bus.io_ports, &b.bus.io_ports);
    try std.testing.expectEqualSlices(u8, &a.bus.expansion_2, &b.bus.expansion_2);
    try std.testing.expectEqualSlices(u8, &a.bus.expansion_3, &b.bus.expansion_3);
    try std.testing.expectEqual(a.bus.expansion_3_last_write_width, b.bus.expansion_3_last_write_width);
    try std.testing.expectEqualSlices(u8, &a.bus.cache_control, &b.bus.cache_control);
    try std.testing.expectEqual(a.bus.wait_cycles, b.bus.wait_cycles);
    try std.testing.expectEqual(a.bus.sys_clock, b.bus.sys_clock);
}

test "interrupt, timer and dma sections restore every field" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    a.bus.interrupts.stat = 0x5;
    a.bus.interrupts.mask = 0x7FF;
    for (&a.bus.timers, 0..) |*t, i| {
        const n: u32 = @intCast(i + 1);
        t.counter = n;
        t.mode = n * 2;
        t.target = n * 3;
        t.prescale_counter = n * 4;
        t.pending_ticks = n * 5;
        t.event_countdown = -@as(i64, n);
    }
    a.bus.dma.dpcr = 0x12345678;
    a.bus.dma.dicr = 0x00FF0000;
    a.bus.dma.busy_hint = true;
    const c = &a.bus.dma.channels[2];
    c.base_addr = 1;
    c.block_control = 2;
    c.control = 3;
    c.transfer_active = true;
    c.words_remaining = 4;
    c.linked_list_next = 5;
    c.ll_nodes = 6;
    c.chop_dma_window = 7;
    c.chop_cpu_window = 8;
    c.chop_is_cpu_turn = true;
    c.chop_counter = 9;
    c.block_words = 10;
    c.block_word_progress = 11;
    c.block_cycles = 12;
    c.block_gap_counter = 13;

    try roundTrip(&a, &b, io_state.saveIrq, io_state.loadIrq);
    try roundTrip(&a, &b, io_state.saveTimers, io_state.loadTimers);
    try roundTrip(&a, &b, io_state.saveDma, io_state.loadDma);

    try std.testing.expectEqualDeep(a.bus.interrupts, b.bus.interrupts);
    try std.testing.expectEqualDeep(a.bus.timers, b.bus.timers);
    try std.testing.expectEqualDeep(a.bus.dma, b.bus.dma);
}

test "sio section restores protocol state but never the card images" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const io = &a.bus.sio;
    io.stat = 0x123;
    io.mode = 0x4D;
    io.ctrl = 0x1003;
    io.baud = 0x88;
    io.rx_data = 0x41;
    io.ack = true;
    io.irq = true;
    io.irq_timer = 450;
    io.buttons = 0xFFFE;
    io.analog_enabled = true;
    io.port = 1;
    io.joy_rx = 1;
    io.joy_ry = 2;
    io.joy_lx = 3;
    io.joy_ly = 4;
    io.motor_right_small = 5;
    io.motor_left_large = 6;
    io.memcard_staging[1][7] = 0x77;
    io.memcard_address[1] = 0x3F;
    io.memcard_checksum[1] = 0x12;
    io.memcard_step[1] = 9;
    io.memcard_is_write[1] = true;
    io.memcard_flag[1] = 0;
    io.memcard_status[1] = 'E';
    io.memcard_data[0][0] = 0xEE; // must NOT travel
    io.memcard_dirty[0] = true; // must NOT travel

    try roundTrip(&a, &b, io_state.saveSio, io_state.loadSio);

    const got = &b.bus.sio;
    try std.testing.expectEqual(io.stat, got.stat);
    try std.testing.expectEqual(io.mode, got.mode);
    try std.testing.expectEqual(io.ctrl, got.ctrl);
    try std.testing.expectEqual(io.baud, got.baud);
    try std.testing.expectEqual(io.rx_data, got.rx_data);
    try std.testing.expectEqual(io.ctrl_state, got.ctrl_state);
    try std.testing.expectEqual(io.ack, got.ack);
    try std.testing.expectEqual(io.irq, got.irq);
    try std.testing.expectEqual(io.irq_timer, got.irq_timer);
    try std.testing.expectEqual(io.buttons, got.buttons);
    try std.testing.expectEqual(io.analog_enabled, got.analog_enabled);
    try std.testing.expectEqual(io.port, got.port);
    try std.testing.expectEqual(io.joy_ly, got.joy_ly);
    try std.testing.expectEqual(io.motor_left_large, got.motor_left_large);
    try std.testing.expectEqualDeep(io.memcard_staging, got.memcard_staging);
    try std.testing.expectEqualDeep(io.memcard_address, got.memcard_address);
    try std.testing.expectEqualDeep(io.memcard_checksum, got.memcard_checksum);
    try std.testing.expectEqualDeep(io.memcard_step, got.memcard_step);
    try std.testing.expectEqualDeep(io.memcard_is_write, got.memcard_is_write);
    try std.testing.expectEqualDeep(io.memcard_flag, got.memcard_flag);
    try std.testing.expectEqualDeep(io.memcard_status, got.memcard_status);
    try std.testing.expect(got.memcard_data[0][0] != 0xEE);
    try std.testing.expect(!got.memcard_dirty[0]);
}

test "mdec section restores tables, fifos and the block in progress" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const m = &a.bus.mdec;
    m.status = 0x80040000;
    m.quant_luminance[3] = 9;
    m.quant_color[4] = 8;
    m.scale_table[5] = -7;
    m.current_cmd = 0x30000000;
    m.words_remaining = 100;
    m.input_fifo[6] = 0xFE00;
    m.input_len = 7;
    m.y_blocks[2][8] = -300;
    m.cb_block[9] = 1;
    m.cr_block[10] = 2;
    m.output_fifo[11] = 0xABCDEF;
    m.output_ptr = 12;
    m.output_len = 13;
    m.output_depth = 2;
    m.output_set_bit15 = true;

    try roundTrip(&a, &b, io_state.saveMdec, io_state.loadMdec);
    try std.testing.expectEqualDeep(a.bus.mdec, b.bus.mdec);
}

test "gpu section restores vram, transfers, environments, gp0 and the fifo" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const g = &a.bus.gpu;
    g.vram.data[1024 * 100 + 5] = 0x7FFF;
    g.vram.write_active = true;
    g.vram.write_x = 1;
    g.vram.write_y = 2;
    g.vram.write_w = 3;
    g.vram.write_h = 4;
    g.vram.write_curr_x = 5;
    g.vram.write_curr_y = 6;
    g.vram.write_remaining = 7;
    g.vram.read_active = true;
    g.vram.read_x = 8;
    g.vram.read_y = 9;
    g.vram.read_w = 10;
    g.vram.read_h = 11;
    g.vram.read_curr_x = 12;
    g.vram.read_curr_y = 13;
    g.vram.read_remaining = 14;
    g.draw_env.draw_mode = 0x20F;
    g.draw_env.tex_window = 1;
    g.draw_env.area_top_left = 2;
    g.draw_env.area_bot_right = 3;
    g.draw_env.offset = 4;
    g.draw_env.mask_bit = 3;
    g.draw_env.texture_disable_allowed = true;
    g.disp_env.vram_x_start = 320;
    g.disp_env.vram_y_start = 240;
    g.disp_env.screen_x1 = 1;
    g.disp_env.screen_x2 = 2;
    g.disp_env.screen_y1 = 3;
    g.disp_env.screen_y2 = 4;
    g.disp_env.display_mode = 0x11;
    g.disp_env.display_disabled = false;
    g.gp0.cmd_buffer[2] = 0x38000000;
    g.gp0.words_remaining = 5;
    g.gp0.words_read = 3;
    g.gp0.polyline_active = true;
    g.gp0.polyline_shaded = true;
    g.gp0.polyline_count = 4;
    g.gp0.polyline_transparent = true;
    g.gp0.polyline_prev_x = -10;
    g.gp0.polyline_prev_y = 20;
    g.gp0.polyline_prev_color = 0xFF;
    g.gp0.polyline_next_color = 0xFF00;
    g.gpu_read_data = 0x1234;
    g.dma_direction = 2;
    g.interrupt_flag = true;
    g.is_vblank = true;
    g.is_ntsc = false;
    g.h_count = 100;
    g.v_count = 200;
    g.dotclock_count = 300;
    g.prev_interrupt_flag = true;
    g.is_even_field = true;
    g.fifo[3] = 0xCAFE;
    g.fifo_head = 3;
    g.fifo_tail = 4;
    g.fifo_count = 1;
    g.cycle_debt = -50;
    g.pending_cycles = 60;
    g.event_countdown = 70;
    g.eager = true;

    try roundTrip(&a, &b, gpu_state.saveGpu, gpu_state.loadGpu);

    const got = &b.bus.gpu;
    try std.testing.expectEqualSlices(u16, &g.vram.data, &got.vram.data);
    try std.testing.expectEqual(g.vram.write_remaining, got.vram.write_remaining);
    try std.testing.expectEqual(g.vram.read_remaining, got.vram.read_remaining);
    try std.testing.expectEqual(g.vram.read_curr_y, got.vram.read_curr_y);
    try std.testing.expectEqualDeep(g.draw_env, got.draw_env);
    try std.testing.expectEqualDeep(g.disp_env, got.disp_env);
    try std.testing.expectEqualDeep(g.gp0.cmd_buffer, got.gp0.cmd_buffer);
    try std.testing.expectEqual(g.gp0.words_remaining, got.gp0.words_remaining);
    try std.testing.expectEqual(g.gp0.polyline_prev_x, got.gp0.polyline_prev_x);
    try std.testing.expectEqual(g.gp0.polyline_next_color, got.gp0.polyline_next_color);
    try std.testing.expectEqual(g.gpu_read_mode, got.gpu_read_mode);
    try std.testing.expectEqual(g.dma_direction, got.dma_direction);
    try std.testing.expectEqual(g.is_ntsc, got.is_ntsc);
    try std.testing.expectEqual(g.dotclock_count, got.dotclock_count);
    try std.testing.expectEqualDeep(g.fifo, got.fifo);
    try std.testing.expectEqual(g.fifo_count, got.fifo_count);
    try std.testing.expectEqual(g.cycle_debt, got.cycle_debt);
    try std.testing.expectEqual(g.pending_cycles, got.pending_cycles);
    try std.testing.expectEqual(g.event_countdown, got.event_countdown);
    try std.testing.expectEqual(g.eager, got.eager);
}

test "spu section restores sram, voices, reverb, noise, mix and the output ring" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const s = &a.bus.spu;
    s.sram[1000] = 0x42;
    s.main_vol_l = -1;
    s.main_vol_r = 2;
    s.reverb_vol_l = 3;
    s.reverb_vol_r = 4;
    s.spu_cnt = 0xC000;
    s.spu_stat = 5;
    s.sram_addr = 6;
    s.sram_read_buffer = 7;
    s.dtc = 8;
    s.pmon = 9;
    s.non = 10;
    s.von = 11;
    s.noise.timer = -12;
    s.noise.lfsr = 13;
    s.noise.level = 14;
    s.mix.cd_vol_l = 15;
    s.mix.cd_vol_r = 16;
    s.mix.ext_vol_l = 17;
    s.mix.ext_vol_r = 18;
    s.mix.current_cd_l = 19;
    s.mix.current_cd_r = 20;
    s.mix.current_ext_l = 21;
    s.mix.current_ext_r = 22;
    s.irq_addr = 23;
    s.irq_flag = true;
    s.reverb.regs[4] = -24;
    s.reverb.base = 25;
    s.reverb.curr_addr = 26;
    s.reverb.counter = 27;
    s.reverb.out_l = 28;
    s.reverb.out_r = 29;
    const v = &s.voices[7];
    v.regs.vol_l = 30;
    v.regs.pitch = 0x1000;
    v.regs.adsr_vol = -31;
    v.adpcm.current_addr = 32;
    v.adpcm.current_fraction = 33;
    v.adpcm.old = 34;
    v.adpcm.older = 35;
    v.adpcm.decoded_buffer[3] = 36;
    v.adpcm.history[1] = 37;
    v.adpcm.buffer_index = 4;
    v.is_on = true;
    v.ignore_samples = true;
    v.has_reached_endx = true;
    v.env.current_ad_vol = 38;
    v.env.cycles = 39;
    s.output_buffer[40] = 0.5;
    s.write_idx = 41;
    s.read_idx = 42;
    s.cycle_accumulator = 43;

    try roundTrip(&a, &b, spu_state.saveSpu, spu_state.loadSpu);

    const got = &b.bus.spu;
    try std.testing.expectEqualSlices(u8, &s.sram, &got.sram);
    try std.testing.expectEqualDeep(s.noise, got.noise);
    try std.testing.expectEqualDeep(s.mix, got.mix);
    try std.testing.expectEqualDeep(s.reverb, got.reverb);
    try std.testing.expectEqualDeep(s.voices, got.voices);
    try std.testing.expectEqualSlices(f32, &s.output_buffer, &got.output_buffer);
    try std.testing.expectEqual(s.main_vol_l, got.main_vol_l);
    try std.testing.expectEqual(s.dtc, got.dtc);
    try std.testing.expectEqual(s.von, got.von);
    try std.testing.expectEqual(s.irq_flag, got.irq_flag);
    try std.testing.expectEqual(s.write_idx, got.write_idx);
    try std.testing.expectEqual(s.read_idx, got.read_idx);
    try std.testing.expectEqual(s.cycle_accumulator, got.cycle_accumulator);
}

test "cdrom section restores drive, fifos, irq queue, audio and xa state" {
    var a = try Machine.init();
    defer a.deinit();
    var b = try Machine.init();
    defer b.deinit();

    const cd = &a.bus.cdrom;
    cd.regs.index = 2;
    cd.regs.irq_enable = 7;
    cd.regs.busy_for = -3;
    cd.regs.last_response_byte = 4;
    cd.regs.volume_ll = 5;
    cd.regs.volume_lr = 6;
    cd.regs.volume_rl = 7;
    cd.regs.volume_rr = 8;
    cd.fifos.parameter_fifo[1] = 9;
    cd.fifos.parameter_len = 2;
    cd.fifos.irq_line = true;
    cd.fifos.last_raw_sector[100] = 10;
    cd.fifos.sector_buffer[200] = 11;
    cd.fifos.sector_buffer_ptr = 12;
    cd.fifos.sector_buffer_len = 2340;
    cd.fifos.data_fifo_empty = false;
    cd.fifos.irq_queue.head = 1;
    cd.fifos.irq_queue.tail = 2;
    cd.fifos.irq_queue.count = 1;
    cd.fifos.irq_queue.overflow_count = 3;
    cd.fifos.irq_queue.items[1] = .{ .irq = 3, .response_len = 1, .response_ptr = 0, .delay = 50000, .ack = true, .triggered = true, .auto_status = true };
    cd.fifos.irq_queue.items[1].response[0] = 0x22;
    cd.drive.drive_state = .Reading;
    cd.drive.sector_timer = 13;
    cd.drive.seek_timer = 14;
    cd.drive.read_after_seek = true;
    cd.drive.status = 0x22;
    cd.drive.mode = 0x80;
    cd.drive.seek_target = .{ .m = 0x01, .s = 0x02, .f = 0x03 };
    cd.drive.current_pos = .{ .m = 0x04, .s = 0x05, .f = 0x06 };
    cd.drive.loc_l_valid = true;
    cd.drive.muted = true;
    cd.drive.shell_open = true;
    cd.drive.shell_changed = true;
    cd.drive.shell_close_timer = 15;
    cd.drive.last_sector_header[2] = 16;
    cd.drive.last_subchannel_q[3] = 17;
    cd.drive.sectors_delivered = 18;
    cd.drive.previous_track = 2;
    cd.audio.audio_fifo_l[5] = -19;
    cd.audio.audio_fifo_r[6] = 20;
    cd.audio.audio_fifo_read = 21;
    cd.audio.audio_fifo_write = 22;
    cd.audio.audio_tick_counter = 23;
    cd.xa.xa_filter_file = 1;
    cd.xa.xa_filter_channel = 2;
    cd.xa.xa_old_l = 24;
    cd.xa.xa_older_l = 25;
    cd.xa.xa_old_r = 26;
    cd.xa.xa_older_r = 27;
    cd.xa.xa_ringbuf[1][4] = 28;
    cd.xa.xa_ring_p = .{ 29, 30 };
    cd.xa.xa_sixstep = .{ 3, 4 };
    cd.pending_command = 0x1B;
    cd.pending_command_delay = 31;
    cd.pending_cycles = 32;
    cd.event_countdown = 33;

    try roundTrip(&a, &b, cdrom_state.saveCdrom, cdrom_state.loadCdrom);

    const got = &b.bus.cdrom;
    try std.testing.expectEqualDeep(cd.regs, got.regs);
    try std.testing.expectEqualDeep(cd.fifos, got.fifos);
    try std.testing.expectEqualDeep(cd.drive, got.drive);
    try std.testing.expectEqualDeep(cd.audio, got.audio);
    try std.testing.expectEqualDeep(cd.xa, got.xa);
    try std.testing.expectEqual(cd.pending_command, got.pending_command);
    try std.testing.expectEqual(cd.pending_command_delay, got.pending_command_delay);
    try std.testing.expectEqual(cd.pending_cycles, got.pending_cycles);
    try std.testing.expectEqual(cd.event_countdown, got.event_countdown);
}

fn saveAlloc(m: *Machine) ![]u8 {
    const n = try savestate.save(&m.cpu, null);
    const buf = try std.testing.allocator.alloc(u8, n);
    errdefer std.testing.allocator.free(buf);
    try std.testing.expectEqual(n, try savestate.save(&m.cpu, buf));
    return buf;
}

test "a whole state round-trips and peeks its identity" {
    var a = try Machine.init();
    defer a.deinit();
    @memset(&a.bus.bios, 0x5A);
    a.bus.ram[42] = 42;
    a.cpu.regs[3] = 3;
    a.bus.gpu.vram.data[7] = 7;

    const buf = try saveAlloc(&a);
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqualSlices(u8, "SBST", buf[0..4]);

    const id = try savestate.peek(buf);
    try std.testing.expectEqualDeep(savestate.identityOf(a.bus), id);

    var b = try Machine.init();
    defer b.deinit();
    @memset(&b.bus.bios, 0x5A);
    try savestate.load(&b.cpu, buf);
    try std.testing.expectEqual(@as(u8, 42), b.bus.ram[42]);
    try std.testing.expectEqual(@as(u32, 3), b.cpu.regs[3]);
    try std.testing.expectEqual(@as(u16, 7), b.bus.gpu.vram.data[7]);
}

test "hostile states are refused with their own error" {
    var a = try Machine.init();
    defer a.deinit();
    const buf = try saveAlloc(&a);
    defer std.testing.allocator.free(buf);

    var b = try Machine.init();
    defer b.deinit();

    const copy = try std.testing.allocator.dupe(u8, buf);
    defer std.testing.allocator.free(copy);

    // Bad magic.
    @memcpy(copy, buf);
    copy[0] = 'X';
    try std.testing.expectError(error.StateBadMagic, savestate.load(&b.cpu, copy));

    // A newer container version.
    @memcpy(copy, buf);
    std.mem.writeInt(u32, copy[4..8], savestate.format_version + 1, .little);
    try std.testing.expectError(error.StateVersion, savestate.load(&b.cpu, copy));

    // One flipped body byte fails the CRC.
    @memcpy(copy, buf);
    copy[savestate.header_len + 100] ^= 0xFF;
    try std.testing.expectError(error.StateCorrupt, savestate.load(&b.cpu, copy));

    // Truncation, at every one of a spread of points.
    var cut: usize = 1;
    while (cut < buf.len) : (cut += buf.len / 17) {
        // A cut into the header reads as no state at all; anywhere else, as corrupt.
        if (savestate.load(&b.cpu, buf[0 .. buf.len - cut])) |_| {
            return error.TestUnexpectedSuccess;
        } else |e| {
            try std.testing.expect(e == error.StateCorrupt or e == error.StateBadMagic);
        }
    }

    // A different BIOS.
    @memset(&b.bus.bios, 0x01);
    try std.testing.expectError(error.StateBios, savestate.load(&b.cpu, buf));
}

test "a section version newer than this build knows is StateVersion" {
    var a = try Machine.init();
    defer a.deinit();
    const buf = try saveAlloc(&a);
    defer std.testing.allocator.free(buf);

    // The first section's version sits right after its 4-byte tag.
    const at = savestate.header_len + 4;
    std.mem.writeInt(u32, buf[at..][0..4], 99, .little);
    // Re-seal the CRC so the version check is what fires.
    std.mem.writeInt(u32, buf[8..12], std.hash.Crc32.hash(buf[savestate.header_len..]), .little);

    var b = try Machine.init();
    defer b.deinit();
    try std.testing.expectError(error.StateVersion, savestate.load(&b.cpu, buf));
}

test "save into a buffer one byte short is NoSpace" {
    var a = try Machine.init();
    defer a.deinit();
    const n = try savestate.save(&a.cpu, null);
    const buf = try std.testing.allocator.alloc(u8, n - 1);
    defer std.testing.allocator.free(buf);
    try std.testing.expectError(error.NoSpace, savestate.save(&a.cpu, buf));
}

/// Offset of section `index`'s tag, found by walking the length fields.
fn sectionOffset(buf: []const u8, index: usize) usize {
    var at: usize = savestate.header_len;
    for (0..index) |_| at += 12 + std.mem.readInt(u32, buf[at + 8 ..][0..4], .little);
    return at;
}

/// Seals a hand-edited state the way `save` does, so the check under test is
/// the one that fires rather than the CRC.
fn reseal(buf: []u8) void {
    const body = buf[savestate.header_len..];
    std.mem.writeInt(u32, buf[12..16], @intCast(body.len), .little);
    std.mem.writeInt(u32, buf[8..12], std.hash.Crc32.hash(body), .little);
}

fn expectLoad(buf: []u8, expected: anyerror) !void {
    var b = try Machine.init();
    defer b.deinit();
    try std.testing.expectError(expected, savestate.load(&b.cpu, buf));
}

test "every section is mandatory exactly once" {
    var a = try Machine.init();
    defer a.deinit();
    const buf = try saveAlloc(&a);
    defer std.testing.allocator.free(buf);
    const last = sectionOffset(buf, 9);
    try std.testing.expectEqual(buf.len, sectionOffset(buf, 10));

    // The last section dropped.
    const dropped = try std.testing.allocator.dupe(u8, buf[0..last]);
    defer std.testing.allocator.free(dropped);
    reseal(dropped);
    try expectLoad(dropped, error.StateCorrupt);

    // The first section appearing twice.
    const first_end = sectionOffset(buf, 1);
    const doubled = try std.testing.allocator.alloc(u8, buf.len + first_end - savestate.header_len);
    defer std.testing.allocator.free(doubled);
    @memcpy(doubled[0..buf.len], buf);
    @memcpy(doubled[buf.len..], buf[savestate.header_len..first_end]);
    reseal(doubled);
    try expectLoad(doubled, error.StateCorrupt);

    // A tag this build does not know.
    const renamed = try std.testing.allocator.dupe(u8, buf);
    defer std.testing.allocator.free(renamed);
    @memcpy(renamed[last..][0..4], "ZZZZ");
    reseal(renamed);
    try expectLoad(renamed, error.StateVersion);

    // The last section's version newer than this build's.
    const bumped = try std.testing.allocator.dupe(u8, buf);
    defer std.testing.allocator.free(bumped);
    std.mem.writeInt(u32, bumped[last + 4 ..][0..4], 99, .little);
    reseal(bumped);
    try expectLoad(bumped, error.StateVersion);

    // A header body_len that disagrees with the file, CRC untouched.
    const lying = try std.testing.allocator.dupe(u8, buf);
    defer std.testing.allocator.free(lying);
    std.mem.writeInt(u32, lying[12..16], @intCast(buf.len - savestate.header_len + 1), .little);
    try expectLoad(lying, error.StateCorrupt);
}

const disc_sector_bytes = 2352;
const disc_sectors = 40;

/// The smallest Mode 1 disc `discid` reads a serial from: a PVD, a root
/// directory and a SYSTEM.CNF naming `boot`.
fn buildDisc(image: *[disc_sector_bytes * disc_sectors]u8, boot: []const u8) ps1.disc.Disc {
    @memset(image, 0);
    const put = struct {
        fn sector(img: []u8, lba: usize, payload: []const u8) void {
            const base = lba * disc_sector_bytes;
            img[base + 15] = 1;
            @memcpy(img[base + 16 ..][0..payload.len], payload);
        }
        fn record(out: []u8, extent: u32, length: usize, name: []const u8) usize {
            const size = 33 + name.len + (name.len + 1) % 2;
            out[0] = @intCast(size);
            std.mem.writeInt(u32, out[2..6], extent, .little);
            std.mem.writeInt(u32, out[10..14], @intCast(length), .little);
            out[32] = @intCast(name.len);
            @memcpy(out[33..][0..name.len], name);
            return size;
        }
    };
    var pvd = [_]u8{0} ** 2048;
    pvd[0] = 1;
    @memcpy(pvd[1..6], "CD001");
    pvd[6] = 1;
    _ = put.record(pvd[156..], 22, 2048, "\x00");
    put.sector(image, 16, &pvd);
    var root = [_]u8{0} ** 2048;
    var at: usize = 0;
    at += put.record(root[at..], 22, 2048, "\x00");
    at += put.record(root[at..], 22, 2048, "\x01");
    _ = put.record(root[at..], 30, boot.len, "SYSTEM.CNF;1");
    put.sector(image, 22, &root);
    put.sector(image, 30, boot);
    return ps1.disc.Disc.init(image);
}

test "a state refuses a different disc in the tray" {
    var img_a: [disc_sector_bytes * disc_sectors]u8 = undefined;
    var img_b: [disc_sector_bytes * disc_sectors]u8 = undefined;
    var a = try Machine.init();
    defer a.deinit();
    a.bus.cdrom.disc = buildDisc(&img_a, "BOOT = cdrom:\\SLUS_005.30;1\r\n");
    try std.testing.expectEqualStrings("SLUS-00530", std.mem.sliceTo(&savestate.identityOf(a.bus).serial, 0));
    const buf = try saveAlloc(&a);
    defer std.testing.allocator.free(buf);

    var b = try Machine.init();
    defer b.deinit();
    b.bus.cdrom.disc = buildDisc(&img_b, "BOOT = cdrom:\\SLUS_005.31;1\r\n");
    try std.testing.expectError(error.StateDisc, savestate.load(&b.cpu, buf));

    // No disc at all is a different disc too.
    b.bus.cdrom.disc = null;
    try std.testing.expectError(error.StateDisc, savestate.load(&b.cpu, buf));

    // The same disc loads.
    b.bus.cdrom.disc = buildDisc(&img_b, "BOOT = cdrom:\\SLUS_005.30;1\r\n");
    try savestate.load(&b.cpu, buf);
}
