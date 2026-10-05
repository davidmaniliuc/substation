//! The multi-disc set catalog. The rows are generated data in `discdb.zon`;
//! this file is the hand-written type and lookup over them.

const std = @import("std");

pub const Entry = struct {
    serial: []const u8,
    game_title: []const u8,
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
