//! The games that cannot take the CD speedup, keyed by SYSTEM.CNF serial. The
//! rows are generated data in `cd_speedup.zon` (see `gen_cd_speedup.py`); this
//! file is the hand-written lookup over them.
//!
//! A listed game breaks when its loads run faster than the real drive, in one
//! direction or both. The core never applies a row itself: a frontend folds it
//! into the speedup it asks for, forcing a disabled direction to 1x.

const std = @import("std");

pub const Row = struct { serial: []const u8, read_disabled: bool, seek_disabled: bool };

/// The directions a game cannot speed up.
pub const Disabled = struct { read: bool = false, seek: bool = false };

/// Upper-case serials, sorted.
pub const entries: []const Row = @import("cd_speedup.zon");

pub fn lookup(serial: []const u8) Disabled {
    for (entries) |row| {
        if (std.ascii.eqlIgnoreCase(row.serial, serial)) {
            return .{ .read = row.read_disabled, .seek = row.seek_disabled };
        }
    }
    return .{};
}
