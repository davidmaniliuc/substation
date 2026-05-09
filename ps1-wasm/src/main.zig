const std = @import("std");
const ps1_core = @import("ps1_core");

const Bus = ps1_core.memory.Bus;
const Cpu = ps1_core.cpu.Cpu;

extern "env" fn jsConsoleLog(ptr: [*]const u8, len: usize) void;

// We keep global state for the emulator so JS can easily tick it
var bus: *Bus = undefined;
var cpu: Cpu = undefined;
var is_bios_loaded: bool = false;
var exe_buffer: []u8 = &[_]u8{};

// Exporting makes these functions visible to JavaScript
export fn init() void {
    // wasm_allocator is more appropriate for freestanding WASM
    bus = Bus.init(std.heap.wasm_allocator) catch unreachable;
    cpu = Cpu.init(bus);
    is_bios_loaded = false;
    exe_buffer = &[_]u8{};
}

// Allows JS to copy the user-provided BIOS directly into WebAssembly memory
export fn getBiosPtr() [*]u8 {
    return bus.bios[0..].ptr;
}

// Called by JS once a valid BIOS has been copied into memory
export fn setBiosLoaded() void {
    is_bios_loaded = true;
}

export fn setControllerButtons(buttons: u32) void {
    bus.sio.setButtons(@truncate(buttons));
}

export fn allocExeBuffer(size: usize) [*]u8 {
    if (exe_buffer.len > 0) {
        std.heap.wasm_allocator.free(exe_buffer);
        exe_buffer = &[_]u8{};
    }

    exe_buffer = std.heap.wasm_allocator.alloc(u8, size) catch @panic("Failed to allocate EXE buffer");
    return exe_buffer.ptr;
}

export fn loadExeAndRun() void {
    if (exe_buffer.len == 0) return;

    cpu.loadExe(exe_buffer) catch |err| {
        std.log.err("Failed to load PS-EXE: {}", .{err});
    };

    std.heap.wasm_allocator.free(exe_buffer);
    exe_buffer = &[_]u8{};
}

// Called by JS inside requestAnimationFrame (60 times a second)
export fn stepFrame() void {
    if (!is_bios_loaded) return;

    while (cpu.bus.gpu.is_vblank) {
        cpu.step();
    }

    while (!cpu.bus.gpu.is_vblank) {
        cpu.step();
    }
}

// Allows JS to find the VRAM array in WebAssembly Memory
export fn getVramPtr() [*]const u16 {
    return cpu.bus.gpu.getVramPtr();
}

export fn getDisplayWidth() u32 {
    return cpu.bus.gpu.getDisplayWidth();
}

export fn getDisplayHeight() u32 {
    return cpu.bus.gpu.getDisplayHeight();
}

export fn getDisplayVramX() u32 {
    return cpu.bus.gpu.disp_env.vram_x_start;
}

export fn getDisplayVramY() u32 {
    return cpu.bus.gpu.disp_env.vram_y_start;
}

export fn isDisplayEnabled() bool {
    return !cpu.bus.gpu.disp_env.display_disabled;
}

export fn is24BitMode() bool {
    return (cpu.bus.gpu.disp_env.display_mode & (1 << 21)) != 0;
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    jsConsoleLog(msg.ptr, msg.len);
    while (true) {}
}

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;

    var buf: [1024]u8 = undefined;
    if (std.fmt.bufPrint(&buf, format, args)) |text| {
        jsConsoleLog(text.ptr, text.len);
    } else |_| {
        const err_msg = "Log message too long";
        jsConsoleLog(err_msg.ptr, err_msg.len);
    }
}
