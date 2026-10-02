//! The CD-ROM section: registers, the parameter/response/data FIFOs and the
//! IRQ queue, the drive mechanism (position, every timer `nextDeadline` reads,
//! the shell latch), the shared audio FIFO and the XA decoder's history.
//!
//! The disc itself is not here: its bytes are reloaded from the library and
//! the header's serial proves it is the same disc. `debug_enable` and
//! `trace_commands` are host logging switches.

const std = @import("std");
const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const cdrom = @import("../cdrom/cdrom.zig");

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveCdrom(cpu: *const Cpu, w: *Writer) Error!void {
    const cd = &cpu.bus.cdrom;
    try w.int(cd.regs.index);
    try w.int(cd.regs.irq_enable);
    try w.int(cd.regs.busy_for);
    try w.int(cd.regs.last_response_byte);
    try w.int(cd.regs.volume_ll);
    try w.int(cd.regs.volume_lr);
    try w.int(cd.regs.volume_rl);
    try w.int(cd.regs.volume_rr);

    const f = &cd.fifos;
    try w.array(&f.parameter_fifo);
    try w.int(f.parameter_len);
    const q = &f.irq_queue;
    for (&q.items) |*item| {
        try w.int(item.irq);
        try w.array(&item.response);
        try w.int(item.response_len);
        try w.int(item.response_ptr);
        try w.int(item.delay);
        try w.flag(item.ack);
        try w.flag(item.triggered);
        try w.tag(item.action);
        try w.flag(item.auto_status);
    }
    try w.int(q.head);
    try w.int(q.tail);
    try w.int(q.count);
    try w.int(q.overflow_count);
    try w.flag(f.irq_line);
    try w.array(&f.last_raw_sector);
    try w.array(&f.sector_buffer);
    try w.int(f.sector_buffer_ptr);
    try w.int(f.sector_buffer_len);
    try w.flag(f.data_fifo_empty);

    const d = &cd.drive;
    try w.tag(d.drive_state);
    try w.int(d.sector_timer);
    try w.int(d.seek_timer);
    try w.flag(d.read_after_seek);
    try w.int(d.status);
    try w.int(d.mode);
    try w.int(d.seek_target.m);
    try w.int(d.seek_target.s);
    try w.int(d.seek_target.f);
    try w.int(d.current_pos.m);
    try w.int(d.current_pos.s);
    try w.int(d.current_pos.f);
    try w.flag(d.loc_l_valid);
    try w.flag(d.muted);
    try w.flag(d.shell_open);
    try w.flag(d.shell_changed);
    try w.int(d.shell_close_timer);
    try w.array(&d.last_sector_header);
    try w.array(&d.last_subchannel_q);
    try w.int(d.sectors_delivered);
    try w.int(d.previous_track);

    try w.array(&cd.audio.audio_fifo_l);
    try w.array(&cd.audio.audio_fifo_r);
    try w.int(cd.audio.audio_fifo_read);
    try w.int(cd.audio.audio_fifo_write);
    try w.int(cd.audio.audio_tick_counter);

    try w.int(cd.xa.xa_filter_file);
    try w.int(cd.xa.xa_filter_channel);
    try w.int(cd.xa.xa_old_l);
    try w.int(cd.xa.xa_older_l);
    try w.int(cd.xa.xa_old_r);
    try w.int(cd.xa.xa_older_r);
    try w.array(&cd.xa.xa_ringbuf);
    try w.array(&cd.xa.xa_ring_p);
    try w.array(&cd.xa.xa_sixstep);

    try w.flag(cd.pending_command != null);
    try w.int(cd.pending_command orelse 0);
    try w.int(cd.pending_command_delay);
    try w.int(cd.pending_cycles);
    try w.int(cd.event_countdown);
}

pub fn loadCdrom(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const cd = &cpu.bus.cdrom;
    cd.regs.index = try r.int(u2);
    cd.regs.irq_enable = try r.int(u8);
    cd.regs.busy_for = try r.int(i32);
    cd.regs.last_response_byte = try r.int(u8);
    cd.regs.volume_ll = try r.int(u8);
    cd.regs.volume_lr = try r.int(u8);
    cd.regs.volume_rl = try r.int(u8);
    cd.regs.volume_rr = try r.int(u8);

    const f = &cd.fifos;
    try r.array(&f.parameter_fifo);
    f.parameter_len = try r.int(usize);
    if (f.parameter_len > f.parameter_fifo.len) return error.StateCorrupt;
    const q = &f.irq_queue;
    for (&q.items) |*item| {
        item.irq = try r.int(u8);
        try r.array(&item.response);
        item.response_len = try r.int(usize);
        item.response_ptr = try r.int(usize);
        if (item.response_len > item.response.len or item.response_ptr > item.response.len) return error.StateCorrupt;
        item.delay = try r.int(i64);
        item.ack = try r.flag();
        item.triggered = try r.flag();
        item.action = try r.tag(cdrom.IrqAction);
        item.auto_status = try r.flag();
    }
    q.head = try r.int(usize);
    q.tail = try r.int(usize);
    q.count = try r.int(usize);
    q.overflow_count = try r.int(u32);
    if (q.head >= q.items.len or q.tail >= q.items.len or q.count > q.items.len) return error.StateCorrupt;
    f.irq_line = try r.flag();
    try r.array(&f.last_raw_sector);
    try r.array(&f.sector_buffer);
    f.sector_buffer_ptr = try r.int(usize);
    f.sector_buffer_len = try r.int(usize);
    f.data_fifo_empty = try r.flag();
    if (f.sector_buffer_len > f.sector_buffer.len) return error.StateCorrupt;
    if (!f.data_fifo_empty and f.sector_buffer_ptr >= f.sector_buffer_len) return error.StateCorrupt;

    const d = &cd.drive;
    d.drive_state = try r.tag(cdrom.DriveState);
    d.sector_timer = try r.int(i64);
    d.seek_timer = try r.int(i64);
    d.read_after_seek = try r.flag();
    d.status = try r.int(u8);
    d.mode = try r.int(u8);
    d.seek_target.m = try r.int(u8);
    d.seek_target.s = try r.int(u8);
    d.seek_target.f = try r.int(u8);
    d.current_pos.m = try r.int(u8);
    d.current_pos.s = try r.int(u8);
    d.current_pos.f = try r.int(u8);
    d.loc_l_valid = try r.flag();
    d.muted = try r.flag();
    d.shell_open = try r.flag();
    d.shell_changed = try r.flag();
    d.shell_close_timer = try r.int(i64);
    try r.array(&d.last_sector_header);
    try r.array(&d.last_subchannel_q);
    d.sectors_delivered = try r.int(u64);
    d.previous_track = try r.int(u8);

    try r.array(&cd.audio.audio_fifo_l);
    try r.array(&cd.audio.audio_fifo_r);
    cd.audio.audio_fifo_read = try r.int(usize);
    cd.audio.audio_fifo_write = try r.int(usize);
    cd.audio.audio_tick_counter = try r.int(u32);
    if (cd.audio.audio_fifo_read >= cd.audio.audio_fifo_l.len or cd.audio.audio_fifo_write >= cd.audio.audio_fifo_l.len) return error.StateCorrupt;

    cd.xa.xa_filter_file = try r.int(u8);
    cd.xa.xa_filter_channel = try r.int(u8);
    cd.xa.xa_old_l = try r.int(i32);
    cd.xa.xa_older_l = try r.int(i32);
    cd.xa.xa_old_r = try r.int(i32);
    cd.xa.xa_older_r = try r.int(i32);
    try r.array(&cd.xa.xa_ringbuf);
    try r.array(&cd.xa.xa_ring_p);
    try r.array(&cd.xa.xa_sixstep);
    for (cd.xa.xa_sixstep) |n| if (n == 0 or n > 6) return error.StateCorrupt;

    const has_pending = try r.flag();
    const pending = try r.int(u8);
    cd.pending_command = if (has_pending) pending else null;
    cd.pending_command_delay = try r.int(u32);
    cd.pending_cycles = try r.int(u32);
    cd.event_countdown = try r.int(i64);
}
