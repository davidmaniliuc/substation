//! Byte offsets the emitted code addresses: `Cpu` through x19, `Pins`
//! through x22. The checks below fail the build when one outgrows the
//! unsigned-offset form that reaches it.

const std = @import("std");
const Pins = @import("../cache.zig").Pins;
const Cpu = @import("../../cpu/cpu.zig").Cpu;
const Block = @import("../block.zig").Block;
const Value = @import("../../pgxp/pgxp.zig").Value;
const Pipeline = @FieldType(Cpu, "pipeline");
const LoadDelay = @FieldType(Cpu, "load_delay");

/// `ram` and `scratchpad`: the prologue loads both with one `ldp`.
pub const pins_ram = @offsetOf(Pins, "ram");
pub const pins_running = @offsetOf(Pins, "running");
pub const pins_downcount = @offsetOf(Pins, "downcount");
pub const pins_link_site = @offsetOf(Pins, "link_site");
pub const pins_budget = @offsetOf(Pins, "budget");
pub const pins_link_pc = @offsetOf(Pins, "link_pc");
pub const pins_ram_blocks = @offsetOf(Pins, "ram_blocks");
pub const block_start_pc = @offsetOf(Block, "start_pc");
pub const block_link_entry = @offsetOf(Block, "link_entry");

pub fn reg(r: u5) u32 {
    return @offsetOf(Cpu, "regs") + @as(u32, r) * 4;
}
pub const pc = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "pc");
pub const next_pc = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "next_pc");
pub const current_pc = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "current_pc");
pub const is_delay_slot = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "is_delay_slot");
pub const next_is_delay_slot = @offsetOf(Cpu, "pipeline") + @offsetOf(Pipeline, "next_is_delay_slot");
pub const load_r = @offsetOf(Cpu, "load_delay") + @offsetOf(LoadDelay, "load_r");
pub const load_v = @offsetOf(Cpu, "load_delay") + @offsetOf(LoadDelay, "load_v");
pub const delay_r = @offsetOf(Cpu, "load_delay") + @offsetOf(LoadDelay, "delay_r");
pub const delay_v = @offsetOf(Cpu, "load_delay") + @offsetOf(LoadDelay, "delay_v");
pub fn shadow(r: u5) u32 {
    return @offsetOf(Cpu, "gpr_shadow") + @as(u32, r) * @sizeOf(Value);
}
pub const load_shadow = @offsetOf(Cpu, "load_shadow");
pub const delay_shadow = @offsetOf(Cpu, "delay_shadow");
pub fn pinsLoadShadow(slot: u1) u32 {
    return @offsetOf(Pins, "load_shadows") + @as(u32, slot) * @sizeOf(Value);
}

comptime {
    // A store's page test indexes `has_code` from x22 itself.
    std.debug.assert(@offsetOf(Pins, "has_code") == 0);
    std.debug.assert(@offsetOf(Pins, "scratchpad") == pins_ram + 8);
    std.debug.assert(pins_ram % 8 == 0 and pins_ram <= 504);
    // `ldr`/`str` of a doubleword: below 32 KB, and aligned.
    for ([_]u32{ pins_running, pins_downcount, pins_link_site, pins_ram_blocks, block_link_entry }) |o| std.debug.assert(o < 32768 and o % 8 == 0);
    // `ldr`/`str` of a word: below 16 KB. `strb`: below 4 KB.
    for ([_]u32{ reg(31), pc, next_pc, current_pc, load_v, delay_v, pins_budget, pins_link_pc, block_start_pc }) |o| std.debug.assert(o < 16384 and o % 4 == 0);
    for ([_]u32{ is_delay_slot, next_is_delay_slot, load_r, delay_r }) |o| std.debug.assert(o < 4096);
    // A `Value` moves as whole words (`shadow.zig`): every word of each
    // reachable by `ldr`/`str` of a word. A slot's address is also an
    // `add` immediate (the load shim's argument).
    std.debug.assert(@sizeOf(Value) % 4 == 0);
    for ([_]u32{ shadow(31), load_shadow, delay_shadow, pinsLoadShadow(1) }) |o| std.debug.assert(o + @sizeOf(Value) <= 16384 and o % 4 == 0);
    std.debug.assert(pinsLoadShadow(1) < 4096);
    // One byte each: `strb` writes them whole.
    std.debug.assert(@sizeOf(@FieldType(LoadDelay, "load_r")) == 1 and @sizeOf(@FieldType(Pipeline, "is_delay_slot")) == 1);
}
