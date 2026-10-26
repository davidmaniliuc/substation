//! The games that need dual VRAM, keyed by SYSTEM.CNF serial. The rows are
//! generated data in `vram_readbacks.zon` (see `gen_vram_readbacks.py`); this
//! file is the hand-written lookup over them.
//!
//! A listed game reads VRAM back often enough that a machine whose only VRAM
//! is the GPU's would wait on the render thread every frame. The core never
//! applies a row itself: a frontend folds it into the VRAM mode it asks for,
//! beside the player's own per-game choice.

const std = @import("std");

/// Upper-case serials, sorted.
pub const entries: []const []const u8 = @import("vram_readbacks.zon");

pub fn needsDual(serial: []const u8) bool {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, serial)) return true;
    }
    return false;
}
