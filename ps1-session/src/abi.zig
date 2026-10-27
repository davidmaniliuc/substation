//! The session C ABI (`ps1-capi/include/ps1_session.h`). Each export
//! forwards to `Session`; this file only translates C shapes into Zig ones.
//! Nothing here traps across the boundary: a bad enum value is ignored, and
//! every failure is a negative code.

const std = @import("std");
const builtin = @import("builtin");
const capi = @import("ps1_capi");
const metal = @import("ps1_metal");
const session = @import("session.zig");
const machine = @import("machine.zig");
const requests = @import("requests.zig");
const events = @import("events.zig");

const Session = session.Session;
const DiscBytes = session.DiscBytes;
const VramReadbacks = @import("settings.zig").VramReadbacks;
const pi = metal.prim_instance;

/// The testing allocator under test, so a leaked session fails the run.
const allocator = if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;

pub const Ps1DiscBytes = extern struct {
    bin: ?[*]const u8,
    bin_len: usize,
    release: ?*const fn (?*anyopaque) callconv(.c) void,
    release_ctx: ?*anyopaque,
    cue: ?[*]const u8,
    cue_len: usize,
    sbi: ?[*]const u8,
    sbi_len: usize,
    ppf: ?[*]const u8,
    ppf_len: usize,

    /// Null for a disc with no bin: the BIOS shell.
    fn toZig(self: *const Ps1DiscBytes) ?DiscBytes {
        const bin = self.bin orelse return null;
        return .{
            .bin = bin[0..self.bin_len],
            .release = self.release,
            .release_ctx = self.release_ctx,
            .cue = optSlice(self.cue, self.cue_len),
            .sbi = optSlice(self.sbi, self.sbi_len),
            .ppf = optSlice(self.ppf, self.ppf_len),
        };
    }
};

pub const Ps1SessionConfig = extern struct {
    bios: [*]const u8,
    bios_len: usize,
    disc: Ps1DiscBytes,
    resume_state: ?[*]const u8,
    resume_len: usize,
    card_dir: [*:0]const u8,
    ns_view: ?*anyopaque,
    band_height: f64,
    band_edge: f64,
    band_sigma: f64,
    cpu_engine: i32,
    fast_boot: u8,
    on_event: ?events.EventFn,
    event_ctx: ?*anyopaque,
};

pub const Ps1PgxpSettings = extern struct {
    enabled: u8,
    cpu: u8,
    culling: u8,
    vertex_cache: u8,
    texture_correction: u8,
    color_correction: u8,
    depth_buffer: u8,
    transparent_depth: u8,
    disable_2d: u8,
    preserve_projection: u8,
    tolerance: f32,
};

fn optSlice(p: ?[*]const u8, len: usize) ?[]const u8 {
    return if (p) |q| q[0..len] else null;
}

fn enumOf(comptime E: type, v: i32) ?E {
    return std.enums.fromInt(E, v);
}

fn configOf(cfg: *const Ps1SessionConfig) session.Config {
    return .{
        .bios = cfg.bios[0..cfg.bios_len],
        .disc = cfg.disc.toZig(),
        .resume_state = optSlice(cfg.resume_state, cfg.resume_len),
        .card_dir = std.mem.span(cfg.card_dir),
        .view = @ptrCast(cfg.ns_view),
        .band = .{ .height = cfg.band_height, .edge = cfg.band_edge, .sigma = cfg.band_sigma },
        .settings = .{ .engine = enumOf(machine.Engine, cfg.cpu_engine) orelse .interpreter },
        .fast_boot = cfg.fast_boot != 0,
        .events = if (cfg.on_event) |f| .{ .on_event = f, .ctx = cfg.event_ctx } else null,
    };
}

fn codeOf(err: session.Error) i32 {
    return switch (err) {
        error.NoMetal => capi.PS1_ERR_NO_METAL,
        error.Audio => capi.PS1_ERR_AUDIO,
        // A thread the OS would not start: out of resources.
        error.Thread => capi.PS1_ERR_OOM,
        else => |e| machine.errorCode(e),
    };
}

fn new(cfg: session.Config, out: **Session) i32 {
    out.* = Session.create(allocator, cfg) catch |err| return codeOf(err);
    return capi.PS1_OK;
}

pub export fn ps1_session_new(cfg: *const Ps1SessionConfig, out: **Session) i32 {
    return new(configOf(cfg), out);
}

/// A session with no audio device, the mixer pulled by the test. Exported
/// from test builds only: the shipped library has no way to make one.
fn newHeadless(cfg: *const Ps1SessionConfig, out: **Session) callconv(.c) i32 {
    var c = configOf(cfg);
    c.audio = .none;
    return new(c, out);
}

comptime {
    if (builtin.is_test) @export(&newHeadless, .{ .name = "ps1_session_new_headless" });
}

pub export fn ps1_session_start(s: *Session) i32 {
    s.start() catch |err| return codeOf(err);
    return capi.PS1_OK;
}

pub export fn ps1_session_free(s: ?*Session) void {
    if (s) |p| p.destroy();
}

// MARK: Setters

/// One field of the settings the host last sent, changed and sent whole.
/// The host's thread is `player`'s only writer, so it reads it unlocked.
fn update(s: *Session, comptime field: []const u8, value: anytype) void {
    var p = s.player;
    @field(p, field) = value;
    s.setSettings(p);
}

pub export fn ps1_session_set_buttons(s: *Session, mask: u16) void {
    s.setButtons(mask);
}

pub export fn ps1_session_set_sticks(s: *Session, lx: u8, ly: u8, rx: u8, ry: u8) void {
    s.setSticks(lx, ly, rx, ry);
}

pub export fn ps1_session_press_analog(s: *Session) void {
    s.pressAnalogButton();
}

pub export fn ps1_session_set_speed(s: *Session, speed: i32) void {
    s.setSpeed(@intCast(std.math.clamp(speed, 1, std.math.maxInt(i32))));
}

pub export fn ps1_session_set_paused(s: *Session, paused: u8) void {
    s.setPaused(paused != 0);
}

pub export fn ps1_session_set_rewinding(s: *Session, rewinding: u8) void {
    s.setRewinding(rewinding != 0);
}

/// The vertex cache crosses to the machine only when it changes, so folding
/// it in here costs the per-frame re-apply nothing.
pub export fn ps1_session_set_pgxp(s: *Session, p: *const Ps1PgxpSettings) void {
    var next = s.player;
    next.vertex_cache = p.vertex_cache != 0;
    next.pgxp = .{
        .enabled = p.enabled != 0,
        .cpu = p.cpu != 0,
        .culling = p.culling != 0,
        .tolerance = p.tolerance,
        .texture_correction = p.texture_correction != 0,
        .color_correction = p.color_correction != 0,
        .depth_buffer = p.depth_buffer != 0,
        .transparent_depth = p.transparent_depth != 0,
        .disable_2d = p.disable_2d != 0,
        .preserve_projection = p.preserve_projection != 0,
    };
    s.setSettings(next);
}

pub export fn ps1_session_set_cpu_engine(s: *Session, engine: i32) void {
    if (enumOf(machine.Engine, engine)) |e| update(s, "engine", e);
}

pub export fn ps1_session_set_vram_mode(s: *Session, mode: i32) void {
    if (enumOf(capi.VramMode, mode)) |m| update(s, "vram_readbacks", @as(VramReadbacks, switch (m) {
        .dual => .on,
        .gpu => .off,
    }));
}

pub export fn ps1_session_set_rewind_budget(s: *Session, bytes: usize) void {
    update(s, "rewind_budget", bytes);
}

pub export fn ps1_session_set_runahead(s: *Session, frames: i32) void {
    update(s, "runahead", @as(u32, @intCast(@max(frames, 0))));
}

pub export fn ps1_session_set_gain(s: *Session, gain: f32) void {
    update(s, "gain", gain);
}

pub export fn ps1_session_set_dither(s: *Session, mode: i32) void {
    if (enumOf(pi.DitherMode, mode)) |d| update(s, "dither", d);
}

pub export fn ps1_session_set_texture_filter(s: *Session, filter: i32) void {
    if (enumOf(pi.TextureFilter, filter)) |f| update(s, "texture_filter", f);
}

pub export fn ps1_session_set_sprite_filter(s: *Session, filter: i32) void {
    if (enumOf(pi.TextureFilter, filter)) |f| update(s, "sprite_filter", f);
}

pub export fn ps1_session_set_scale(s: *Session, scale: i32) void {
    update(s, "scale", @as(u32, @intCast(std.math.clamp(scale, 1, 8))));
}

pub export fn ps1_session_set_size(s: *Session, w_pt: f64, h_pt: f64, backing_scale: f64) void {
    s.setSize(w_pt, h_pt, backing_scale);
}

pub export fn ps1_session_set_occluded(s: *Session, occluded: u8) void {
    s.setOccluded(occluded != 0);
}

pub export fn ps1_session_set_band_shown(s: *Session, shown: u8) void {
    s.setBandShown(shown != 0);
}

// MARK: Requests

pub export fn ps1_session_request_save(s: *Session, done: requests.SaveDone, ctx: ?*anyopaque) void {
    s.requestSave(done, ctx);
}

pub export fn ps1_session_request_load(s: *Session, state: [*]const u8, len: usize, done: requests.LoadDone, ctx: ?*anyopaque) void {
    s.requestLoad(state[0..len], done, ctx);
}

pub export fn ps1_session_request_reset(s: *Session, done: requests.Done, ctx: ?*anyopaque) void {
    s.requestReset(done, ctx);
}

/// A disc with no bin is refused at once, as the machine would refuse it.
pub export fn ps1_session_request_swap(s: *Session, disc: *const Ps1DiscBytes, done: requests.Done, ctx: ?*anyopaque) void {
    const d = disc.toZig() orelse return done(ctx, capi.PS1_ERR_BAD_CUE);
    s.requestSwap(d, .on, done, ctx);
}

pub export fn ps1_session_request_screenshot(s: *Session, done: session.ScreenshotDone, ctx: ?*anyopaque) void {
    s.requestScreenshot(done, ctx);
}

// MARK: Counters

pub export fn ps1_session_frames_produced(s: *Session) u64 {
    return s.framesProduced();
}

pub export fn ps1_session_pad_status(s: *Session, out: *capi.Ps1PadStatus) void {
    const m = s.motor();
    out.* = .{ .analog = @intCast(s.padStatus() & 1), .small = m[0], .large = m[1] };
}

pub export fn ps1_session_card_writes(s: *Session) u64 {
    return s.cardWrites();
}

pub export fn ps1_session_rewind_seconds(s: *Session) f64 {
    return s.rewindSeconds();
}

pub export fn ps1_session_newest_display(s: *Session, out: *capi.Ps1Display) void {
    const d = s.newestDisplay();
    out.* = .{
        .vram_x = d.vram_x,
        .vram_y = d.vram_y,
        .width = d.width,
        .height = d.height,
        .depth24 = @intFromBool(d.depth24),
        .enabled = @intFromBool(d.enabled),
        .pal = 0,
        ._pad = 0,
    };
}
