//! Game titles, keyed by SYSTEM.CNF serial. A PS1 disc records no title of
//! its own, so this is the only place one comes from. The rows are generated
//! data in `game_titles.zon` (see `gen_game_titles.py`); this file is the
//! hand-written type and lookup over them.

const std = @import("std");

pub const Entry = struct {
    serial: []const u8,
    /// Per DISC: a multi-disc game's rows read "Final Fantasy VII (Disc 1)".
    title: []const u8,
};

pub const entries: []const Entry = @import("game_titles.zon");

/// Null means the serial is not catalogued: the frontend names the disc.
pub fn lookup(serial: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.serial, serial)) return entry;
    }
    return null;
}
