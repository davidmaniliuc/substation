const std = @import("std");
const ps1 = @import("ps1_core");
const stream = ps1.savestate_stream;

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
const cpu_state = ps1.savestate_cpu;
const io_state = ps1.savestate_io;

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
