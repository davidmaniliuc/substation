//! Per-game PGXP overrides, keyed by SYSTEM.CNF serial. The rows are generated
//! data in `pgxp_presets.zon` (see `gen_pgxp_presets.py`); this file is the
//! hand-written type and lookup over them.
//!
//! The core never applies a preset itself. A frontend re-applies every PGXP
//! setting every frame, so an override set inside the core would be undone by
//! the next frame; the frontend folds a preset into what it pushes instead.

const std = @import("std");

/// Each field is null where the game keeps the player's own setting. The
/// names are the `Bus.pgxp_*` settings they override.
pub const Preset = struct {
    serial: []const u8,
    enabled: ?bool = null,
    cpu: ?bool = null,
    culling: ?bool = null,
    vertex_cache: ?bool = null,
    texture_correction: ?bool = null,
    color_correction: ?bool = null,
    depth_buffer: ?bool = null,
    disable_2d: ?bool = null,
    preserve_projection: ?bool = null,
    tolerance: ?f32 = null,
};

pub const entries: []const Preset = @import("pgxp_presets.zon");

/// Null means the game has no preset: every setting is the player's.
pub fn lookup(serial: []const u8) ?Preset {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.serial, serial)) return entry;
    }
    return null;
}
