//! The C ABI for ps1-core.
//!
//! This is a frontend, not part of the core: the core stays free of host
//! assumptions and `include/ps1.h` stays a reviewable artifact that a rename
//! cannot silently break. Nothing here may trap across the boundary — every
//! failure is a negative return code, and `panic` aborts rather than unwinding
//! into Swift, where there is no unwinder to catch it.

const std = @import("std");
const ps1 = @import("ps1_core");

const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;
const Disc = ps1.disc.Disc;

const allocator = std.heap.smp_allocator;

pub const PS1_OK: i32 = 0;
pub const PS1_ERR_BAD_BIOS_SIZE: i32 = -1;
pub const PS1_ERR_BAD_CUE: i32 = -2;
pub const PS1_ERR_MULTI_FILE_CUE: i32 = -3;
pub const PS1_ERR_OOM: i32 = -4;

const bios_bytes = 512 * 1024;

pub const Handle = struct {
    bus: *Bus,
    cpu: Cpu,
    /// Retained so `ps1_reset` can re-copy it: `Bus.init` memsets the struct,
    /// which clears `bus.bios` along with everything else.
    bios: [bios_bytes]u8 = [_]u8{0} ** bios_bytes,
    bios_loaded: bool = false,
    /// Borrowed, never owned — `Disc` holds a slice into the caller's bytes.
    disc: ?Disc = null,
};

fn buildMachine(h: *Handle) void {
    h.cpu = Cpu.init(h.bus);
    if (h.bios_loaded) @memcpy(h.bus.bios[0..], h.bios[0..]);
    if (h.disc) |d| h.bus.cdrom.setDisc(d);
}

pub export fn ps1_create() ?*Handle {
    const h = allocator.create(Handle) catch return null;
    h.* = .{
        .bus = Bus.init(allocator) catch {
            allocator.destroy(h);
            return null;
        },
        .cpu = undefined,
    };
    buildMachine(h);
    return h;
}

pub export fn ps1_destroy(handle: ?*Handle) void {
    const h = handle orelse return;
    h.bus.deinit(allocator);
    allocator.destroy(h);
}

/// The front-panel reset button: rebuilds the machine but keeps the BIOS and
/// the disc. Running with no disc is valid — it boots to the BIOS shell.
pub export fn ps1_reset(h: *Handle) void {
    h.bus.deinit(allocator);
    h.bus = Bus.init(allocator) catch {
        // Re-allocating 2MB+ immediately after freeing it should not fail; if
        // it does there is no valid state to return to and no way to report it.
        @panic("ps1_reset: out of memory rebuilding Bus");
    };
    buildMachine(h);
}

pub export fn ps1_load_bios(h: *Handle, bytes: [*]const u8, len: usize) i32 {
    if (len != bios_bytes) return PS1_ERR_BAD_BIOS_SIZE;
    @memcpy(h.bios[0..], bytes[0..bios_bytes]);
    h.bios_loaded = true;
    @memcpy(h.bus.bios[0..], h.bios[0..]);
    return PS1_OK;
}

/// Attaches a disc. The `.bin` bytes are BORROWED, not copied — `Disc` holds a
/// slice into them, so they must outlive the handle or the next call here.
/// Pass `cue_len == 0` for the raw-`.bin` fallback, which is a single data
/// track at LBA 0 and cannot represent audio tracks.
pub export fn ps1_load_disc(
    h: *Handle,
    bin: [*]const u8,
    bin_len: usize,
    cue: ?[*]const u8,
    cue_len: usize,
) i32 {
    if (bin_len < ps1.constants.sector_bytes) return PS1_ERR_BAD_CUE;

    const data = bin[0..bin_len];
    var d: Disc = undefined;

    if (cue_len > 0) {
        const cue_ptr = cue orelse return PS1_ERR_BAD_CUE;
        const cue_text = cue_ptr[0..cue_len];

        const files = ps1.disc.countCueFiles(cue_text);
        if (files == 0) return PS1_ERR_BAD_CUE;
        if (files > 1) return PS1_ERR_MULTI_FILE_CUE;

        // `initFromCue` silently falls back to a single data track on a cue it
        // cannot parse, so a cue with no TRACK line has to be caught here.
        if (std.mem.indexOf(u8, cue_text, "TRACK ") == null) return PS1_ERR_BAD_CUE;

        d = Disc.initFromCue(cue_text, data);
    } else {
        d = Disc.init(data);
    }

    h.disc = d;
    h.cpu.bus.cdrom.setDisc(d);
    return PS1_OK;
}

/// Mirrors `Ps1Display` in ps1.h. `extern struct` pins the C layout.
pub const Ps1Display = extern struct {
    vram_x: u32,
    vram_y: u32,
    width: u32,
    height: u32,
    depth24: u8,
    enabled: u8,
    pal: u8,
    _pad: u8,
};

/// Runs vblank-to-vblank, the same shape as the wasm frontend's `stepFrame`:
/// spin out of any vblank we are already in, then run until the next one.
pub export fn ps1_run_frame(h: *Handle) void {
    if (!h.bios_loaded) return;
    while (h.cpu.bus.gpu.is_vblank) h.cpu.step();
    while (!h.cpu.bus.gpu.is_vblank) h.cpu.step();
}

/// Takes `sio.zig`'s own convention: 0 means PRESSED, 1 means released,
/// 0xFFFF is idle. The ABI deliberately does not re-invent a button enum.
pub export fn ps1_set_buttons(h: *Handle, mask: u16) void {
    h.cpu.bus.sio.setButtons(mask);
}

pub export fn ps1_copy_vram(h: *const Handle, dst: [*]u16) void {
    const src = h.cpu.bus.gpu.vram.data;
    @memcpy(dst[0..src.len], src[0..]);
}

pub export fn ps1_get_display(h: *const Handle, out: *Ps1Display) void {
    const g = &h.cpu.bus.gpu;
    out.* = .{
        .vram_x = g.disp_env.vram_x_start,
        .vram_y = g.disp_env.vram_y_start,
        .width = g.getDisplayWidth(),
        .height = g.getDisplayHeight(),
        .depth24 = @intFromBool((g.disp_env.display_mode & (1 << 4)) != 0),
        .enabled = @intFromBool(!g.disp_env.display_disabled),
        .pal = @intFromBool(!g.is_ntsc),
        ._pad = 0,
    };
}

/// Drains the SPU's output ring into `dst`, returning the number of floats
/// written (interleaved stereo, 44100 Hz).
///
/// The ring's indices belong to the core, not the caller: the wasm frontend
/// exposes them raw and makes JavaScript do the modular arithmetic, which is a
/// wasm-shaped ABI and is not repeated here.
///
/// `max_floats` should be even; an odd value is truncated down so a stereo
/// pair is never split across two calls.
pub export fn ps1_read_audio(h: *Handle, dst: [*]f32, max_floats: usize) usize {
    const spu = &h.cpu.bus.spu;
    const len = spu.output_buffer.len;

    const available = (spu.write_idx + len - spu.read_idx) % len;
    var n = @min(available, max_floats);
    n -= n % 2;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        dst[i] = spu.output_buffer[(spu.read_idx + i) % len];
    }
    spu.read_idx = (spu.read_idx + n) % len;
    return n;
}

/// Nothing may unwind into Swift — there is no unwinder there to catch it.
/// Log to stderr and abort, so a crash is a readable message rather than a
/// corrupted stack.
pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = first_trace_addr;
        std.debug.print("ps1-capi PANIC: {s}\n", .{msg});
        std.process.abort();
    }
}.panicFn);
