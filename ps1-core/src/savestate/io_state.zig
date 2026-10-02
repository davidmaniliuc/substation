//! Sections for the memory regions `Bus` owns directly and the small devices:
//! interrupt controller, root counters, DMA, SIO and MDEC.
//!
//! The SIO section carries the pad and card PROTOCOL, never the card images
//! or their dirty flags. The cards are one pair shared by every game, so a
//! state that restored them would roll back saves made in other games.

const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Sio = @import("../sio.zig").Sio;

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveBus(cpu: *const Cpu, w: *Writer) Error!void {
    const bus = cpu.bus;
    try w.array(&bus.ram);
    try w.array(&bus.scratchpad);
    try w.array(&bus.io_ports);
    try w.array(&bus.expansion_2);
    try w.array(&bus.expansion_3);
    try w.int(bus.expansion_3_last_write_width);
    try w.array(&bus.cache_control);
    try w.int(bus.wait_cycles);
    try w.int(bus.sys_clock);
}

pub fn loadBus(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const bus = cpu.bus;
    try r.array(&bus.ram);
    try r.array(&bus.scratchpad);
    try r.array(&bus.io_ports);
    try r.array(&bus.expansion_2);
    try r.array(&bus.expansion_3);
    bus.expansion_3_last_write_width = try r.int(u8);
    try r.array(&bus.cache_control);
    bus.wait_cycles = try r.int(u32);
    bus.sys_clock = try r.int(u64);
}

pub fn saveIrq(cpu: *const Cpu, w: *Writer) Error!void {
    try w.int(cpu.bus.interrupts.stat);
    try w.int(cpu.bus.interrupts.mask);
}

pub fn loadIrq(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    cpu.bus.interrupts.stat = try r.int(u32);
    cpu.bus.interrupts.mask = try r.int(u32);
}

pub fn saveTimers(cpu: *const Cpu, w: *Writer) Error!void {
    for (&cpu.bus.timers) |*t| {
        try w.int(t.counter);
        try w.int(t.mode);
        try w.int(t.target);
        try w.int(t.prescale_counter);
        try w.int(t.pending_ticks);
        try w.int(t.event_countdown);
    }
}

pub fn loadTimers(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    for (&cpu.bus.timers) |*t| {
        t.counter = try r.int(u32);
        t.mode = try r.int(u32);
        t.target = try r.int(u32);
        t.prescale_counter = try r.int(u32);
        t.pending_ticks = try r.int(u32);
        t.event_countdown = try r.int(i64);
    }
}

pub fn saveDma(cpu: *const Cpu, w: *Writer) Error!void {
    const d = &cpu.bus.dma;
    try w.int(d.dpcr);
    try w.int(d.dicr);
    try w.flag(d.busy_hint);
    for (&d.channels) |*c| {
        try w.int(c.base_addr);
        try w.int(c.block_control);
        try w.int(c.control);
        try w.flag(c.transfer_active);
        try w.int(c.words_remaining);
        try w.int(c.linked_list_next);
        try w.int(c.ll_nodes);
        try w.int(c.chop_dma_window);
        try w.int(c.chop_cpu_window);
        try w.flag(c.chop_is_cpu_turn);
        try w.int(c.chop_counter);
        try w.int(c.block_words);
        try w.int(c.block_word_progress);
        try w.int(c.block_cycles);
        try w.int(c.block_gap_counter);
    }
}

pub fn loadDma(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const d = &cpu.bus.dma;
    d.dpcr = try r.int(u32);
    d.dicr = try r.int(u32);
    d.busy_hint = try r.flag();
    for (&d.channels) |*c| {
        c.base_addr = try r.int(u32);
        c.block_control = try r.int(u32);
        c.control = try r.int(u32);
        c.transfer_active = try r.flag();
        c.words_remaining = try r.int(u32);
        c.linked_list_next = try r.int(u32);
        c.ll_nodes = try r.int(u32);
        c.chop_dma_window = try r.int(u32);
        c.chop_cpu_window = try r.int(u32);
        c.chop_is_cpu_turn = try r.flag();
        c.chop_counter = try r.int(u32);
        c.block_words = try r.int(u32);
        c.block_word_progress = try r.int(u32);
        c.block_cycles = try r.int(u32);
        c.block_gap_counter = try r.int(u32);
    }
}

pub fn saveSio(cpu: *const Cpu, w: *Writer) Error!void {
    const io = &cpu.bus.sio;
    try w.int(io.stat);
    try w.int(io.mode);
    try w.int(io.ctrl);
    try w.int(io.baud);
    try w.int(io.rx_data);
    try w.tag(io.ctrl_state);
    try w.flag(io.ack);
    try w.flag(io.irq);
    try w.int(io.irq_timer);
    try w.int(io.buttons);
    try w.flag(io.analog_enabled);
    try w.int(io.port);
    try w.int(io.joy_rx);
    try w.int(io.joy_ry);
    try w.int(io.joy_lx);
    try w.int(io.joy_ly);
    try w.int(io.motor_right_small);
    try w.int(io.motor_left_large);
    for (0..Sio.memcard_slots) |i| {
        try w.array(&io.memcard_staging[i]);
        try w.int(io.memcard_address[i]);
        try w.int(io.memcard_checksum[i]);
        try w.int(io.memcard_step[i]);
        try w.flag(io.memcard_is_write[i]);
        try w.int(io.memcard_flag[i]);
        try w.int(io.memcard_status[i]);
    }
}

pub fn loadSio(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const io = &cpu.bus.sio;
    io.stat = try r.int(u32);
    io.mode = try r.int(u32);
    io.ctrl = try r.int(u32);
    io.baud = try r.int(u32);
    io.rx_data = try r.int(u8);
    io.ctrl_state = try r.tag(Sio.SioState);
    io.ack = try r.flag();
    io.irq = try r.flag();
    io.irq_timer = try r.int(u32);
    io.buttons = try r.int(u16);
    io.analog_enabled = try r.flag();
    io.port = try r.int(u1);
    io.joy_rx = try r.int(u8);
    io.joy_ry = try r.int(u8);
    io.joy_lx = try r.int(u8);
    io.joy_ly = try r.int(u8);
    io.motor_right_small = try r.int(u8);
    io.motor_left_large = try r.int(u8);
    for (0..Sio.memcard_slots) |i| {
        try r.array(&io.memcard_staging[i]);
        io.memcard_address[i] = try r.int(u16);
        io.memcard_checksum[i] = try r.int(u8);
        io.memcard_step[i] = try r.int(u32);
        io.memcard_is_write[i] = try r.flag();
        io.memcard_flag[i] = try r.int(u8);
        io.memcard_status[i] = try r.int(u8);
        if (io.memcard_address[i] > Sio.memcard_address_mask) return error.StateCorrupt;
        if (io.memcard_step[i] > Sio.memcard_sector_bytes) return error.StateCorrupt;
    }
}

pub fn saveMdec(cpu: *const Cpu, w: *Writer) Error!void {
    const m = &cpu.bus.mdec;
    try w.int(m.status);
    try w.array(&m.quant_luminance);
    try w.array(&m.quant_color);
    try w.array(&m.scale_table);
    try w.int(m.current_cmd);
    try w.int(m.words_remaining);
    try w.array(&m.input_fifo);
    try w.int(m.input_len);
    try w.array(&m.y_blocks);
    try w.array(&m.cb_block);
    try w.array(&m.cr_block);
    try w.array(&m.output_fifo);
    try w.int(m.output_ptr);
    try w.int(m.output_len);
    try w.int(m.output_depth);
    try w.flag(m.output_set_bit15);
}

pub fn loadMdec(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const m = &cpu.bus.mdec;
    m.status = try r.int(u32);
    try r.array(&m.quant_luminance);
    try r.array(&m.quant_color);
    try r.array(&m.scale_table);
    m.current_cmd = try r.int(u32);
    m.words_remaining = try r.int(u32);
    try r.array(&m.input_fifo);
    m.input_len = try r.int(usize);
    try r.array(&m.y_blocks);
    try r.array(&m.cb_block);
    try r.array(&m.cr_block);
    try r.array(&m.output_fifo);
    m.output_ptr = try r.int(usize);
    m.output_len = try r.int(usize);
    m.output_depth = try r.int(u3);
    m.output_set_bit15 = try r.flag();

    const fifo_len = m.input_fifo.len;
    if (m.input_len > fifo_len or m.input_len % 2 != 0) return error.StateCorrupt;
    if (m.output_ptr >= m.output_fifo.len or m.output_len > m.output_fifo.len) return error.StateCorrupt;
    if (m.output_depth > 3) return error.StateCorrupt;
    const words_ok = switch (m.current_cmd) {
        1 => m.input_len + 2 * @as(usize, m.words_remaining) <= fifo_len,
        2, 3 => m.words_remaining <= 32,
        else => m.words_remaining == 0,
    };
    if (!words_ok) return error.StateCorrupt;
}
