const Cpu = @import("cpu.zig").Cpu;

pub const CacheLine = struct {
    tag: u32 = 0xFFFFFFFF,
    data: [4]u32 = [_]u32{0} ** 4,
};

pub fn fetchInstruction(cpu: *Cpu, virtual_address: u32) u32 {
    const is_cached = virtual_address < 0xA0000000 or virtual_address >= 0xC0000000;

    if (!is_cached) {
        // Uncached.
        cpu.bus.addWaitCycles(u32, virtual_address, false);
        return cpu.bus.fetchInstruction(virtual_address);
    }

    // Cached!
    const line_index = (virtual_address >> 4) & 0xFF; // 256 lines
    const tag = virtual_address & 0xFFFFF000;
    const word_offset = (virtual_address >> 2) & 3;

    var line = &cpu.icache[line_index];

    if (line.tag == tag) {
        // Cache Hit! 0 wait cycles.
        return line.data[word_offset];
    }

    // Cache Miss!
    // We must fetch 4 words from the bus.
    const line_base = virtual_address & 0xFFFFFFF0;

    // Accurate Burst Read Timing
    const paddr = line_base & 0x1FFFFFFF;
    if (paddr >= 0x00000000 and paddr <= 0x001FFFFF) {
        // RAM Burst: 4 cycles for first word, 1 for each subsequent. Total = 7 cycles.
        cpu.bus.wait_cycles += 7;
    } else {
        // ROM / BIOS: No burst support, so it's 4 sequential reads.
        cpu.bus.addWaitCycles(u32, line_base + 0, false);
        cpu.bus.addWaitCycles(u32, line_base + 4, false);
        cpu.bus.addWaitCycles(u32, line_base + 8, false);
        cpu.bus.addWaitCycles(u32, line_base + 12, false);
    }

    const w0 = cpu.bus.fetchInstruction(line_base + 0);
    const w1 = cpu.bus.fetchInstruction(line_base + 4);
    const w2 = cpu.bus.fetchInstruction(line_base + 8);
    const w3 = cpu.bus.fetchInstruction(line_base + 12);

    // Update cache line
    line.tag = tag;
    line.data[0] = w0;
    line.data[1] = w1;
    line.data[2] = w2;
    line.data[3] = w3;

    return line.data[word_offset];
}

pub fn flush(cpu: *Cpu) void {
    // Isolate Cache enabled: invalidate entire I-cache to mimic BIOS flush
    for (&cpu.icache) |*line| {
        line.tag = 0xFFFFFFFF;
    }
}
