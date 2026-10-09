//! Runahead's mark: one trusted snapshot of the running machine, plus the
//! two memory-card images and their dirty flags, which no state carries.
//!
//! Cards stay out of a state because they are shared across games: a state
//! that restored them would roll back other games' saves. A mark is the
//! opposite case. The machine returns to it within a few frames, and a save
//! made by a speculative frame must not reach the card, or the host's file,
//! ahead of the real one.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const Sio = @import("../sio/sio.zig").Sio;
const savestate = @import("savestate.zig");
const PgxpShadows = @import("pgxp_mark.zig").PgxpShadows;

pub const RestoreError = savestate.Error || error{NoMark};

pub const Mark = struct {
    allocator: std.mem.Allocator,
    /// Sized by the first `take` and reused: a build's state size is fixed.
    buf: []u8 = &.{},
    len: usize = 0,
    held: bool = false,
    cards: [Sio.memcard_slots][Sio.memcard_bytes]u8 = undefined,
    dirty: [Sio.memcard_slots]bool = undefined,
    /// No state carries a PGXP shadow; see `pgxp_mark.zig`.
    pgxp: PgxpShadows,

    pub fn init(allocator: std.mem.Allocator) Mark {
        return .{ .allocator = allocator, .pgxp = .init(allocator) };
    }

    pub fn deinit(m: *Mark) void {
        m.allocator.free(m.buf);
        m.pgxp.deinit();
        m.* = undefined;
    }

    pub fn take(m: *Mark, cpu: *const Cpu) error{OutOfMemory}!void {
        // Counting never fails, and the buffer is sized from that count.
        const n = savestate.saveTrusted(cpu, null) catch unreachable;
        if (m.buf.len < n) {
            m.allocator.free(m.buf);
            m.buf = &.{};
            m.buf = try m.allocator.alloc(u8, n);
        }
        m.len = savestate.saveTrusted(cpu, m.buf) catch unreachable;
        // After `saveTrusted`, which drained the raster worker that owns
        // the depth plane.
        try m.pgxp.take(cpu);
        m.cards = cpu.bus.sio.memcard_data;
        m.dirty = cpu.bus.sio.memcard_dirty;
        m.held = true;
    }

    /// Returns the machine to the mark, which stays held.
    pub fn restore(m: *const Mark, cpu: *Cpu) RestoreError!void {
        if (!m.held) return error.NoMark;
        try savestate.loadTrusted(cpu, m.buf[0..m.len]);
        m.pgxp.restore(cpu);
        cpu.bus.sio.memcard_data = m.cards;
        cpu.bus.sio.memcard_dirty = m.dirty;
    }

    /// The machine the mark was taken from is gone (a reset, a load, a disc
    /// change): returning to it now would restore a different machine.
    pub fn forget(m: *Mark) void {
        m.held = false;
    }
};
