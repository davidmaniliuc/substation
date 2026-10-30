//! What the emulator thread asks of a machine, as one contract.
//!
//! `RunLoop(M)` is generic over it so the orderings that matter (save before
//! load, the rewind step's shadow, resync and streams, the staged real frame
//! around a runahead group) are tested against a scripted machine that
//! records calls. `HandleMachine` is the real one: each method is one call
//! on the `ps1-capi` handle, the same calls the Swift runner made.

const std = @import("std");
const capi = @import("ps1_capi");
const ps1_core = @import("ps1_core");
const metal = @import("ps1_metal");

const command = ps1_core.gpu.command;
const Display = metal.stream_queue.Display;
const RasterState = metal.rasterizer.Rasterizer.State;
const PendingVram = ps1_core.savestate.Rewind.PendingVram;
const native_pixels = metal.prim_instance.native_pixels;
const card_bytes = @import("cards.zig").bytes;

/// Every `PS1_ERR_*` a machine call returns, by name.
pub const Error = error{
    BadBiosSize,
    BadCue,
    MultiFileCue,
    OutOfMemory,
    BadSbi,
    BadMemcardSize,
    BadSlot,
    StateBadMagic,
    StateVersion,
    StateBios,
    StateDisc,
    StateCorrupt,
    StateNoSpace,
    EngineUnavailable,
    BadChd,
    NoSnapshot,
    NoHistory,
    BadPpf,
    PpfMismatch,
    StatePatch,
    BadExe,
};

const codes = [_]struct { i32, Error }{
    .{ capi.PS1_ERR_BAD_BIOS_SIZE, error.BadBiosSize },
    .{ capi.PS1_ERR_BAD_CUE, error.BadCue },
    .{ capi.PS1_ERR_MULTI_FILE_CUE, error.MultiFileCue },
    .{ capi.PS1_ERR_OOM, error.OutOfMemory },
    .{ capi.PS1_ERR_BAD_SBI, error.BadSbi },
    .{ capi.PS1_ERR_BAD_MEMCARD_SIZE, error.BadMemcardSize },
    .{ capi.PS1_ERR_BAD_SLOT, error.BadSlot },
    .{ capi.PS1_ERR_STATE_BAD_MAGIC, error.StateBadMagic },
    .{ capi.PS1_ERR_STATE_VERSION, error.StateVersion },
    .{ capi.PS1_ERR_STATE_BIOS, error.StateBios },
    .{ capi.PS1_ERR_STATE_DISC, error.StateDisc },
    .{ capi.PS1_ERR_STATE_CORRUPT, error.StateCorrupt },
    .{ capi.PS1_ERR_STATE_NO_SPACE, error.StateNoSpace },
    .{ capi.PS1_ERR_ENGINE_UNAVAILABLE, error.EngineUnavailable },
    .{ capi.PS1_ERR_BAD_CHD, error.BadChd },
    .{ capi.PS1_ERR_NO_SNAPSHOT, error.NoSnapshot },
    .{ capi.PS1_ERR_NO_HISTORY, error.NoHistory },
    .{ capi.PS1_ERR_BAD_PPF, error.BadPpf },
    .{ capi.PS1_ERR_PPF_MISMATCH, error.PpfMismatch },
    .{ capi.PS1_ERR_STATE_PATCH, error.StatePatch },
    .{ capi.PS1_ERR_BAD_EXE, error.BadExe },
};

/// `PS1_OK` is success; an unknown negative code reads as corruption, the
/// most conservative thing a caller can be told.
pub fn fromCode(code: i32) Error!void {
    if (code >= 0) return;
    for (codes) |c| if (c[0] == code) return c[1];
    return error.StateCorrupt;
}

/// Back to the ABI's numbering.
pub fn errorCode(err: Error) i32 {
    for (codes) |c| if (c[1] == err) return c[0];
    unreachable;
}

/// A disc as the frontend hands it over. `bin` is BORROWED for as long as the
/// machine runs from it (the handle keeps slices into it) and `release` is
/// called once it is not; `cue`, `sbi` and `ppf` are read during the call.
pub const DiscBytes = struct {
    bin: []const u8,
    release: ?*const fn (?*anyopaque) callconv(.c) void = null,
    release_ctx: ?*anyopaque = null,
    cue: ?[]const u8 = null,
    sbi: ?[]const u8 = null,
    ppf: ?[]const u8 = null,

    pub fn releaseBin(self: DiscBytes) void {
        if (self.release) |f| f(self.release_ctx);
    }
};

/// An executable booted in place of a disc. Both are read during the call;
/// `libps` is empty when the program has none beside it.
pub const ExeBytes = struct {
    exe: []const u8,
    libps: []const u8 = &.{},
};

/// The nine PGXP switches and the tolerance, re-applied every frame. The
/// vertex cache is NOT here: it crosses only on change (`setVertexCache`).
pub const Pgxp = struct {
    enabled: bool = false,
    cpu: bool = false,
    culling: bool = false,
    /// A negative tolerance is the core's "none".
    tolerance: f32 = -1,
    texture_correction: bool = false,
    color_correction: bool = false,
    depth_buffer: bool = false,
    transparent_depth: bool = false,
    disable_2d: bool = false,
    preserve_projection: bool = false,
};

/// `ps1.h`'s `PS1_ENGINE_*` numbering.
pub const Engine = enum(u8) { interpreter = 0, cached = 1, jit = 2 };

const contract = [_][]const u8{
    "runFrame",            "readAudio",         "takeFrameStream", "display",
    "copyVram",            "copyDepth",         "saveStateSize",   "saveState",
    "loadState",           "snapshotMark",      "snapshotReturn",  "reset",
    "swapDisc",            "setButtons",        "setAnalog",       "pressAnalogButton",
    "padStatus",           "takeMemcard",       "loadMemcard",     "applyPgxp",
    "setVertexCache",      "setEngine",         "configureRewind", "rewindStep",
    "rewindFramesCovered", "setVramHost",       "copyVramAsIs",    "copyDepthAsIs",
    "rasterState",         "rewindPendingVram", "rewindFillVram",  "rewindDropVramFrom",
    "setVramMode",
};

/// The comptime check `RunLoop` makes of its machine.
pub fn check(comptime M: type) void {
    for (contract) |name| {
        if (!@hasDecl(M, name)) @compileError(@typeName(M) ++ " does not implement Machine." ++ name);
    }
}

/// The real machine: a `ps1-capi` handle, which the emulator thread is the
/// only caller of.
pub const HandleMachine = struct {
    h: *capi.Handle,

    /// A handle with `bios` loaded and no disc: what the tests run.
    pub fn create(bios: []const u8) Error!HandleMachine {
        return boot(bios, .{});
    }

    pub const Options = struct {
        engine: Engine = .interpreter,
        fast_boot: bool = false,
        /// The VRAM mode the machine boots in; `setVramMode` changes it.
        vram: capi.VramMode = .dual,
    };

    /// The first step of a session's: the engine and fast boot on the
    /// machine BEFORE its BIOS, and so before any resume state loads. The
    /// load restores the I-cache as the saving machine held it, and a later
    /// engine switch would flush it. A refused engine leaves the
    /// interpreter, as the Swift launch did.
    pub fn boot(bios: []const u8, o: Options) Error!HandleMachine {
        const h = capi.ps1_create() orelse return error.OutOfMemory;
        errdefer capi.ps1_destroy(h);
        _ = capi.ps1_set_cpu_engine(h, @backingInt(o.engine));
        capi.setVramMode(h, o.vram);
        capi.ps1_set_fast_boot(h, @intFromBool(o.fast_boot));
        try fromCode(capi.ps1_load_bios(h, bios.ptr, bios.len));
        return .{ .h = h };
    }

    pub fn destroy(self: *HandleMachine) void {
        capi.ps1_destroy(self.h);
    }

    pub fn runFrame(self: *HandleMachine) void {
        capi.ps1_run_frame(self.h);
    }

    pub fn readAudio(self: *HandleMachine, dst: []f32) usize {
        return capi.ps1_read_audio(self.h, dst.ptr, dst.len);
    }

    /// Once per `runFrame`, unconditionally: the recorder is a drain, and a
    /// frame left untaken stacks onto the next until it overruns.
    pub fn takeFrameStream(self: *HandleMachine) command.Stream {
        return self.h.cpu.bus.gpu.sink.rec.takeFrame();
    }

    pub fn display(self: *HandleMachine) Display {
        var d: capi.Ps1Display = undefined;
        capi.ps1_get_display(self.h, &d);
        return .{ .vram_x = d.vram_x, .vram_y = d.vram_y, .width = d.width, .height = d.height, .depth24 = d.depth24 != 0, .enabled = d.enabled != 0 };
    }

    pub fn copyVram(self: *HandleMachine, dst: *[native_pixels]u16) void {
        capi.ps1_copy_vram(self.h, dst);
    }

    pub fn copyDepth(self: *HandleMachine, dst: *[native_pixels]u32) void {
        capi.ps1_copy_depth(self.h, dst);
    }

    /// `vram.data` with no readback: only for VRAM known complete.
    pub fn copyVramAsIs(self: *HandleMachine, dst: *[native_pixels]u16) void {
        capi.copyVramAsIs(self.h, dst);
    }

    pub fn copyDepthAsIs(self: *HandleMachine, dst: *[native_pixels]u32) void {
        capi.copyDepthAsIs(self.h, dst);
    }

    pub fn rewindPendingVram(self: *HandleMachine) ?PendingVram {
        return capi.rewindPendingVram(self.h);
    }

    pub fn rewindFillVram(self: *HandleMachine, id: u64, pixels: *const [native_pixels]u16) bool {
        return capi.rewindFillVram(self.h, id, pixels);
    }

    pub fn rewindDropVramFrom(self: *HandleMachine, id: u64) void {
        capi.rewindDropVramFrom(self.h, id);
    }

    /// The env and upload cursor every shadow carries to the renderer.
    pub fn rasterState(self: *HandleMachine) RasterState {
        const s = capi.rasterState(self.h);
        return .{ .env = s.env, .transfer = s.transfer };
    }

    pub fn vramStats(self: *HandleMachine) ps1_core.gpu.HostStats {
        return capi.vramStats(self.h);
    }

    /// Between frames, never with a mark held. GPU-only to dual reads the
    /// whole texture back; a change clears the rewind history.
    pub fn setVramMode(self: *HandleMachine, mode: capi.VramMode) void {
        capi.setVramMode(self.h, mode);
    }

    /// The renderer that answers a GPU-only machine's reads, or null.
    pub fn setVramHost(self: *HandleMachine, host: ?ps1_core.gpu.Host) void {
        capi.setVramHost(self.h, host);
    }

    pub fn saveStateSize(self: *HandleMachine) usize {
        return capi.ps1_save_state_size(self.h);
    }

    pub fn saveState(self: *HandleMachine, dst: []u8) Error!usize {
        var written: usize = 0;
        try fromCode(capi.ps1_save_state(self.h, dst.ptr, dst.len, &written));
        return written;
    }

    /// All-or-nothing in the core: an error leaves the machine as it was.
    pub fn loadState(self: *HandleMachine, src: []const u8) Error!void {
        if (src.len == 0) return error.StateBadMagic;
        try fromCode(capi.ps1_load_state(self.h, src.ptr, src.len));
    }

    pub fn snapshotMark(self: *HandleMachine) Error!void {
        try fromCode(capi.ps1_snapshot_mark(self.h));
    }

    pub fn snapshotReturn(self: *HandleMachine) Error!void {
        try fromCode(capi.ps1_snapshot_return(self.h));
    }

    pub fn reset(self: *HandleMachine) void {
        capi.ps1_reset(self.h);
    }

    /// The disc a session boots from, before the machine first runs.
    pub fn loadDisc(self: *HandleMachine, disc: DiscBytes) Error!void {
        try self.discCall(capi.ps1_load_disc, disc);
    }

    /// The executable a session boots in place of a disc, before the
    /// machine first runs.
    pub fn loadExe(self: *HandleMachine, exe: ExeBytes) Error!void {
        try fromCode(capi.ps1_load_exe(self.h, exe.exe.ptr, exe.exe.len, exe.libps.ptr, exe.libps.len));
    }

    pub fn swapDisc(self: *HandleMachine, disc: DiscBytes) Error!void {
        try self.discCall(capi.ps1_swap_disc, disc);
    }

    fn discCall(self: *HandleMachine, comptime f: anytype, disc: DiscBytes) Error!void {
        const cue = disc.cue orelse &.{};
        const sbi = disc.sbi orelse &.{};
        const ppf = disc.ppf orelse &.{};
        try fromCode(f(
            self.h,
            disc.bin.ptr,
            disc.bin.len,
            if (disc.cue != null) cue.ptr else null,
            cue.len,
            if (disc.sbi != null) sbi.ptr else null,
            sbi.len,
            if (disc.ppf != null) ppf.ptr else null,
            ppf.len,
        ));
    }

    pub fn setButtons(self: *HandleMachine, mask: u16) void {
        capi.ps1_set_buttons(self.h, mask);
    }

    pub fn setAnalog(self: *HandleMachine, s: [4]u8) void {
        capi.ps1_set_analog(self.h, s[0], s[1], s[2], s[3]);
    }

    pub fn pressAnalogButton(self: *HandleMachine) void {
        capi.ps1_press_analog_button(self.h);
    }

    /// Packed as the frontend reads it: analog in bit 0, the small motor in
    /// bits 8-15, the large in bits 16-23.
    pub fn padStatus(self: *HandleMachine) u32 {
        var p: capi.Ps1PadStatus = undefined;
        capi.ps1_get_pad_status(self.h, &p);
        return @as(u32, p.analog & 1) | @as(u32, p.small) << 8 | @as(u32, p.large) << 16;
    }

    /// True when the slot had new bytes, which are then in `dst`.
    pub fn takeMemcard(self: *HandleMachine, slot: u1, dst: *[card_bytes]u8) bool {
        return capi.ps1_take_memcard(self.h, slot, dst) == 1;
    }

    pub fn loadMemcard(self: *HandleMachine, slot: u1, src: *const [card_bytes]u8) Error!void {
        try fromCode(capi.ps1_load_memcard(self.h, slot, src, card_bytes));
    }

    /// The nine switches and the tolerance, in the order the Swift runner
    /// applied them every frame.
    pub fn applyPgxp(self: *HandleMachine, p: Pgxp) void {
        const h = self.h;
        capi.ps1_set_pgxp(h, @intFromBool(p.enabled));
        capi.ps1_set_pgxp_cpu(h, @intFromBool(p.cpu));
        capi.ps1_set_pgxp_culling(h, @intFromBool(p.culling));
        capi.ps1_set_pgxp_tolerance(h, p.tolerance);
        capi.ps1_set_pgxp_texture_correction(h, @intFromBool(p.texture_correction));
        capi.ps1_set_pgxp_color_correction(h, @intFromBool(p.color_correction));
        capi.ps1_set_pgxp_depth_buffer(h, @intFromBool(p.depth_buffer));
        capi.ps1_set_pgxp_transparent_depth(h, @intFromBool(p.transparent_depth));
        capi.ps1_set_pgxp_disable_2d(h, @intFromBool(p.disable_2d));
        capi.ps1_set_pgxp_preserve_projection(h, @intFromBool(p.preserve_projection));
    }

    /// Allocates or frees 83 MB: the caller crosses only a CHANGE.
    pub fn setVertexCache(self: *HandleMachine, on: bool) void {
        capi.ps1_set_pgxp_vertex_cache(self.h, @intFromBool(on));
    }

    pub fn setEngine(self: *HandleMachine, e: Engine) Error!void {
        try fromCode(capi.ps1_set_cpu_engine(self.h, @backingInt(e)));
    }

    pub fn configureRewind(self: *HandleMachine, bytes: usize) Error!void {
        try fromCode(capi.ps1_rewind_configure(self.h, bytes));
    }

    /// Back one capture, in place; false when no history is left, and then
    /// nothing changed.
    pub fn rewindStep(self: *HandleMachine) bool {
        return capi.ps1_rewind_step(self.h) == capi.PS1_OK;
    }

    pub fn rewindFramesCovered(self: *HandleMachine) u32 {
        var info: capi.Ps1RewindInfo = undefined;
        capi.ps1_rewind_info(self.h, &info);
        return info.frames_covered;
    }
};
