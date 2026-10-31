//! The games that need the CPU at another clock, keyed by SYSTEM.CNF serial.
//! The rows are generated data in `cpu_overclock.zon` (see
//! `gen_cpu_overclock.py`); this file is the hand-written lookup over them.
//!
//! The core never applies a row itself: a frontend folds it in under the
//! player's own setting, which wins whenever the player has turned it on.

const std = @import("std");

pub const Row = struct { serial: []const u8, percent: u32 };

/// Upper-case serials, sorted.
pub const entries: []const Row = @import("cpu_overclock.zon");

/// The percentage a listed game runs the CPU at.
pub fn lookup(serial: []const u8) ?u32 {
    for (entries) |row| {
        if (std.ascii.eqlIgnoreCase(row.serial, serial)) return row.percent;
    }
    return null;
}
