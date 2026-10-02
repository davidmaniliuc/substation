//! The SPU section: sound RAM, every voice, reverb, noise, the CD/external
//! mix and the output ring.
//!
//! The output ring is saved so a restored machine is bit-identical to one
//! that never saved; on a resume the app drains the few milliseconds it
//! holds like any other samples. `reverb_enable` is a host isolation switch
//! with no setter, and is not machine state.

const std = @import("std");
const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const AdsrState = @import("../spu/adsr.zig").AdsrState;

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveSpu(cpu: *const Cpu, w: *Writer) Error!void {
    const s = &cpu.bus.spu;
    try w.array(&s.sram);
    try w.int(s.main_vol_l);
    try w.int(s.main_vol_r);
    try w.int(s.reverb_vol_l);
    try w.int(s.reverb_vol_r);
    try w.int(s.spu_cnt);
    try w.int(s.spu_stat);
    try w.int(s.sram_addr);
    try w.int(s.sram_read_buffer);
    try w.int(s.dtc);
    try w.int(s.pmon);
    try w.int(s.non);
    try w.int(s.von);
    try w.int(s.noise.timer);
    try w.int(s.noise.lfsr);
    try w.int(s.noise.level);
    try w.int(s.mix.cd_vol_l);
    try w.int(s.mix.cd_vol_r);
    try w.int(s.mix.ext_vol_l);
    try w.int(s.mix.ext_vol_r);
    try w.int(s.mix.current_cd_l);
    try w.int(s.mix.current_cd_r);
    try w.int(s.mix.current_ext_l);
    try w.int(s.mix.current_ext_r);
    try w.int(s.irq_addr);
    try w.flag(s.irq_flag);
    try w.array(&s.reverb.regs);
    try w.int(s.reverb.base);
    try w.int(s.reverb.curr_addr);
    try w.int(s.reverb.counter);
    try w.int(s.reverb.out_l);
    try w.int(s.reverb.out_r);
    for (&s.voices) |*v| {
        try w.int(v.regs.vol_l);
        try w.int(v.regs.vol_r);
        try w.int(v.regs.pitch);
        try w.int(v.regs.start_addr);
        try w.int(v.regs.adsr1);
        try w.int(v.regs.adsr2);
        try w.int(v.regs.adsr_vol);
        try w.int(v.regs.loop_addr);
        try w.int(v.adpcm.current_addr);
        try w.int(v.adpcm.current_fraction);
        try w.int(v.adpcm.old);
        try w.int(v.adpcm.older);
        try w.array(&v.adpcm.decoded_buffer);
        try w.array(&v.adpcm.history);
        try w.int(v.adpcm.buffer_index);
        try w.flag(v.is_on);
        try w.flag(v.ignore_samples);
        try w.flag(v.has_reached_endx);
        try w.tag(v.env.state);
        try w.int(v.env.current_ad_vol);
        try w.int(v.env.cycles);
    }
    try w.array(&s.output_buffer);
    try w.int(s.write_idx);
    try w.int(s.read_idx);
    try w.int(s.cycle_accumulator);
}

pub fn loadSpu(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    const s = &cpu.bus.spu;
    try r.array(&s.sram);
    s.main_vol_l = try r.int(i16);
    s.main_vol_r = try r.int(i16);
    s.reverb_vol_l = try r.int(i16);
    s.reverb_vol_r = try r.int(i16);
    s.spu_cnt = try r.int(u16);
    s.spu_stat = try r.int(u16);
    s.sram_addr = try r.int(u32);
    s.sram_read_buffer = try r.int(u16);
    s.dtc = try r.int(u16);
    s.pmon = try r.int(u32);
    s.non = try r.int(u32);
    s.von = try r.int(u32);
    s.noise.timer = try r.int(i32);
    s.noise.lfsr = try r.int(u32);
    s.noise.level = try r.int(i32);
    s.mix.cd_vol_l = try r.int(i16);
    s.mix.cd_vol_r = try r.int(i16);
    s.mix.ext_vol_l = try r.int(i16);
    s.mix.ext_vol_r = try r.int(i16);
    s.mix.current_cd_l = try r.int(i16);
    s.mix.current_cd_r = try r.int(i16);
    s.mix.current_ext_l = try r.int(i16);
    s.mix.current_ext_r = try r.int(i16);
    s.irq_addr = try r.int(u16);
    s.irq_flag = try r.flag();
    try r.array(&s.reverb.regs);
    s.reverb.base = try r.int(u16);
    s.reverb.curr_addr = try r.int(u32);
    s.reverb.counter = try r.int(u32);
    s.reverb.out_l = try r.int(i32);
    s.reverb.out_r = try r.int(i32);
    for (&s.voices) |*v| {
        v.regs.vol_l = try r.int(i16);
        v.regs.vol_r = try r.int(i16);
        v.regs.pitch = try r.int(u16);
        v.regs.start_addr = try r.int(u16);
        v.regs.adsr1 = try r.int(u16);
        v.regs.adsr2 = try r.int(u16);
        v.regs.adsr_vol = try r.int(i16);
        v.regs.loop_addr = try r.int(u16);
        v.adpcm.current_addr = try r.int(u32);
        v.adpcm.current_fraction = try r.int(u16);
        v.adpcm.old = try r.int(i32);
        v.adpcm.older = try r.int(i32);
        try r.array(&v.adpcm.decoded_buffer);
        try r.array(&v.adpcm.history);
        v.adpcm.buffer_index = try r.int(usize);
        if (v.adpcm.buffer_index > v.adpcm.decoded_buffer.len) return error.StateCorrupt;
        v.is_on = try r.flag();
        v.ignore_samples = try r.flag();
        v.has_reached_endx = try r.flag();
        v.env.state = try r.tag(AdsrState);
        v.env.current_ad_vol = try r.int(i32);
        v.env.cycles = try r.int(u32);
    }
    try r.array(&s.output_buffer);
    s.write_idx = try r.int(usize);
    s.read_idx = try r.int(usize);
    if (s.write_idx >= s.output_buffer.len or s.read_idx >= s.output_buffer.len) return error.StateCorrupt;
    s.cycle_accumulator = try r.int(u32);
}
