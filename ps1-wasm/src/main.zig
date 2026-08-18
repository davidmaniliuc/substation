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
    if (probes_enabled) ps1_core.memory.store_watch = storeWatch;
}

/// TEMPORARY. Master switch for the Tekken 3 debug scaffolding below (the
/// last-writer shadow map, the `[acc]`/`[dup]` rings, the per-instruction PC
/// ring and DMA attribution scan). Measuring what it costs the browser needs
/// a build with it off.
const probes_enabled = true;

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

/// Hand JS a fresh buffer to copy an upload into, releasing whatever the
/// previous upload of the same kind left behind. The page calls these once
/// per file picked, so re-uploading without this leaks the old copy.
fn allocUploadBuffer(buffer: *[]u8, size: usize, comptime what: []const u8) [*]u8 {
    freeUploadBuffer(buffer);
    buffer.* = std.heap.wasm_allocator.alloc(u8, size) catch @panic("Failed to allocate " ++ what ++ " buffer");
    return buffer.ptr;
}

fn freeUploadBuffer(buffer: *[]u8) void {
    if (buffer.len > 0) {
        std.heap.wasm_allocator.free(buffer.*);
        buffer.* = &[_]u8{};
    }
}

export fn allocExeBuffer(size: usize) [*]u8 {
    return allocUploadBuffer(&exe_buffer, size, "EXE");
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

    freeUploadBuffer(&exe_buffer);
}

export fn allocCdBuffer(size: usize) [*]u8 {
    return allocUploadBuffer(&cd_buffer, size, "CD");
}

export fn allocCueBuffer(size: usize) [*]u8 {
    return allocUploadBuffer(&cue_buffer, size, "CUE");
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

    if (probes_enabled) {
        checkKernelIntegrity();
        logCdHealth();
        checkDmaStall();
    }
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
    if (!probes_enabled) {
        cpu.step();
        return;
    }
    pc_ring[pc_ring_idx & 255] = cpu.pipeline.current_pc;
    pc_ring_idx +%= 1;

    // A linked-list transfer normally starts and finishes well inside one
    // frame, so the once-a-second probe never catches its head. Latch MADR on
    // the rising edge of ch2 instead -- that is the address the game actually
    // handed the DMA, which is where a walk has to start to judge the chain.
    const ch2_active = cpu.bus.dma.channels[2].transfer_active;
    if (ch2_active and !ll_prev_active) {
        ll_start_madr = cpu.bus.dma.channels[2].base_addr;
        ll_starts +%= 1;
    }
    ll_prev_active = ch2_active;

    // Attribution for the last-writer map: a store made while a channel owns
    // the bus came from the controller, and carries the frozen CPU's PC.
    store_from_dma = false;
    for (cpu.bus.dma.channels) |ch| {
        if (ch.transfer_active) {
            store_from_dma = true;
            break;
        }
    }

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

/// Side-effect-free byte peek, for the `sb` render gates.
fn peek8(addr: u32) u8 {
    const paddr = addr & 0x1FFFFFFF;
    if (paddr < cpu.bus.ram.len) return cpu.bus.ram[paddr];
    return 0xFF;
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

// ---------------------------------------------------------------------------
// TEMPORARY stall probe for the Tekken 3 post-KO freeze.
//
// DMA is cooperative here: while a channel is active `isCpuStalled` is true and
// `Cpu.step()` retires no instruction at all, yet it still ticks the
// peripherals. A channel that never reaches its end condition therefore parks
// the PC on one address forever while the drive keeps reading and the SPU keeps
// mixing -- a frozen picture with live audio, which is exactly the reported
// symptom. This names the channel holding the bus and, for a linked list, walks
// the chain so a cycle or an unrecognised terminator is visible directly.
// Remove once that bug is closed.
// ---------------------------------------------------------------------------

/// A tight spin loop can sample the same PC twice by luck, so require three.
const stall_pc_samples = 3;
var stall_prev_pc: u32 = 0;
var stall_same_pc: u32 = 0;
var stall_reported: bool = false;

/// MADR latched on the rising edge of a ch2 linked-list transfer, i.e. the head
/// of the chain as the game handed it over.
var ll_start_madr: u32 = 0;
var ll_prev_active: bool = false;
var ll_starts: u32 = 0;
var region_dumped: bool = false;

/// Last-writer shadow map: for every 32-bit word of RAM, the PC of the most
/// recent 32-bit store to it, with bit 0 set when that store came from a DMA
/// channel rather than the CPU (a PC is always 4-aligned, so bit 0 is free).
///
/// This replaces the earlier heuristic, which only logged stores whose value
/// looked like a tag linking *upward* inside one of two hardcoded pools. That
/// filter had to guess: guess the pools (there is at least a third primitive
/// region around 0x0EC000, and the ring moves between buffers run to run) and
/// guess that the ring closes with a single upward link rather than by reuse of
/// a stale list. A shadow map guesses nothing -- once the ring is found, every
/// node in it can be attributed to the instruction that wrote it.
///
/// 512K words * 4 bytes = 2 MB of wasm memory, which is not worth economising.
var last_writer = [_]u32{0} ** (2 * 1024 * 1024 / 4);

/// The frame each of those stores happened in, so "written this frame" and
/// "left over from an earlier one" are distinguishable. Truncated to 16 bits;
/// the freeze is thousands of frames in but the comparison is only ever
/// between neighbours in one list.
var last_writer_frame = [_]u16{0} ** (2 * 1024 * 1024 / 4);

/// Set while any DMA channel owns the bus, so a store seen by `storeWatch` can
/// be attributed to the controller instead of to the frozen CPU's stale PC.
var store_from_dma: bool = false;

// ---------------------------------------------------------------------------
// The chain accumulator.
//
// Tekken 3 does not use AddPrim against a cleared ordering table for these
// primitives. 0x8003b4f8 keeps a running "what comes after this chain" pointer
// in the display-buffer struct at +0xFBC, reached as
// `*(*(0x800a8c54) + 4) + 0xFBC`. Each emitter call takes that value masked to
// 24 bits as the tail packet's `next` (`0x80037b28`'s `sw t3, 0(a1)`, the store
// that closed the ring), then writes the new chain head back to it.
//
// So the ring means the accumulator already held a pointer into the very chain
// being built. Watching every store to that one word shows whether it is reset
// to 0xFFFFFF at the top of each frame and which frame's reset went missing.
// The address is only known at runtime and moves with the double buffer, so a
// few recently seen values are tracked rather than one.
// ---------------------------------------------------------------------------

const acc_field_offset: u32 = 0xFBC;
const acc_ctx_ptr: u32 = 0x800A8C54;

var acc_addrs = [_]u32{0} ** 4;

/// Re-resolve the accumulator address and remember it if it is new.
fn trackAccumulatorAddress() void {
    const ctx = peek32(acc_ctx_ptr);
    if (ctx & 0x1FFFFF == 0) return;
    const db = peek32(ctx +% 4);
    const addr = (db +% acc_field_offset) & 0x1FFFFC;
    if (addr == 0) return;
    for (acc_addrs) |a| {
        if (a == addr) return;
    }
    var i: usize = acc_addrs.len - 1;
    while (i > 0) : (i -= 1) acc_addrs[i] = acc_addrs[i - 1];
    acc_addrs[0] = addr;
}

const AccHit = struct {
    frame: u32 = 0,
    pc: u32 = 0,
    ra: u32 = 0,
    addr: u32 = 0,
    value: u32 = 0,
    /// 0x800ADEFC -- which pre-built chain the emitter was pointed at. The
    /// buffer flip is nothing but an update of this, and 0x80028bf4 skips that
    /// update whenever 0x80029628 reports the frame gate at zero.
    selector: u32 = 0,
    /// 0x8009542C -- what that gate reads.
    flip_gate: u32 = 0,
    /// 0x800ADFD0 -- gates 0x8003b594, the accumulator write-back.
    wb_gate: u32 = 0,
    /// Emitter stores only: which `jal 0x8003a818` this emit came from, read
    /// off the stack at sp+84. 0x80037b28 is a leaf, so sp still belongs to
    /// 0x8003b4f8 (frame 32) -> 0x8003a87c (frame 32) -> 0x8003a818 (frame 24,
    /// ra at +20). The dispatcher at 0x8002ba64 calls 0x8003a818 from three
    /// gated sites, so 8002bac0 / 8002bad8 / 8002bb04 name the object, and two
    /// emits sharing a site mean that `jal` ran twice -- i.e. the dispatcher
    /// itself re-ran, which is the open question.
    site: u32 = 0,
    /// Store width in bytes. The `obj->0xC3` gates are `sb` and the
    /// round-outcome flags are `sh`, so a hit is not necessarily a word.
    width: u8 = 0,
};

var acc_ring = [_]AccHit{.{}} ** 256;
var acc_idx: usize = 0;
var acc_total: u32 = 0;

/// The frame-pacing globals, as physical RAM offsets. The fault is now known to
/// be a second render pass against a single ordering-table reset, so what
/// matters next is which pacing decision differs on the faulting frame:
///
///   09BC5C  the frame-done counter. 0x80029894 clears it, the submit path at
///           0x80029874 *increments* it, and 0x800296c4 clears it again and
///           then spins (burning a PRNG at 0x8004ce54) until it goes non-zero.
///           0x8002983c branches on it being already set -- an explicit
///           frame-overrun path, and the likeliest way a second pass happens.
///           Read by 0x800295f4, which returns `counter >= 2` and is exactly
///           the "did we miss a frame" test the re-render loop at 0x800508c4
///           branches on. Note the address: the code reaches it as
///           `lui 0x800a` + a *sign-extended negative* displacement
///           (-17316 = -0x43A4), so it is 0x8009BC5C, not 0x800ABC5C. The
///           earlier 0x0ABC5C in this list was that sign error, and it meant
///           the counter never appeared in any [acc] dump.
///   0ADCA4  the emit gate. Non-zero skips the emit at 0x8003a99c entirely;
///           cleared at 0x80029768 and 0x800298a4.
///   09542C  the flip gate 0x80029628 reads.
///   095428  cleared by both 0x800296d8 and 0x800298b0.
///   095424  the budget-measurement enable read at 0x80029678.
const pace_addrs = [_]u32{ 0x09BC5C, 0x0ADCA4, 0x09542C, 0x095428, 0x095424 };

/// The round-phase state machine, decoded out of `SLUS_004.02` on 2026-08-17.
///
/// 0x8003cb84 is a ten-state machine on [0x80096F2C] (jump table at
/// 0x8001A354). Its two emits at 0x8003d1c0/0x8003d1c8 live in **state 4**,
/// which is a one-shot: the emitting branch ends `[0x80096F2C] += 1` and falls
/// straight through into state 5's body. So the faulting frame is the frame the
/// machine passes through state 4, and both emits there are by design.
///
/// The other dispatcher, 0x8002ba64, runs on *both* arms of the
/// `[0x800954A4] != 0` test in 0x8002ae58 (0x8002b030 and 0x8002b1ec), so it
/// always runs too. Its per-fighter gate `obj->0xC3` is therefore the only
/// thing that can keep the frame from emitting an object twice -- which makes
/// the three 0xC3 bytes the whole remaining question.
///
///   096F2C  the round phase itself.
///   09546C  the KO camera mode 0x8003eb2c picks (7 / 6 / 2), read by state 6.
///   0954A4  0x8003cb84's return value, latched at 0x8002af84.
///   0ADBCC  the round clock: `600 * (setting + 2)` at 0x8002a9c8, decremented
///           once per frame at 0x8003cce8 while the fight runs.
///   0ADE78  the round-outcome flags 0x8003e4f8 computes. Bit 0 is set from
///           `slti [0x800ADBCC], 1` -- i.e. it means TIME OUT, and is
///           correctly clear on a health KO. It is the emit gate at
///           0x8003d1b4, so its being clear is expected, not the bug.
///   0A92EB / 0AAB77 / 0AC403  the `obj->0xC3` render gates of the three
///           fighter objects (0x800A9228, +6284, +6284). 0x8002b98c clears all
///           three and sets exactly one; 0x8003ebd0/0x8003ebd4 set both
///           fighters during a normal round.
const game_addrs = [_]u32{
    0x096F2C, 0x09546C, 0x0954A4, 0x0ADBCC, 0x0ADE78,
    0x0A92EB, 0x0AAB77, 0x0AC403,
};

/// `sw t3, 0(a1)` in the emitter at 0x80037b28 -- the store that writes a
/// chain's tail tag, and the one that closed the ring.
const emitter_tag_store_pc: u32 = 0x80037b58;

fn recordAcc(pc: u32, offset: u32, value: u32, width: u8) void {
    acc_ring[acc_idx] = .{
        .width = width,
        .frame = frames_rendered,
        .pc = pc,
        .ra = cpu.regs[31],
        .addr = offset,
        .value = value,
        .selector = peek32(0x800ADEFC),
        .flip_gate = peek32(0x8009542C),
        .wb_gate = peek32(0x800ADFD0),
        .site = if (pc == emitter_tag_store_pc) peek32(cpu.regs[29] +% 84) else 0,
    };
    acc_idx = (acc_idx + 1) % acc_ring.len;
    acc_total +%= 1;
}

fn storeWatch(offset: u32, value: u32, width: u8) void {
    const pc = cpu.pipeline.current_pc;

    // The shadow map answers "which word-store last wrote this word", which is
    // what attributed the ring's nodes; narrow stores would blur that, so they
    // are recorded in the ring below but not here.
    if (width == 4) {
        const i = (offset & 0x1FFFFF) >> 2;
        last_writer[i] = if (store_from_dma) pc | 1 else pc;
        last_writer_frame[i] = @truncate(frames_rendered);
    }

    // Every watched byte/halfword field below is a distinct address, so an
    // exact match is enough -- no need to widen the compare to the store.
    for (game_addrs) |a| {
        if (a == offset) {
            recordAcc(pc, offset, value, width);
            return;
        }
    }

    if (width != 4) return;

    if (pc == emitter_tag_store_pc) {
        recordAcc(pc, offset, value, width);
        // A chain's tail may only ever link *downward* -- to an OT slot far
        // below the pool, or to a packet allocated earlier. The one store that
        // links upward is the one that closes the ring, and it happens exactly
        // once, so this fires on the fault itself rather than near it.
        if ((value & 0xFFFFFF) >= offset) reportDuplicateEmit(offset, value);
        return;
    }
    for (acc_addrs) |a| {
        if (a != 0 and a == offset) {
            recordAcc(pc, offset, value, width);
            return;
        }
    }
    for (pace_addrs) |a| {
        if (a == offset) {
            recordAcc(pc, offset, value, width);
            return;
        }
    }
}

var dup_reported: bool = false;

/// Snapshot of who was on the stack when the ring got closed.
///
/// The emitter itself (0x80037b28) never touches sp, so at this instant sp
/// still belongs to its caller 0x8003b4f8, whose own return address sits at
/// sp+24 and whose saved s0/s1 are at sp+16/sp+20. Everything above that is
/// the frames that led here -- and the whole question is which path called the
/// emitter a second time for the same object without an OT reset in between.
/// Return addresses are recognisable by eye: they are 0x800xxxxx and land just
/// after a jal.
fn reportDuplicateEmit(offset: u32, value: u32) void {
    if (dup_reported) return;
    dup_reported = true;

    const sp = cpu.regs[29];
    std.log.info("[dup] f={d} closes [{x:0>6}] = {x:0>8} sp={x:0>8} ra={x:0>8} gp={x:0>8}", .{
        frames_rendered, offset, value, sp, cpu.regs[31], cpu.regs[28],
    });
    std.log.info("[dup] s0={x:0>8} s1={x:0>8} s2={x:0>8} s3={x:0>8} s4={x:0>8} s5={x:0>8} s6={x:0>8} s7={x:0>8}", .{
        cpu.regs[16], cpu.regs[17], cpu.regs[18], cpu.regs[19],
        cpu.regs[20], cpu.regs[21], cpu.regs[22], cpu.regs[23],
    });
    std.log.info("[dup] gates: ADCA4={x:0>8} ADFD0={x:0>8} AFA88={x:0>8} 9542C={x:0>8} ADEFC={x:0>8} A8C54={x:0>8}", .{
        peek32(0x800ADCA4), peek32(0x800ADFD0), peek32(0x800AFA88),
        peek32(0x8009542C), peek32(0x800ADEFC), peek32(0x800A8C54),
    });
    // The round-phase machine and the gates that decide whether each dispatcher
    // emits. State 4's emit branch ends by incrementing the phase and falling
    // into state 5's body, so by the time 0x8002ba64 closes the ring the phase
    // reads 5 or 6, not 4 -- the [acc] ring's 096F2C stores are what pin the
    // transition frame. The three 0xC3 bytes say which objects 0x8002ba64 goes
    // on to emit a second time.
    std.log.info("[dup] round: state={d} camera={d} ret954A4={x:0>8} clock={d} outcome={x:0>4} C3=[{d} {d} {d}]", .{
        peek32(0x80096F2C),                     peek32(0x8009546C),          peek32(0x800954A4),
        @as(i32, @bitCast(peek32(0x800ADBCC))), peek32(0x800ADE78) & 0xFFFF, peek8(0x800A92EB),
        peek8(0x800AAB77),                      peek8(0x800AC403),
    });
    var i: u32 = 0;
    while (i < 24) : (i += 4) {
        std.log.info("[dup] sp+{d:0>2}: {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
            i * 4,
            peek32(sp +% (i * 4)),
            peek32(sp +% (i * 4) +% 4),
            peek32(sp +% (i * 4) +% 8),
            peek32(sp +% (i * 4) +% 12),
        });
    }

    // The ring is 64 entries and turns over in ~25 frames, so the copy the
    // stall reporter dumps has long lost the frames that led into the fault.
    // Dumping here catches the emit/reset cadence that armed the bad `next`.
    dumpAccumulator();
}

/// Oldest first, so the last line is the write that armed the bad `next`.
fn dumpAccumulator() void {
    std.log.info("[acc] tracked addrs {x:0>6} {x:0>6} {x:0>6} {x:0>6} + pacing, {d} writes total, last {d}:", .{
        acc_addrs[0], acc_addrs[1],                  acc_addrs[2], acc_addrs[3],
        acc_total,    @min(acc_total, acc_ring.len),
    });
    for (0..acc_ring.len) |k| {
        const hit = acc_ring[(acc_idx + k) % acc_ring.len];
        if (hit.addr == 0) continue;
        std.log.info("[acc] f={d} pc={x:0>8} ra={x:0>8} [{x:0>6}].{d} = {x:0>8} sel={d} flip={x} wb={x} site={x:0>8}{s}", .{
            hit.frame,    hit.pc,                                                                           hit.ra,
            hit.addr,     hit.width,                                                                        hit.value,
            hit.selector, hit.flip_gate,                                                                    hit.wb_gate,
            hit.site,     if (hit.width == 4 and (hit.value & 0xFFFFFF) >= hit.addr) " <-- UPWARD" else "",
        });
    }
}

fn writerOf(addr: u32) u32 {
    return last_writer[(addr & 0x1FFFFF) >> 2];
}

fn whoLine(tag: []const u8, addr: u32) void {
    const header = peek32(addr);
    const w = writerOf(addr);
    std.log.info("[who] {s} @{x:0>6} header={x:0>8} count={d} next={x:0>6} writer={x:0>8}{s} f={d}", .{
        tag,                              addr,
        header,                           header >> 24,
        header & 0xFFFFFF,                w & ~@as(u32, 1),
        if (w & 1 != 0) " (DMA)" else "", last_writer_frame[(addr & 0x1FFFFF) >> 2],
    });
}

/// Names the store that closed the ring, in a handful of lines.
///
/// Inside a primitive pool packets are allocated upward and linked *downward*:
/// `AddPrim(ot, p)` sets `p->next` to whatever the OT slot held, so a link is
/// either an OT address far below the pool or an earlier packet at a lower
/// address. Exactly one edge of the ring must therefore point at or above its
/// own node -- that one should have been the 0xFFFFFF terminator.
///
/// Each node is reported with the PC that last stored to it and the frame that
/// store happened in. If the closing node's writer matches its neighbours', a
/// single instruction built a bad link; if it was written frames earlier, the
/// game is walking a list left over from a previous frame.
fn reportRingCause(meet: u32, len: u32) void {
    // Find the closing edge, remembering the three nodes that precede it.
    var prev = [_]u32{0} ** 3;
    var addr = meet;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const next = peek32(addr) & 0xFFFFFF;
        if (next >= addr) {
            for (prev, 0..) |p, k| {
                if (p != 0) whoLine(switch (k) {
                    0 => "prev-3",
                    1 => "prev-2",
                    else => "prev-1",
                }, p);
            }
            whoLine("CLOSES", addr);
            whoLine("target", next & 0x1FFFFC);
            return;
        }
        prev[0] = prev[1];
        prev[1] = prev[2];
        prev[2] = addr;
        addr = next & 0x1FFFFC;
    }
    std.log.info("[who] no upward edge in {d} nodes -- the ring does not close the way a pool would", .{len});
}

fn checkDmaStall() void {
    trackAccumulatorAddress();
    if (frames_rendered % 60 != 0) return;

    // Per-second channel-2 progress. If MADR keeps moving while the PC does
    // not, the DMA is looping round a chain rather than wedged on one word.
    const ch2 = &cpu.bus.dma.channels[2];
    if (ch2.transfer_active) {
        std.log.info("[ch2] f={d} madr={x:0>8} words={x:0>8} next={x:0>6} chcr={x:0>8}", .{
            frames_rendered, ch2.base_addr, ch2.words_remaining, ch2.linked_list_next, ch2.control,
        });
    }
    if (stall_reported) return;

    const pc = cpu.pipeline.pc;
    if (pc == stall_prev_pc) stall_same_pc += 1 else stall_same_pc = 0;
    stall_prev_pc = pc;
    if (stall_same_pc < stall_pc_samples) return;

    const dma = &cpu.bus.dma;
    const stalled = dma.isCpuStalled(cpu.bus);
    stall_reported = true;

    std.log.info("[stall] f={d} pc={x:0>8} cpu_stalled_by_dma={} dpcr={x:0>8} dicr={x:0>8}", .{
        frames_rendered, pc, stalled, dma.dpcr, dma.dicr,
    });

    var culprit: ?usize = null;
    for (0..7) |i| {
        const ch = &dma.channels[i];
        const sync = (ch.control >> 9) & 3;
        std.log.info("[stall] ch{d} active={} sync={d} madr={x:0>8} bcr={x:0>8} chcr={x:0>8} words={x:0>8} next={x:0>6}", .{
            i, ch.transfer_active, sync, ch.base_addr, ch.block_control, ch.control, ch.words_remaining, ch.linked_list_next,
        });
        if (ch.transfer_active and culprit == null) culprit = i;
    }

    const idx = culprit orelse return;
    const ch = &dma.channels[idx];
    if ((ch.control >> 9) & 3 != 2) return;

    // Walk the chain the way doLinkedListWord does. `words_remaining` is the
    // 0xFFFFFFFF header-pending marker when MADR already points at a header;
    // mid-packet the next header is the one latched in linked_list_next.
    const start = if (ch.words_remaining == 0xFFFFFFFF) ch.base_addr & 0x1FFFFC else ch.linked_list_next & 0x1FFFFC;
    var addr = start;
    var n: usize = 0;
    while (n < 12) : (n += 1) {
        const header = peek32(addr);
        std.log.info("[stall] node{d} @{x:0>6} header={x:0>8} count={d} next={x:0>6}", .{
            n, addr, header, header >> 24, header & 0xFFFFFF,
        });
        if ((header & 0xFFFFFF) == 0xFFFFFF) break;
        addr = (header & 0xFFFFFF) & 0x1FFFFC;
    }

    std.log.info("[stall] chain head as started by the game: madr={x:0>8} (ch2 starts so far: {d})", .{
        ll_start_madr, ll_starts,
    });

    walkChain(start);
    dumpAccumulator();
}

/// Raw words of the region the cycle lives in. A GP0 primitive's first payload
/// word carries the command in its top byte (0x20..0x7F), so real geometry is
/// tellable from scribbled-over memory by eye.
fn dumpRegion(lo: u32, hi: u32) void {
    const from = (lo -% 0x40) & 0x1FFFF0;
    const to = @min((hi +% 0x40) & 0x1FFFFC, 0x1FFFF0);
    var addr = from;
    while (addr <= to) : (addr +%= 0x10) {
        std.log.info("[mem] {x:0>6}: {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
            addr, peek32(addr), peek32(addr +% 4), peek32(addr +% 8), peek32(addr +% 12),
        });
    }
}

/// Follows the next-pointer chain using exactly the rule doLinkedListWord uses
/// (stop only on 0xFFFFFF) and reports how it ends: a terminator, a cycle
/// (Floyd, so no bookkeeping memory), or neither within the bound. Also flags a
/// zero next-pointer, which Avocado treats as an end marker and we do not.
fn walkChain(start: u32) void {
    const limit: u32 = 400000;

    var nodes: u32 = 0;
    var saw_zero_next: bool = false;
    var lo: u32 = 0x1FFFFC;
    var hi: u32 = 0;

    var slow = start;
    var fast = start;
    var cycle_at: ?u32 = null;

    while (nodes < limit) : (nodes += 1) {
        const next_slow = peek32(slow) & 0xFFFFFF;
        if (next_slow == 0) saw_zero_next = true;
        if (next_slow == 0xFFFFFF) break;
        slow = next_slow & 0x1FFFFC;
        if (slow < lo) lo = slow;
        if (slow > hi) hi = slow;

        var i: u8 = 0;
        var terminated = false;
        while (i < 2) : (i += 1) {
            const next_fast = peek32(fast) & 0xFFFFFF;
            if (next_fast == 0xFFFFFF) {
                terminated = true;
                break;
            }
            fast = next_fast & 0x1FFFFC;
        }
        if (terminated) break;

        if (slow == fast) {
            cycle_at = slow;
            break;
        }
    }

    if (cycle_at) |meet| {
        // Measure the loop by going round it once from the meeting point.
        var len: u32 = 1;
        var p = (peek32(meet) & 0xFFFFFF) & 0x1FFFFC;
        while (p != meet and len < limit) : (len += 1) {
            p = (peek32(p) & 0xFFFFFF) & 0x1FFFFC;
        }
        std.log.info("[walk] CYCLE at {x:0>6}, loop_len={d}, nodes_before={d} span={x:0>6}..{x:0>6} zero_next={}", .{
            meet, len, nodes, lo, hi, saw_zero_next,
        });
        reportRingCause(meet, len);
    } else if (nodes < limit) {
        std.log.info("[walk] TERMINATED after {d} nodes, span={x:0>6}..{x:0>6} zero_next={}", .{
            nodes, lo, hi, saw_zero_next,
        });
    } else {
        std.log.info("[walk] NO END within {d} nodes, span={x:0>6}..{x:0>6} zero_next={}", .{
            limit, lo, hi, saw_zero_next,
        });
    }
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
        freeUploadBuffer(&exe_buffer);
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
