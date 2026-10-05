//! The emulator thread's own count of the CPU<->VRAM transfer in flight.
//!
//! GP0 decides every word by it ("pixels, or a command?") and GPUREAD and
//! GPUSTAT bit 27 by its read half, so it is read per word and must never
//! wait on a raster worker. `Vram` keeps its own transfer fields, because
//! placing the pixels needs them; this is the control half alone, updated by
//! `Sink` where the records are made. It is the source of truth with a
//! worker AND without one, which is what lets the goldens police it.

const std = @import("std");
const Vram = @import("vram.zig").Vram;

pub const Transfer = struct {
    /// CPU->VRAM payload words still to come.
    write_words: usize = 0,
    /// VRAM->CPU words still to read through GPUREAD.
    read_words: usize = 0,

    pub fn writeActive(t: Transfer) bool {
        return t.write_words > 0;
    }

    pub fn readActive(t: Transfer) bool {
        return t.read_words > 0;
    }

    pub fn writeSetup(t: *Transfer, w: usize, h: usize) void {
        t.write_words = Vram.transferWords(w, h);
    }

    pub fn wordWritten(t: *Transfer) void {
        if (t.write_words > 0) t.write_words -= 1;
    }

    pub fn writeAbort(t: *Transfer) void {
        t.write_words = 0;
    }

    pub fn readSetup(t: *Transfer, w: usize, h: usize) void {
        t.read_words = Vram.transferWords(w, h);
    }

    pub fn wordRead(t: *Transfer) void {
        if (t.read_words > 0) t.read_words -= 1;
    }

    /// What a settled `Vram` says is in flight. An aborted upload keeps its
    /// `write_remaining` with `write_active` cleared, so the flag decides.
    /// Also how a loaded state rebuilds the mirror: the counters are the
    /// same unit (words), so the savestate format does not change.
    pub fn fromVram(v: *const Vram) Transfer {
        return .{
            .write_words = if (v.write_active) v.write_remaining else 0,
            .read_words = if (v.read_active) v.read_remaining else 0,
        };
    }

    pub fn matches(t: Transfer, v: *const Vram) bool {
        return std.meta.eql(t, fromVram(v));
    }
};
