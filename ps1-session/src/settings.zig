//! What the host tells the session as one value, and the fold that turns it
//! into what the machine is given: a game's PGXP preset replaces the player's
//! switches wherever the row names one, and the VRAM mode follows the
//! readbacks choice over the per-game table. A game's CPU overclock applies
//! while the player's own is off. A game's CD speedup table row forces the
//! direction it disables back to 1x.
//!
//! Pure: no session state, so the whole rule is testable without a machine.
//! The tables are the core's (`pgxp_presets`, `vram_readbacks`,
//! `cpu_overclock`, `cd_speedup`), read only.

const std = @import("std");
const capi = @import("ps1_capi");
const ps1_core = @import("ps1_core");
const metal = @import("ps1_metal");
const machine = @import("machine.zig");

const pi = metal.prim_instance;

/// `ps1_session.h`'s `PS1_READBACKS_*` numbering.
pub const VramReadbacks = enum(u8) { automatic = 0, on = 1, off = 2 };

/// A disc's serial, NUL-padded, as `Ps1DiscId.serial`.
pub const Serial = [16]u8;

/// The serial up to its first NUL.
pub fn serialSlice(s: *const Serial) []const u8 {
    return std.mem.sliceTo(s, 0);
}

/// Every setting the host owns. A default is the "off" value, except
/// `vram_readbacks`, which is `.on`: the safe mode for a game nothing is known
/// about.
pub const Settings = struct {
    gain: f32 = 0,
    engine: machine.Engine = .interpreter,
    runahead: u32 = 0,
    rewind_budget: usize = 0,
    scale: u32 = 1,
    dither: pi.DitherMode = .off,
    texture_filter: pi.TextureFilter = .nearest,
    sprite_filter: pi.TextureFilter = .nearest,
    pgxp: machine.Pgxp = .{},
    vertex_cache: bool = false,
    use_presets: bool = false,
    vram_readbacks: VramReadbacks = .on,
    /// The CPU clock in percent; 100 is off.
    cpu_overclock: u32 = 100,
    display_effect: metal.display.Effect = .none,
    widescreen: ps1_core.widescreen.Widescreen = .off,
    /// The player's CD speedup; 1x is off. A listed game's disabled
    /// direction is forced back to 1x in the fold.
    cd_speedup: ps1_core.speedup.Speedup = .{},
};

/// What the fold decides: the PGXP switches and vertex cache the machine is
/// given, its VRAM mode, its CPU clock and its CD speedup.
pub const Folded = struct {
    pgxp: machine.Pgxp,
    vertex_cache: bool,
    vram: capi.VramMode,
    cpu_overclock: u32,
    cd_speedup: ps1_core.speedup.Speedup,
};

/// `readbacks` is separate from `s.vram_readbacks` because the session's
/// choice for a disc can differ from the player's. `transparent_depth` is
/// never a preset field: it stays the player's. The overclock row is not
/// gated on `use_presets`: it works around a crash, and the player's own
/// setting already wins whenever it is on. Nor is the CD speedup row: a
/// direction it disables is 1x whatever the player asked for.
pub fn fold(
    s: Settings,
    readbacks: VramReadbacks,
    preset: ?ps1_core.pgxp_presets.Preset,
    needs_dual: bool,
    overclock: ?u32,
    cd_disabled: ps1_core.cd_speedup.Disabled,
) Folded {
    var out: Folded = .{
        .pgxp = s.pgxp,
        .vertex_cache = s.vertex_cache,
        .vram = switch (readbacks) {
            .on => .dual,
            .off => .gpu,
            .automatic => if (needs_dual) .dual else .gpu,
        },
        .cpu_overclock = if (s.cpu_overclock == 100) overclock orelse 100 else s.cpu_overclock,
        .cd_speedup = .{
            .read = if (cd_disabled.read) .x1 else s.cd_speedup.read,
            .seek = if (cd_disabled.seek) .x1 else s.cd_speedup.seek,
        },
    };
    if (!s.use_presets) return out;
    const p = preset orelse return out;
    inline for (.{
        "enabled",
        "cpu",
        "culling",
        "texture_correction",
        "color_correction",
        "depth_buffer",
        "disable_2d",
        "preserve_projection",
        "tolerance",
    }) |name| {
        if (@field(p, name)) |v| @field(out.pgxp, name) = v;
    }
    if (p.vertex_cache) |v| out.vertex_cache = v;
    return out;
}

/// `fold` over a game's rows. An empty serial names no row.
pub fn forSerial(s: Settings, readbacks: VramReadbacks, serial: []const u8) Folded {
    const preset = if (serial.len == 0) null else ps1_core.pgxp_presets.lookup(serial);
    const overclock = if (serial.len == 0) null else ps1_core.cpu_overclock.lookup(serial);
    return fold(s, readbacks, preset, ps1_core.vram_readbacks.needsDual(serial), overclock, ps1_core.cd_speedup.lookup(serial));
}

/// The serial a disc image names, with its `cue` (an Alcohol sheet, say) and
/// the `disc` of an eboot; all zeros when identification fails or the disc
/// names none.
pub fn serialOf(bin: []const u8, cue: ?[]const u8, disc: u32) Serial {
    var id: capi.Ps1DiscId = undefined;
    const sheet = cue orelse &.{};
    if (capi.ps1_identify_disc_image(bin.ptr, bin.len, if (cue != null) sheet.ptr else null, sheet.len, disc, &id, null) != 0) return @splat(0);
    return id.serial;
}
