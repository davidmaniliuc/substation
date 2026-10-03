//! The CPU section: R3000A, COP0 and the GTE's registers.
//!
//! Written field by field for the reason `ps1-golden/src/state_hash.zig`
//! gives — a reflected dump would silently follow a refactor. The PGXP
//! shadows are deliberately absent: they are a cache the game rebuilds within
//! a frame or two, and the identity check reads a missing value as "no PGXP".

const std = @import("std");
const stream = @import("stream.zig");
const Cpu = @import("../cpu/cpu.zig").Cpu;

const Writer = stream.Writer;
const Reader = stream.Reader;
const Error = stream.Error;

pub fn saveCpu(cpu: *const Cpu, w: *Writer) Error!void {
    try w.array(&cpu.regs);
    try w.int(cpu.pipeline.pc);
    try w.int(cpu.pipeline.next_pc);
    try w.int(cpu.pipeline.current_pc);
    try w.flag(cpu.pipeline.is_delay_slot);
    try w.flag(cpu.pipeline.next_is_delay_slot);
    try w.int(cpu.load_delay.load_r);
    try w.int(cpu.load_delay.load_v);
    try w.int(cpu.load_delay.delay_r);
    try w.int(cpu.load_delay.delay_v);
    try w.int(cpu.hi);
    try w.int(cpu.lo);
    try w.int(cpu.cycles);
    try w.int(cpu.bus.sched.gpu_clock_frac);
    for (&cpu.icache) |*line| {
        try w.int(line.tag);
        try w.array(&line.data);
    }
    try w.array(&cpu.cop0.regs);
    try w.array(&cpu.cop2.data_regs);
    try w.array(&cpu.cop2.ctrl_regs);
    try w.array(&cpu.cop2.macs);
}

pub fn loadCpu(cpu: *Cpu, r: *Reader, version: u32) Error!void {
    _ = version;
    try r.array(&cpu.regs);
    cpu.pipeline.pc = try r.int(u32);
    cpu.pipeline.next_pc = try r.int(u32);
    cpu.pipeline.current_pc = try r.int(u32);
    cpu.pipeline.is_delay_slot = try r.flag();
    cpu.pipeline.next_is_delay_slot = try r.flag();
    cpu.load_delay.load_r = try r.int(u5);
    cpu.load_delay.load_v = try r.int(u32);
    cpu.load_delay.delay_r = try r.int(u5);
    cpu.load_delay.delay_v = try r.int(u32);
    cpu.hi = try r.int(u32);
    cpu.lo = try r.int(u32);
    cpu.cycles = try r.int(u64);
    // A whole Scheduler, not just the carry: the backlog belonged to the
    // device state this load replaces, and a zero `downcount` re-derives the
    // deadline on the first step.
    cpu.bus.sched = .{ .gpu_clock_frac = try r.int(u32) };
    for (&cpu.icache) |*line| {
        line.tag = try r.int(u32);
        try r.array(&line.data);
    }
    try r.array(&cpu.cop0.regs);
    try r.array(&cpu.cop2.data_regs);
    try r.array(&cpu.cop2.ctrl_regs);
    try r.array(&cpu.cop2.macs);
}
