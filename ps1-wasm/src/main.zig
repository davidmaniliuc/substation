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
var cd_buffer: []u8 = &[_]u8{};
var cue_buffer: []u8 = &[_]u8{};
var pending_exe_sideload: bool = false;
var frames_rendered: u32 = 0;

// Exporting makes these functions visible to JavaScript
export fn init() void {
    // wasm_allocator is more appropriate for freestanding WASM
    bus = Bus.init(std.heap.wasm_allocator) catch unreachable;
    cpu = Cpu.init(bus);
    is_bios_loaded = false;
    exe_buffer = &[_]u8{};
    cd_buffer = &[_]u8{};
    cue_buffer = &[_]u8{};
    pending_exe_sideload = false;
    frames_rendered = 0;
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

export fn stageExeForSideload() void {
    if (exe_buffer.len == 0) return;
    pending_exe_sideload = true;
}

export fn loadExeAndRun() void {
    if (exe_buffer.len == 0) return;

    cpu.loadExe(exe_buffer) catch |err| {
        std.log.err("Failed to load PS-EXE: {}", .{err});
    };

    std.heap.wasm_allocator.free(exe_buffer);
    exe_buffer = &[_]u8{};
}

export fn allocCdBuffer(size: usize) [*]u8 {
    if (cd_buffer.len > 0) {
        std.heap.wasm_allocator.free(cd_buffer);
        cd_buffer = &[_]u8{};
    }

    cd_buffer = std.heap.wasm_allocator.alloc(u8, size) catch @panic("Failed to allocate CD buffer");
    return cd_buffer.ptr;
}

export fn allocCueBuffer(size: usize) [*]u8 {
    if (cue_buffer.len > 0) {
        std.heap.wasm_allocator.free(cue_buffer);
        cue_buffer = &[_]u8{};
    }
    cue_buffer = std.heap.wasm_allocator.alloc(u8, size) catch @panic("Failed to allocate CUE buffer");
    return cue_buffer.ptr;
}

export fn loadCdFromBuffer() void {
    if (cd_buffer.len == 0) return;

    const d = if (cue_buffer.len > 0)
        ps1_core.disc.Disc.initFromCue(cue_buffer, cd_buffer)
    else
        ps1_core.disc.Disc.init(cd_buffer);
    bus.cdrom.setDisc(d);
}

// Called by JS inside requestAnimationFrame (60 times a second)
export fn stepFrame() void {
    if (!is_bios_loaded) return;
    frames_rendered += 1;

    while (cpu.bus.gpu.is_vblank) {
        checkPendingExe();
        stepProbed();
    }

    while (!cpu.bus.gpu.is_vblank) {
        checkPendingExe();
        stepProbed();
    }

    checkKernelIntegrity();
    logCdHealth();
}

// ---------------------------------------------------------------------------
// TEMPORARY crash probe for the Crash "Jungle Rollers" load hang.
// Answers two questions when the CPU parks in an exception storm:
//   1. what exactly faulted first (EPC / BadVaddr / instruction / recent PCs)
//   2. was low RAM (the BIOS kernel + exception vectors) overwritten first,
//      and if so by whom (CPU store vs. an in-flight DMA3 CD transfer)
// Remove once that bug is closed.
// ---------------------------------------------------------------------------

const kernel_watch_len = 0x10000; // first 64K of RAM is BIOS-kernel reserved
const watch_line = 16;
const watch_lines = kernel_watch_len / watch_line;

/// Frames spent learning which kernel lines the BIOS legitimately writes.
/// The window deliberately spans boot + title + a whole first level load, so
/// the kernel bookkeeping a load does is learned as normal; the hang we are
/// hunting lands far later (~frame 26000 in the reported run).
const calibrate_from = 60;
const calibrate_to = 9000;

var kernel_prev: [kernel_watch_len]u8 = [_]u8{0} ** kernel_watch_len;
var kernel_mutable: [watch_lines]bool = [_]bool{false} ** watch_lines;
/// Report several, not just the first: a benign late-calibrating kernel line
/// must not mask the write we are actually hunting.
const kernel_report_limit = 8;
var kernel_reports: u32 = 0;
var fault_reported: bool = false;

var pc_ring: [256]u32 = [_]u32{0} ** 256;
var pc_ring_idx: usize = 0;

fn stepProbed() void {
    pc_ring[pc_ring_idx & 255] = cpu.pipeline.current_pc;
    pc_ring_idx +%= 1;

    cpu.step();

    // enterException() parks PC on the vector; ExcCode 0 (Interrupt) and 8
    // (Syscall) are the only two this BIOS kernel dispatches, everything else
    // is fatal and hangs the machine.
    if (!fault_reported and cpu.pipeline.pc == 0x80000080) {
        const cause = cpu.cop0.readReg(.cause);
        const exc_code = (cause >> 2) & 0x1F;
        if (exc_code != 0 and exc_code != 8) reportFault(cause, exc_code);
    }
}

/// Side-effect-free memory peek — reads the backing arrays directly so probing
/// cannot disturb MMIO, FIFOs or waitstate accounting.
fn peek32(addr: u32) u32 {
    const paddr = (addr & 0x1FFFFFFF) & ~@as(u32, 3);
    if (paddr < cpu.bus.ram.len) {
        return std.mem.readInt(u32, cpu.bus.ram[paddr..][0..4], .little);
    }
    if (paddr >= 0x1FC00000 and paddr < 0x1FC80000) {
        return std.mem.readInt(u32, cpu.bus.bios[paddr - 0x1FC00000 ..][0..4], .little);
    }
    return 0xDEADBEEF;
}

fn reportFault(cause: u32, exc_code: u32) void {
    fault_reported = true;
    const epc = cpu.cop0.readReg(.epc);
    std.log.info("[fault] f={d} cause={x:0>8} exc={d} epc={x:0>8} badv={x:0>8} sr={x:0>8}", .{
        frames_rendered,
        cause,
        exc_code,
        epc,
        cpu.cop0.readReg(.badvaddr),
        cpu.cop0.readReg(.sr),
    });
    std.log.info("[fault] instr@epc: {x:0>8} {x:0>8} [{x:0>8}] {x:0>8} {x:0>8}", .{
        peek32(epc -% 8), peek32(epc -% 4), peek32(epc), peek32(epc +% 4), peek32(epc +% 8),
    });
    std.log.info("[fault] ra={x:0>8} sp={x:0>8} gp={x:0>8} k0={x:0>8} k1={x:0>8} at={x:0>8}", .{
        cpu.regs[31], cpu.regs[29], cpu.regs[28], cpu.regs[26], cpu.regs[27], cpu.regs[1],
    });

    // The kernel's exception plumbing: vector stub, handler entry, chain head.
    std.log.info("[fault] vec@80: {x:0>8} {x:0>8} {x:0>8} {x:0>8} | 0x108={x:0>8} 0x100={x:0>8}", .{
        peek32(0x80000080), peek32(0x80000084), peek32(0x80000088), peek32(0x8000008C),
        peek32(0x80000108), peek32(0x80000100),
    });
    std.log.info("[fault] handler@c80: {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
        peek32(0x80000C80), peek32(0x80000C84), peek32(0x80000C88),
        peek32(0x80000C8C), peek32(0x80000C90), peek32(0x80000C94),
    });

    // Most recent PCs, oldest first, so the path into the fault is readable.
    var buf: [16]u32 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        buf[i] = pc_ring[(pc_ring_idx -% 16 +% i) & 255];
    }
    std.log.info("[fault] pcs: {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
        buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7],
    });
    std.log.info("[fault] pcs: {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
        buf[8], buf[9], buf[10], buf[11], buf[12], buf[13], buf[14], buf[15],
    });
}

/// Learns which lines of kernel RAM the BIOS writes during normal operation,
/// then reports the first write to any line outside that set. A store into
/// kernel code or the exception vectors shows up here one frame after it lands.
fn checkKernelIntegrity() void {
    if (frames_rendered < calibrate_from) {
        @memcpy(&kernel_prev, cpu.bus.ram[0..kernel_watch_len]);
        return;
    }

    const calibrating = frames_rendered <= calibrate_to;
    var line: usize = 0;
    while (line < watch_lines) : (line += 1) {
        const off = line * watch_line;
        const now = cpu.bus.ram[off..][0..watch_line];
        if (std.mem.eql(u8, now, kernel_prev[off..][0..watch_line])) continue;

        if (calibrating) {
            kernel_mutable[line] = true;
        } else if (!kernel_mutable[line] and kernel_reports < kernel_report_limit) {
            kernel_reports += 1;
            const ch = &cpu.bus.dma.channels[3];
            std.log.info("[kernel] f={d} unexpected write at {x:0>8} pc={x:0>8}", .{
                frames_rendered, @as(u32, @intCast(off)), cpu.pipeline.pc,
            });
            std.log.info("[kernel] was: {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
                std.mem.readInt(u32, kernel_prev[off..][0..4], .little),
                std.mem.readInt(u32, kernel_prev[off + 4 ..][0..4], .little),
                std.mem.readInt(u32, kernel_prev[off + 8 ..][0..4], .little),
                std.mem.readInt(u32, kernel_prev[off + 12 ..][0..4], .little),
            });
            std.log.info("[kernel] now: {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
                std.mem.readInt(u32, now[0..4], .little),
                std.mem.readInt(u32, now[4..8], .little),
                std.mem.readInt(u32, now[8..12], .little),
                std.mem.readInt(u32, now[12..16], .little),
            });
            std.log.info("[kernel] dma3 madr={x:0>8} bcr={x:0>8} chcr={x:0>8} | cd drive={s} ptr={d}/{d}", .{
                ch.base_addr,                              ch.block_control,                      ch.control,
                @tagName(cpu.bus.cdrom.drive.drive_state), cpu.bus.cdrom.fifos.sector_buffer_ptr, cpu.bus.cdrom.fifos.sector_buffer_len,
            });
        }
    }
    @memcpy(&kernel_prev, cpu.bus.ram[0..kernel_watch_len]);
}

/// TEMPORARY diagnostic for the Crash "Jungle Rollers" load hang. Prints one
/// line per second to the browser console so a hang can be caught in the act.
/// Remove once that bug is closed.
fn logCdHealth() void {
    if (frames_rendered % 60 != 0) return;
    const cd = &cpu.bus.cdrom;
    const ch = &cpu.bus.dma.channels[3];
    std.log.info(
        "[cd] f={d} pc={x:0>8} cause={x:0>8} irq={x:0>4}/{x:0>4} | drive={s} q={d} ovf={d} inte={x:0>2} mode={x:0>2} pos={x:0>2}:{x:0>2}:{x:0>2} | fifo empty={} ptr={d}/{d} | dma3 madr={x:0>8} bcr={x:0>8} chcr={x:0>8} dicr={x:0>8}",
        .{
            frames_rendered,
            cpu.pipeline.pc,
            cpu.cop0.readReg(.cause),
            cpu.bus.interrupts.stat,
            cpu.bus.interrupts.mask,
            @tagName(cd.drive.drive_state),
            cd.fifos.irq_queue.count,
            cd.fifos.irq_queue.overflow_count,
            cd.regs.irq_enable,
            cd.drive.mode,
            cd.drive.current_pos.m,
            cd.drive.current_pos.s,
            cd.drive.current_pos.f,
            cd.fifos.data_fifo_empty,
            cd.fifos.sector_buffer_ptr,
            cd.fifos.sector_buffer_len,
            ch.base_addr,
            ch.block_control,
            ch.control,
            cpu.bus.dma.dicr,
        },
    );
}

fn checkPendingExe() void {
    // Wait ~1 second (60 frames) for the BIOS to initialize the A/B/C function tables
    // and memory before we inject the EXE. This skips the animation but prevents a crash.
    if (pending_exe_sideload and frames_rendered > 60) {
        cpu.loadExe(exe_buffer) catch |err| {
            std.log.err("Failed to sideload PS-EXE: {}", .{err});
        };
        std.heap.wasm_allocator.free(exe_buffer);
        exe_buffer = &[_]u8{};
        pending_exe_sideload = false;
    }
}

// Allows JS to find the VRAM array in WebAssembly Memory
export fn getVramPtr() [*]const u16 {
    return cpu.bus.gpu.getVramPtr();
}

export fn getAudioBufferPtr() [*]const f32 {
    return &cpu.bus.spu.output_buffer;
}

export fn getAudioBufferSize() usize {
    return cpu.bus.spu.output_buffer.len;
}

export fn getAudioWriteIdx() usize {
    return cpu.bus.spu.write_idx;
}

export fn getAudioReadIdx() usize {
    return cpu.bus.spu.read_idx;
}

export fn setAudioReadIdx(idx: usize) void {
    cpu.bus.spu.read_idx = idx % cpu.bus.spu.output_buffer.len;
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
    // Color depth is bit 4 of GP1(08h) parameter
    return (cpu.bus.gpu.disp_env.display_mode & (1 << 4)) != 0;
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
