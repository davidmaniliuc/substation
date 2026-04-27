const std = @import("std");
const zzssxx = @import("zzssxx");

pub fn main() !void {
    // Setup the Allocator
    const allocator = std.heap.page_allocator;

    // Initialize the Bus and CPU
    const bus = try zzssxx.memory.Bus.init(allocator);
    defer bus.deinit(allocator);
    var cpu = zzssxx.cpu.Cpu.init(bus);

    const bios_bytes = @embedFile("SCPH1001.BIN");
    if (bios_bytes.len != 512 * 1024) {
        @compileError("BIOS file must be exactly 512KB (524288 bytes).");
    }

    @memcpy(bus.bios[0..], bios_bytes[0..bus.bios.len]);

    std.debug.print("BIOS loaded successfully. Booting CPU...\n\n", .{});

    var cycle: u64 = 0;
    while (true) {
        cpu.step();
        cycle += 1;

        if (cycle > 50_000_000) {
            std.debug.print("\n\n--- Paused after 500 million instructions ---\n", .{});
            std.debug.print("Current PC: 0x{X:0>8}\n", .{cpu.pc});
            std.debug.print("BIOS Hits: {}\n", .{zzssxx.cpu.Cpu.bios_hit_count});
            std.debug.print("UART Hits: {}\n", .{zzssxx.memory.Bus.uart_hit_count});
            break;
        }
    }
}
