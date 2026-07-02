const std = @import("std");
const ps1 = @import("ps1_core");

// Execution-diff trace harness: boots a runtime-loaded BIOS (+ optional disc)
// and logs every A0/B0/C0 BIOS syscall in the SAME text format as the avocado
// headless tracer, so the two streams can be diffed to localize the boot
// divergence (blocker #3: the post-ResetCallback IEC-stuck deadlock).
//
// Usage: ps1-trace <bios.bin> [disc.bin] [max_instructions] [out_syscalls.txt]
// TTY goes to stderr; the syscall trace goes to the out file (default /tmp/zig_syscalls.txt).

fn ttyWrite(ctx: ?*anyopaque, ch: u8) void {
    _ = ctx;
    std.debug.print("{c}", .{ch});
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var argv = std.ArrayList([]const u8).empty;
    var it = init.minimal.args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |arg| try argv.append(a, arg);

    if (argv.items.len < 1) {
        std.debug.print("usage: ps1-trace <bios.bin> [disc.bin] [max_instr] [out.txt]\n", .{});
        return;
    }
    const bios_path = argv.items[0];
    const disc_path: ?[]const u8 = if (argv.items.len > 1 and argv.items[1].len > 0) argv.items[1] else null;
    const max_instr: u64 = if (argv.items.len > 2) try std.fmt.parseInt(u64, argv.items[2], 10) else 120_000_000;
    const out_path: []const u8 = if (argv.items.len > 3) argv.items[3] else "/tmp/zig_syscalls.txt";

    var bus = try ps1.memory.Bus.init(a);
    var cpu = ps1.cpu.Cpu.init(bus);

    const bios = try std.Io.Dir.cwd().readFileAlloc(init.io, bios_path, a, .limited(1024 * 1024));
    if (bios.len != 512 * 1024) {
        std.debug.print("BIOS must be 512KB, got {}\n", .{bios.len});
        return;
    }
    @memcpy(bus.bios[0..], bios);
    cpu.tty_write_fn = ttyWrite;

    if (disc_path) |dp| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, dp, a, .limited(700 * 1024 * 1024));
        const d = ps1.disc.Disc.init(bytes);
        cpu.bus.cdrom.setDisc(d);
        std.debug.print("[trace] disc: {} sectors\n", .{bytes.len / 2352});
    }
    std.debug.print("[trace] bios: {s}\n", .{bios_path});

    // Optional windowed PC trace via args: [4]=pc_start [5]=pc_end [6]=pc_out.
    const pc_start: u64 = if (argv.items.len > 4) try std.fmt.parseInt(u64, argv.items[4], 10) else 0;
    const pc_end: u64 = if (argv.items.len > 5) try std.fmt.parseInt(u64, argv.items[5], 10) else 0;
    const pc_out: ?[]const u8 = if (argv.items.len > 6) argv.items[6] else null;
    var pc_lines = std.ArrayList(u8).empty;

    var lines = std.ArrayList(u8).empty;

    var i: u64 = 0;
    while (i < max_instr) : (i += 1) {
        if (pc_out != null and i >= pc_start and i <= pc_end) {
            const ie = cpu.cop0.readReg(.sr) & 1;
            const pl = try std.fmt.allocPrint(a, "{d} {x:0>8} ie={d}\n", .{ i, cpu.pc, ie });
            try pc_lines.appendSlice(a, pl);
        }
        const m = cpu.pc & 0x1FFFFFFF;
        if (m == 0xA0 or m == 0xB0 or m == 0xC0) {
            const kind: u8 = if (m == 0xA0) 'A' else if (m == 0xB0) 'B' else 'C';
            const func: u8 = @truncate(cpu.readReg(.t1));
            const line = try std.fmt.allocPrint(
                a,
                "@{d} {c}:{x:0>2} a0={x:0>8} a1={x:0>8} a2={x:0>8} a3={x:0>8} ra={x:0>8} sr={x:0>8}\n",
                .{
                    i,                    kind,
                    func,                 cpu.readReg(.a0),
                    cpu.readReg(.a1),     cpu.readReg(.a2),
                    cpu.readReg(.a3),     cpu.readReg(.ra),
                    cpu.cop0.readReg(.sr),
                },
            );
            try lines.appendSlice(a, line);
        }
        cpu.step();
    }

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = lines.items });
    if (pc_out) |po| {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = po, .data = pc_lines.items });
        std.debug.print("[trace] wrote {} PC lines to {s}\n", .{ pc_lines.items.len, po });
    }
    std.debug.print("\n[trace] wrote {} bytes of syscalls to {s} (ran {} instr)\n", .{ lines.items.len, out_path, i });
}
