const std = @import("std");
const ps1 = @import("ps1_core");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var bus = try ps1.memory.Bus.init(allocator);
    var cpu = ps1.cpu.Cpu.init(bus);

    const bios_file = try std.fs.cwd().readFileAlloc(allocator, "SCPH1001.BIN", 512 * 1024);
    @memcpy(bus.bios[0..], bios_file);

    var cycles: usize = 0;
    while (cycles < 10000000) : (cycles += 1) {
        if (cpu.pc == 0x80030000) {
            std.debug.print("Hit 0x80030000 at cycle {}\n", .{cycles});
            break;
        }
        cpu.step();
    }
}
