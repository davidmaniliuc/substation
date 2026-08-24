//! Fixed-capacity, per-frame capture of the command stream.
//!
//! No allocation, ever: the emulator thread in the macOS app runs at
//! .userInteractive QoS and must not touch an allocator. A frame exceeding
//! either capacity sets `overflow` and is then reported as INCOMPLETE rather
//! than as a shorter stream — a prefix silently applied to a shadow VRAM puts
//! it permanently out of step.

const std = @import("std");
const command = @import("command.zig");

/// Tekken 3 is known to build a self-referential ordering table, guarded at
/// 65,536 nodes in dma.zig, so "a frame cannot be that large" is not an
/// assumption available here.
pub const max_records: usize = 65_536;

/// A full 1024x512 CPU->VRAM upload is 262,144 words. Two of those per frame.
pub const max_payload_words: usize = 524_288;

pub const Recorder = struct {
    // `undefined` rather than a zero initializer. This saves nothing on the
    // Bus path — `memory.zig`'s `Bus.init` memsets the WHOLE bus to zero
    // before it calls `Gpu.init()`, so these six megabytes are written
    // regardless. It is kept for the direct path: a bare `Gpu.init()` (the
    // unit tests, and anything the later phases stand up) should not pay to
    // zero a buffer it is about to overwrite.
    records: [max_records]command.Command = undefined,
    payload: [max_payload_words]u32 = undefined,
    count: usize = 0,
    payload_len: usize = 0,
    overflow: bool = false,

    /// Off by default. `.dual` is a build-time CAPABILITY, not a build-time
    /// commitment: ps1-golden compiles with it so `stream-verify` exists, and
    /// its `capture`/`verify` subcommands must stay at today's speed.
    enabled: bool = false,

    pub fn arm(self: *Recorder) void {
        self.enabled = true;
        self.reset();
    }

    pub fn reset(self: *Recorder) void {
        self.count = 0;
        self.payload_len = 0;
        self.overflow = false;
    }

    pub fn push(self: *Recorder, cmd: command.Command) void {
        if (!self.enabled) return;
        if (self.count == max_records) {
            self.overflow = true;
            return;
        }
        self.records[self.count] = cmd;
        self.count += 1;
    }

    /// A CPU->VRAM payload word. Consecutive words extend the run in place
    /// rather than pushing a record each: a full-screen upload is 262,144
    /// words and would otherwise blow the record capacity four times over.
    /// A run ends the moment any other command intervenes, which is what keeps
    /// a GP1(01) abort mid-payload in the right place.
    pub fn pushVramWriteData(self: *Recorder, word: u32) void {
        if (!self.enabled) return;
        if (self.payload_len == max_payload_words) {
            self.overflow = true;
            return;
        }
        self.payload[self.payload_len] = word;
        self.payload_len += 1;

        if (self.count > 0 and self.records[self.count - 1].kind == .vram_write_data) {
            self.records[self.count - 1].y += 1;
            return;
        }
        self.push(.{
            .kind = .vram_write_data,
            .x = @intCast(self.payload_len - 1),
            .y = 1,
        });
    }

    /// Hands out the frame and resets. The slices point INTO the recorder and
    /// are valid only until the next recorded command, so consume the stream
    /// before stepping the CPU again.
    pub fn takeFrame(self: *Recorder) command.Stream {
        const s = command.Stream{
            .records = self.records[0..self.count],
            .payload = self.payload[0..self.payload_len],
            .complete = !self.overflow,
        };
        self.reset();
        return s;
    }
};
