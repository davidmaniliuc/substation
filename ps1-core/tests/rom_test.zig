const std = @import("std");
const ps1_core = @import("ps1_core");
const options = @import("rom_test_options");

const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;

const TtyCapture = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,

    fn deinit(self: *TtyCapture) void {
        // In Zig 0.16, deinit requires the allocator to be passed
        self.output.deinit(self.allocator);
    }
};

fn ttyCallback(ctx: ?*anyopaque, char: u8) void {
    const capture: *TtyCapture = @ptrCast(@alignCast(ctx.?));
    // In Zig 0.16, append requires the allocator to be passed
    capture.output.append(capture.allocator, char) catch unreachable;
}

fn readTestFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_size + 1)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
}

fn stripCarriageReturns(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var clean: std.ArrayList(u8) = .empty;
    errdefer clean.deinit(allocator);

    for (input) |c| {
        if (c != '\r') try clean.append(allocator, c);
    }

    return clean.toOwnedSlice(allocator);
}

fn firstMismatch(expected: []const u8, actual: []const u8) usize {
    const len = @min(expected.len, actual.len);
    for (expected[0..len], actual[0..len], 0..) |expected_char, actual_char, index| {
        if (expected_char != actual_char) return index;
    }
    return len;
}

fn printExcerpt(label: []const u8, bytes: []const u8, start: usize) void {
    const excerpt_len = @min(bytes.len -| start, 512);
    std.debug.print("{s} len={} excerpt@{}:\n{s}\n", .{ label, bytes.len, start, bytes[start..][0..excerpt_len] });
}

fn runRomTest(allocator: std.mem.Allocator, exe_path: []const u8, log_path: []const u8, max_cycles: u64) !void {
    if (!options.enable_rom_tests) return error.SkipZigTest;

    const bus = try Bus.init(allocator);
    defer bus.deinit(allocator);

    var cpu = Cpu.init(bus);

    const bios_data = try readTestFile(allocator, "SCPH-1001_BIOS_1995_US.bin", 512 * 1024);
    defer allocator.free(bios_data);
    if (bios_data.len != bus.bios.len) return error.InvalidBiosSize;
    @memcpy(bus.bios[0..], bios_data);

    // Boot sequence to init jump tables
    var boot_cycles: u64 = 0;
    while (boot_cycles < 25_000_000) : (boot_cycles += 1) {
        cpu.step();
    }

    var tty_capture = TtyCapture{
        .allocator = allocator,
        // .output relies on the `= .empty` default initialized in the struct
    };
    defer tty_capture.deinit();
    cpu.tty_context = &tty_capture;
    cpu.tty_write_fn = ttyCallback;

    const exe_data = try readTestFile(allocator, exe_path, 10 * 1024 * 1024);
    defer allocator.free(exe_data);
    try cpu.loadExe(exe_data);

    // Run the test
    var cycles: u64 = 0;
    while (cycles < max_cycles) : (cycles += 1) {
        cpu.step();

        // Early exit optimization
        if (cycles % 100_000 == 0) {
            if (std.mem.indexOf(u8, tty_capture.output.items, "Done.\n") != null) {
                break;
            }
        }
    }

    const expected_log_raw = try readTestFile(allocator, log_path, 1024 * 1024);
    defer allocator.free(expected_log_raw);

    const expected_log = try stripCarriageReturns(allocator, expected_log_raw);
    defer allocator.free(expected_log);

    const actual_log = try stripCarriageReturns(allocator, tty_capture.output.items);
    defer allocator.free(actual_log);

    // Trim invisible BOMs, spaces, and newlines from the bounds
    const whitespace_and_bom = " \n\t\xEF\xBB\xBF";
    const expected_trimmed = std.mem.trim(u8, expected_log, whitespace_and_bom);

    // Grab the first 32 characters of the clean expected log to find where the test actually starts
    const sync_marker = expected_trimmed[0..@min(expected_trimmed.len, 32)];
    const start_idx = std.mem.indexOf(u8, actual_log, sync_marker) orelse 0;

    const actual_aligned = actual_log[start_idx..];
    const actual_trimmed = std.mem.trim(u8, actual_aligned, whitespace_and_bom);

    if (!std.mem.eql(u8, expected_trimmed, actual_trimmed)) {
        const mismatch = firstMismatch(expected_trimmed, actual_trimmed);
        const excerpt_start = mismatch -| 80;
        std.debug.print("\n=== ROM TEST FAILED: {s} ===\n", .{exe_path});
        std.debug.print("first mismatch at byte {}\n", .{mismatch});
        printExcerpt("EXPECTED", expected_trimmed, excerpt_start);
        printExcerpt("GOT", actual_trimmed, excerpt_start);
        return error.RomOutputMismatch;
    }
}

test "ROM: CPU - Access Time" {
    try runRomTest(
        std.testing.allocator,
        "test-roms/cpu/access-time/access-time.exe",
        "test-roms/cpu/access-time/psx.log",
        10_000_000,
    );
}

test "ROM: CPU - COP" {
    try runRomTest(
        std.testing.allocator,
        "test-roms/cpu/cop/cop.exe",
        "test-roms/cpu/cop/psx.log",
        10_000_000,
    );
}

test "ROM: CPU - CODE IN IO" {
    try runRomTest(
        std.testing.allocator,
        "test-roms/cpu/code-in-io/code-in-io.exe",
        "test-roms/cpu/code-in-io/psx.log",
        10_000_000,
    );
}

test "ROM: CPU - IO ACCESS BITWIDTH" {
    try runRomTest(
        std.testing.allocator,
        "test-roms/cpu/io-access-bitwidth/io-access-bitwidth.exe",
        "test-roms/cpu/io-access-bitwidth/psx.log",
        10_000_000,
    );
}

test "ROM: DMA - DPCR" {
    try runRomTest(
        std.testing.allocator,
        "test-roms/dma/dpcr/dpcr.exe",
        "test-roms/dma/dpcr/psx.log",
        10_000_000,
    );
}
