//! Hand-written, per-region hashing of the whole emulated machine.
//!
//! Every field is named by hand, on purpose. Reflection (`std.meta.fields`, a
//! `@typeInfo` loop over a device struct, `std.hash.autoHash` on a struct) would
//! make this file silently *follow* the refactor it is supposed to police: a
//! field that gets renamed, retyped or absorbed into a sub-struct would keep
//! being hashed with no diff, and a field that gets dropped would vanish from
//! the check along with it. Naming each field means a structural change to the
//! core has to be reflected here explicitly, by a human, and anything missed
//! shows up as a compile error rather than as a hole in the safety net.
//!
//! The only `@typeInfo` in this file is on the `Region` *enum*, to pin its
//! order against `golden.region_names`.

const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");

const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;

/// Column order of a golden row. Kept in lockstep with `golden.region_names`
/// by the comptime check below.
pub const Region = enum(u8) {
    ram,
    io,
    vram,
    cpu,
    cdrom,
    spu,
    gpu,
    dma,
    timer,
    sio,
    mdec,
    interrupt,
};

comptime {
    const fields = @typeInfo(Region).@"enum".fields;
    if (fields.len != golden.region_count) @compileError("Region/region_names length mismatch");
    for (fields, golden.region_names) |f, n| {
        if (!std.mem.eql(u8, f.name, n)) @compileError("Region/region_names order mismatch: " ++ f.name);
    }
}

/// Every integer is widened to 64 bits before hashing, so a refactor that
/// changes a field's width (u8 -> u16, usize -> u32) does not by itself move a
/// hash. Width changes are a legitimate part of this refactor; value changes
/// are not.
pub const Sink = struct {
    w: std.hash.Wyhash,

    pub fn init() Sink {
        return .{ .w = std.hash.Wyhash.init(0) };
    }

    pub fn bytes(self: *Sink, b: []const u8) void {
        self.w.update(b);
    }

    pub fn int(self: *Sink, v: anytype) void {
        const info = @typeInfo(@TypeOf(v)).int;
        if (info.signedness == .signed) {
            const wide = std.mem.nativeToLittle(i64, @as(i64, v));
            self.w.update(std.mem.asBytes(&wide));
        } else {
            const wide = std.mem.nativeToLittle(u64, @as(u64, v));
            self.w.update(std.mem.asBytes(&wide));
        }
    }

    pub fn flag(self: *Sink, v: bool) void {
        self.int(@as(u8, if (v) 1 else 0));
    }

    pub fn tag(self: *Sink, v: anytype) void {
        self.int(@as(u32, @intFromEnum(v)));
    }

    pub fn optByte(self: *Sink, v: ?u8) void {
        self.flag(v != null);
        self.int(v orelse 0);
    }

    pub fn final(self: *Sink) u64 {
        return self.w.final();
    }
};

pub fn hashAll(cpu: *const Cpu, out: *[golden.region_count]u64) void {
    const bus = cpu.bus;
    out[@intFromEnum(Region.ram)] = hashRam(bus);
    out[@intFromEnum(Region.io)] = hashIo(bus);
    out[@intFromEnum(Region.vram)] = hashVram(bus);
    out[@intFromEnum(Region.cpu)] = hashCpu(cpu);
    out[@intFromEnum(Region.cdrom)] = hashCdrom(bus);
    out[@intFromEnum(Region.spu)] = hashSpu(bus);
    out[@intFromEnum(Region.gpu)] = hashGpu(bus);
    out[@intFromEnum(Region.dma)] = hashDma(bus);
    out[@intFromEnum(Region.timer)] = hashTimers(bus);
    out[@intFromEnum(Region.sio)] = hashSio(bus);
    out[@intFromEnum(Region.mdec)] = hashMdec(bus);
    out[@intFromEnum(Region.interrupt)] = hashInterrupt(bus);
}

/// Regions that no workload writes but a refactor could still corrupt. Hashing
/// 10 MB of expansion space 240 times per workload would dominate runtime for
/// no benefit, so these are checked once at start and once at end of a run.
pub fn hashStatic(bus: *const Bus) u64 {
    var s = Sink.init();
    s.bytes(&bus.bios);
    s.bytes(&bus.expansion_1);
    s.bytes(&bus.expansion_2);
    s.bytes(&bus.expansion_3);
    s.int(bus.expansion_3_last_write_width);
    return s.final();
}

fn hashRam(bus: *const Bus) u64 {
    var s = Sink.init();
    s.bytes(&bus.ram);
    s.int(bus.sys_clock);
    s.int(bus.wait_cycles);
    return s.final();
}

fn hashIo(bus: *const Bus) u64 {
    var s = Sink.init();
    s.bytes(&bus.scratchpad);
    s.bytes(&bus.io_ports);
    s.bytes(&bus.cache_control);
    return s.final();
}

fn hashVram(bus: *const Bus) u64 {
    const v = &bus.gpu.vram;
    var s = Sink.init();
    s.bytes(std.mem.asBytes(&v.data));
    s.flag(v.write_active);
    s.int(v.write_x);
    s.int(v.write_y);
    s.int(v.write_w);
    s.int(v.write_h);
    s.int(v.write_curr_x);
    s.int(v.write_curr_y);
    s.int(v.write_remaining);
    s.flag(v.read_active);
    s.int(v.read_x);
    s.int(v.read_y);
    s.int(v.read_w);
    s.int(v.read_h);
    s.int(v.read_curr_x);
    s.int(v.read_curr_y);
    s.int(v.read_remaining);
    return s.final();
}

/// Excludes `bus`, `tty_context` and `tty_write_fn`: host pointers whose values
/// vary between runs and carry no emulated state.
///
/// Also excludes `Cpu.bios_hit_count`. It is a `pub var` in the `Cpu`
/// *namespace*, not a field — one process-global diagnostic counter shared by
/// every machine ever constructed, printed by `ps1-debug` and read by nothing
/// else. Folding it in would make a region hash depend on how many other
/// machines the process had already run.
fn hashCpu(cpu: *const Cpu) u64 {
    var s = Sink.init();
    for (cpu.regs) |r| s.int(r);
    s.int(cpu.pipeline.pc);
    s.int(cpu.pipeline.next_pc);
    s.int(cpu.pipeline.current_pc);
    s.flag(cpu.pipeline.is_delay_slot);
    s.flag(cpu.pipeline.next_is_delay_slot);
    s.int(cpu.load_delay.load_r);
    s.int(cpu.load_delay.load_v);
    s.int(cpu.load_delay.delay_r);
    s.int(cpu.load_delay.delay_v);
    s.int(cpu.hi);
    s.int(cpu.lo);
    s.int(cpu.cycles);
    s.int(cpu.gpu_clock_frac);
    for (cpu.cop0.regs) |r| s.int(r);
    for (cpu.cop2.data_regs) |r| s.int(r);
    for (cpu.cop2.ctrl_regs) |r| s.int(r);
    for (cpu.cop2.macs) |m| s.int(m);
    for (cpu.icache) |line| {
        s.int(line.tag);
        for (line.data) |wd| s.int(wd);
    }
    return s.final();
}

/// Excludes `debug_enable` (a host logging toggle) and `disc` (holds a slice
/// into a heap buffer whose address varies per run, plus a `tracks` array that
/// is `undefined` past `track_count`; the disc is read-only input, identical
/// for every run of a workload).
fn hashCdrom(bus: *const Bus) u64 {
    const cd = &bus.cdrom;
    var s = Sink.init();
    s.int(cd.regs.index);
    s.int(cd.regs.irq_enable);
    s.bytes(&cd.fifos.parameter_fifo);
    s.int(cd.fifos.parameter_len);
    s.int(cd.regs.last_response_byte);
    s.bytes(&cd.fifos.last_raw_sector);
    s.bytes(&cd.fifos.sector_buffer);
    s.int(cd.fifos.sector_buffer_ptr);
    s.int(cd.fifos.sector_buffer_len);
    s.flag(cd.fifos.data_fifo_empty);
    s.int(cd.drive.status);
    s.int(cd.drive.mode);
    s.int(cd.drive.seek_target.m);
    s.int(cd.drive.seek_target.s);
    s.int(cd.drive.seek_target.f);
    s.int(cd.drive.current_pos.m);
    s.int(cd.drive.current_pos.s);
    s.int(cd.drive.current_pos.f);
    s.int(cd.regs.busy_for);
    s.flag(cd.drive.loc_l_valid);
    s.flag(cd.drive.muted);
    s.flag(cd.drive.shell_open);
    s.flag(cd.drive.shell_changed);
    s.int(cd.drive.shell_close_timer);
    s.bytes(&cd.drive.last_sector_header);
    s.bytes(&cd.drive.last_subchannel_q);
    s.int(cd.xa.xa_filter_file);
    s.int(cd.xa.xa_filter_channel);
    s.int(cd.regs.volume_ll);
    s.int(cd.regs.volume_lr);
    s.int(cd.regs.volume_rl);
    s.int(cd.regs.volume_rr);
    s.optByte(cd.pending_command);
    s.int(cd.pending_command_delay);
    s.bytes(std.mem.asBytes(&cd.audio.audio_fifo_l));
    s.bytes(std.mem.asBytes(&cd.audio.audio_fifo_r));
    s.int(cd.audio.audio_fifo_read);
    s.int(cd.audio.audio_fifo_write);
    s.int(cd.audio.audio_tick_counter);
    s.int(cd.xa.xa_old_l);
    s.int(cd.xa.xa_older_l);
    s.int(cd.xa.xa_old_r);
    s.int(cd.xa.xa_older_r);
    for (&cd.xa.xa_ringbuf) |*ring| s.bytes(std.mem.asBytes(ring));
    for (cd.xa.xa_ring_p) |p| s.int(p);
    for (cd.xa.xa_sixstep) |v| s.int(v);
    s.tag(cd.drive.drive_state);
    s.int(cd.drive.sector_timer);
    s.int(cd.drive.seek_timer);
    s.flag(cd.drive.read_after_seek);

    const q = &cd.fifos.irq_queue;
    s.int(q.head);
    s.int(q.tail);
    s.int(q.count);
    s.int(q.overflow_count);
    for (&q.items) |*item| {
        s.int(item.irq);
        s.bytes(&item.response);
        s.int(item.response_len);
        s.int(item.response_ptr);
        s.int(item.delay);
        s.flag(item.ack);
        s.flag(item.triggered);
        s.tag(item.action);
        s.flag(item.auto_status);
    }

    s.flag(cd.fifos.irq_line);
    s.int(cd.drive.sectors_delivered);
    return s.final();
}

/// Excludes `reverb_enable`: a host isolation switch with no setter, constant
/// for the lifetime of a run.
fn hashSpu(bus: *const Bus) u64 {
    const spu = &bus.spu;
    var s = Sink.init();
    s.bytes(&spu.sram);
    s.int(spu.main_vol_l);
    s.int(spu.main_vol_r);
    s.int(spu.reverb_vol_l);
    s.int(spu.reverb_vol_r);
    s.int(spu.spu_cnt);
    s.int(spu.spu_stat);
    s.int(spu.sram_addr);
    s.int(spu.sram_read_buffer);
    s.int(spu.dtc);
    s.int(spu.pmon);
    s.int(spu.non);
    s.int(spu.von);
    s.int(spu.noise.timer);
    s.int(spu.noise.lfsr);
    s.int(spu.noise.level);
    s.int(spu.mix.cd_vol_l);
    s.int(spu.mix.cd_vol_r);
    s.int(spu.mix.ext_vol_l);
    s.int(spu.mix.ext_vol_r);
    s.int(spu.mix.current_cd_l);
    s.int(spu.mix.current_cd_r);
    s.int(spu.mix.current_ext_l);
    s.int(spu.mix.current_ext_r);
    s.int(spu.irq_addr);
    s.flag(spu.irq_flag);
    s.bytes(std.mem.asBytes(&spu.reverb.regs));
    s.int(spu.reverb.base);
    s.int(spu.reverb.curr_addr);
    s.int(spu.reverb.counter);
    s.int(spu.reverb.out_l);
    s.int(spu.reverb.out_r);
    for (&spu.voices) |*v| {
        s.int(v.regs.vol_l);
        s.int(v.regs.vol_r);
        s.int(v.regs.pitch);
        s.int(v.regs.start_addr);
        s.int(v.regs.adsr1);
        s.int(v.regs.adsr2);
        s.int(v.regs.adsr_vol);
        s.int(v.regs.loop_addr);
        s.int(v.adpcm.current_addr);
        s.int(v.adpcm.current_fraction);
        s.int(v.adpcm.old);
        s.int(v.adpcm.older);
        s.bytes(std.mem.asBytes(&v.adpcm.decoded_buffer));
        s.bytes(std.mem.asBytes(&v.adpcm.history));
        s.int(v.adpcm.buffer_index);
        s.flag(v.is_on);
        s.flag(v.ignore_samples);
        s.flag(v.has_reached_endx);
        s.tag(v.env.state);
        s.int(v.env.current_ad_vol);
        s.int(v.env.cycles);
    }
    // The emitted audio itself. f32 bit patterns are deterministic for the
    // same arithmetic on the same target.
    s.bytes(std.mem.asBytes(&spu.output_buffer));
    s.int(spu.write_idx);
    s.int(spu.read_idx);
    s.int(spu.cycle_accumulator);
    return s.final();
}

/// VRAM lives in its own region, so this is the GPU's register and FIFO state.
///
/// Excludes `Gpu.sink`. It is host capture state, not machine state: in a
/// `gpu_sink = .software` build it is a zero-sized struct, and in the `.dual`
/// build ps1-golden itself uses it is a capture buffer whose contents are an
/// artifact of when `stream-verify` last drained it. Hashing it would make
/// `capture`/`verify` disagree with `stream-verify` for reasons that have
/// nothing to do with the emulated machine. Same category as the host pointers
/// and `cdrom.debug_enable`.
///
/// Also excludes `Gpu.fifo_pgxp` and `Gp0Engine.cmd_buffer_pgxp`. Same
/// category as `cdrom.pending_cycles`: host-side derived state, not
/// hardware-visible, always all-`Precise.none` with PGXP off, and hashing
/// two more 16-entry `Precise` arrays (16 bytes each) per sample would cost
/// the sweep for a field the machine itself cannot observe.
fn hashGpu(bus: *const Bus) u64 {
    const g = &bus.gpu;
    var s = Sink.init();
    s.int(g.draw_env.draw_mode);
    s.int(g.draw_env.tex_window);
    s.int(g.draw_env.area_top_left);
    s.int(g.draw_env.area_bot_right);
    s.int(g.draw_env.offset);
    s.int(g.draw_env.mask_bit);
    s.flag(g.draw_env.texture_disable_allowed);
    s.int(g.disp_env.vram_x_start);
    s.int(g.disp_env.vram_y_start);
    s.int(g.disp_env.screen_x1);
    s.int(g.disp_env.screen_x2);
    s.int(g.disp_env.screen_y1);
    s.int(g.disp_env.screen_y2);
    s.int(g.disp_env.display_mode);
    s.flag(g.disp_env.display_disabled);
    for (g.gp0.cmd_buffer) |wd| s.int(wd);
    s.int(g.gp0.words_remaining);
    s.int(g.gp0.words_read);
    s.flag(g.gp0.polyline_active);
    s.flag(g.gp0.polyline_shaded);
    s.int(g.gp0.polyline_count);
    s.flag(g.gp0.polyline_transparent);
    s.int(g.gp0.polyline_prev_x);
    s.int(g.gp0.polyline_prev_y);
    s.int(g.gp0.polyline_prev_color);
    s.int(g.gp0.polyline_next_color);
    s.tag(g.gpu_read_mode);
    s.int(g.gpu_read_data);
    s.int(g.dma_direction);
    s.flag(g.interrupt_flag);
    s.flag(g.is_vblank);
    s.flag(g.is_ntsc);
    s.int(g.h_count);
    s.int(g.v_count);
    s.int(g.dotclock_count);
    s.flag(g.prev_interrupt_flag);
    s.flag(g.is_even_field);
    for (g.fifo) |wd| s.int(wd);
    s.int(g.fifo_head);
    s.int(g.fifo_tail);
    s.int(g.fifo_count);
    s.int(g.cycle_debt);
    return s.final();
}

fn hashDma(bus: *const Bus) u64 {
    const d = &bus.dma;
    var s = Sink.init();
    s.int(d.dpcr);
    s.int(d.dicr);
    for (&d.channels) |*c| {
        s.int(c.base_addr);
        s.int(c.block_control);
        s.int(c.control);
        s.flag(c.transfer_active);
        s.int(c.words_remaining);
        s.int(c.linked_list_next);
        s.int(c.ll_nodes);
        s.int(c.chop_dma_window);
        s.int(c.chop_cpu_window);
        s.flag(c.chop_is_cpu_turn);
        s.int(c.chop_counter);
        s.int(c.block_words);
        s.int(c.block_word_progress);
        s.int(c.block_cycles);
        s.int(c.block_gap_counter);
    }
    return s.final();
}

fn hashTimers(bus: *const Bus) u64 {
    var s = Sink.init();
    for (&bus.timers) |*t| {
        s.int(t.counter);
        s.int(t.mode);
        s.int(t.target);
        s.int(t.prescale_counter);
    }
    return s.final();
}

fn hashSio(bus: *const Bus) u64 {
    const io = &bus.sio;
    var s = Sink.init();
    s.int(io.stat);
    s.int(io.mode);
    s.int(io.ctrl);
    s.int(io.baud);
    s.int(io.rx_data);
    s.tag(io.ctrl_state);
    s.flag(io.ack);
    s.flag(io.irq);
    s.int(io.irq_timer);
    s.int(io.buttons);
    s.flag(io.analog_enabled);
    s.int(io.joy_rx);
    s.int(io.joy_ry);
    s.int(io.joy_lx);
    s.int(io.joy_ly);
    s.int(io.motor_right_small);
    s.int(io.motor_left_large);
    s.int(io.port);
    for (0..ps1.sio.Sio.memcard_slots) |i| {
        s.bytes(&io.memcard_data[i]);
        s.bytes(&io.memcard_staging[i]);
        s.int(io.memcard_address[i]);
        s.int(io.memcard_checksum[i]);
        s.int(io.memcard_step[i]);
        s.flag(io.memcard_is_write[i]);
        s.flag(io.memcard_dirty[i]);
        s.int(io.memcard_flag[i]);
        s.int(io.memcard_status[i]);
    }
    return s.final();
}

fn hashMdec(bus: *const Bus) u64 {
    const m = &bus.mdec;
    var s = Sink.init();
    s.int(m.status);
    s.bytes(&m.quant_luminance);
    s.bytes(&m.quant_color);
    s.bytes(std.mem.asBytes(&m.scale_table));
    s.int(m.current_cmd);
    s.int(m.words_remaining);
    s.bytes(std.mem.asBytes(&m.input_fifo));
    s.int(m.input_len);
    for (&m.y_blocks) |*blk| s.bytes(std.mem.asBytes(blk));
    s.bytes(std.mem.asBytes(&m.cb_block));
    s.bytes(std.mem.asBytes(&m.cr_block));
    s.bytes(std.mem.asBytes(&m.output_fifo));
    s.int(m.output_ptr);
    s.int(m.output_len);
    s.int(m.output_depth);
    s.flag(m.output_set_bit15);
    return s.final();
}

fn hashInterrupt(bus: *const Bus) u64 {
    var s = Sink.init();
    s.int(bus.interrupts.stat);
    s.int(bus.interrupts.mask);
    return s.final();
}
