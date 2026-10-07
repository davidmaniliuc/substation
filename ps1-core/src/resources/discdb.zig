//! The multi-disc set catalog, keyed by SYSTEM.CNF serial. The rows are
//! generated data in `discdb.zon` (see `gen_discdb.py`); this file is the
//! hand-written type and lookup over them.

const std = @import("std");

pub const Entry = struct {
    serial: []const u8,
    /// The set's identity, region included: two regions' rips of one game
    /// are two sets.
    game_title: []const u8,
    /// One-based position in the set, which orders its discs. A set that
    /// folds in a second edition numbers past the first edition's discs.
    disc_number: u8,
};

pub const entries: []const Entry = @import("discdb.zon");

/// Null means this serial is not a catalogued multi-disc title.
pub fn lookup(serial: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.serial, serial)) return entry;
    }
    return null;
}
