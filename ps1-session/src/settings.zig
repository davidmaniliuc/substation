//! What the host tells the session as one value, and the fold that turns it
//! into what the machine is given: a game's PGXP preset replaces the player's
//! switches wherever the row names one, and the VRAM mode follows the
//! readbacks choice over the per-game table.
//!
//! Pure: no session state, so the whole rule is testable without a machine.
//! The tables are the core's (`pgxp_presets`, `vram_readbacks`), read only.

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
};

/// What the fold decides: the PGXP switches and vertex cache the machine is
/// given, and its VRAM mode.
pub const Folded = struct {
    pgxp: machine.Pgxp,
    vertex_cache: bool,
    vram: capi.VramMode,
};

/// `readbacks` is separate from `s.vram_readbacks` because the session's
/// choice for a disc can differ from the player's. `transparent_depth` is
/// never a preset field: it stays the player's.
pub fn fold(
    s: Settings,
    readbacks: VramReadbacks,
    preset: ?ps1_core.pgxp_presets.Preset,
    needs_dual: bool,
) Folded {
    var out: Folded = .{
        .pgxp = s.pgxp,
        .vertex_cache = s.vertex_cache,
        .vram = switch (readbacks) {
            .on => .dual,
            .off => .gpu,
            .automatic => if (needs_dual) .dual else .gpu,
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
    return fold(s, readbacks, preset, ps1_core.vram_readbacks.needsDual(serial));
}

/// The serial a disc image names; all zeros when identification fails or the
/// disc names none.
pub fn serialOf(bin: []const u8) Serial {
    var id: capi.Ps1DiscId = undefined;
    if (capi.ps1_identify_disc(bin.ptr, bin.len, &id) != 0) return @splat(0);
    return id.serial;
}
