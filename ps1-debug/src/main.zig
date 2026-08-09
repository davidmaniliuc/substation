const std = @import("std");
const ps1_core = @import("ps1_core");

pub fn main(init: std.process.Init) !void {
    // Setup the Allocator
    const allocator = std.heap.page_allocator;

    // Initialize the Bus and CPU
    const bus = try ps1_core.memory.Bus.init(allocator);
    defer bus.deinit(allocator);
    var cpu = ps1_core.cpu.Cpu.init(bus);

    const bios_bytes = @embedFile("BIOS.BIN");
    if (bios_bytes.len != 512 * 1024) {
        @compileError("BIOS file must be exactly 512KB (524288 bytes).");
    }

    @memcpy(bus.bios[0..], bios_bytes[0..bus.bios.len]);

    std.debug.print("BIOS loaded successfully. Booting CPU...\n\n", .{});

    // Optional disc loading: if a path is provided as the first CLI argument,
    // load it as a raw .bin disc image and call setDisc() so the BIOS CD-boot
    // path is exercised rather than an EXE sideload.
    var args_it = init.minimal.args.iterate();
    _ = args_it.skip(); // skip argv[0] (program name)
    if (args_it.next()) |disc_path| {
        const max_disc_bytes: usize = 700 * 1024 * 1024; // 700 MB ceiling
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            disc_path,
            allocator,
            .limited(max_disc_bytes),
        );
        // Note: `bytes` is intentionally not freed — Disc borrows the slice and
        // the program exits at the end of the run loop, so this is safe.
        const d = ps1_core.disc.Disc.init(bytes);
        cpu.bus.cdrom.setDisc(d);
        cpu.bus.cdrom.debug_enable = true;
        std.debug.print("Disc loaded: {} sectors ({} bytes)\n", .{ bytes.len / 2352, bytes.len });
    }

    var cycle: u64 = 0;
    while (true) {
        cpu.step();
        cycle += 1;

        if (cycle > 150_000_000) {
            std.debug.print("\n\n--- Paused after 150 million instructions ---\n", .{});
            std.debug.print("Current PC: 0x{x:0>8}\n", .{cpu.pipeline.pc});
            std.debug.print("BIOS Hits: {}\n", .{ps1_core.cpu.Cpu.bios_hit_count});
            break;
        }
    }
}
