//! What the session tells its host without being asked: the pad's mode and
//! motors, a game's memory-card write, the seconds of rewind history left and
//! the frame rate. Each is one `Ps1Event` handed to the host's sink.
//!
//! Coalesced here, at the source: a pad status or a rewind value is sent only
//! when it differs from the last one sent, so a host gets at most one of each
//! per frame and none while nothing changes. The sink is called on the thread
//! that calls these methods (the emulator thread, once the session runs), with
//! no session lock held.

const std = @import("std");
const capi = @import("ps1_capi");

pub const Kind = enum(i32) { pad = 0, card_write = 1, rewind = 2, frame_rate = 3 };

/// ps1_session.h's Ps1Event: valid only during the call. A field its kind
/// does not use is zero.
pub const Ps1Event = extern struct {
    kind: i32,
    pad: capi.Ps1PadStatus,
    card_writes: u64,
    value: f64,
};

pub const EventFn = *const fn (ctx: ?*anyopaque, ev: *const Ps1Event) callconv(.c) void;

pub const Sink = struct {
    on_event: EventFn,
    ctx: ?*anyopaque,
};

/// Frames per second over a fixed window, fed the CUMULATIVE frame count and
/// a monotonic time. Closing on elapsed time rather than on a call count: a
/// sample inside the window is ignored outright, and the frames it saw still
/// count towards the window it fell inside.
pub const FrameRate = struct {
    /// Long enough that one late frame does not swing the reading, short
    /// enough that a stall shows up while it is still happening.
    pub const window_ns: u64 = 500 * std.time.ns_per_ms;

    base_frames: ?u64 = null,
    base_ns: u64 = 0,

    /// The rate when this sample closes a window. The first sample, and the
    /// first after `reset`, only latches the baseline.
    pub fn sample(self: *FrameRate, frames: u64, now_ns: u64) ?f64 {
        const base = self.base_frames orelse {
            self.base_frames = frames;
            self.base_ns = now_ns;
            return null;
        };
        const elapsed = now_ns -| self.base_ns;
        if (elapsed < window_ns) return null;
        const produced = if (frames >= base) frames - base else 0;
        self.base_frames = frames;
        self.base_ns = now_ns;
        return @as(f64, @floatFromInt(produced)) / (@as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s);
    }

    /// The next window starts at the next sample: one spanning a pause would
    /// read low.
    pub fn reset(self: *FrameRate) void {
        self.base_frames = null;
    }
};

pub const Events = struct {
    /// Null where no host listens (the tests, a tool): every method still
    /// keeps its state.
    sink: ?Sink = null,
    /// Idle, which is what a host assumes of a new session: digital, still.
    last_pad: u32 = 0,
    /// Null so a session's first rewind value is always sent.
    last_rewind_frames: ?u32 = null,
    frame_rate: FrameRate = .{},

    /// `status` packed as `RunLoop.pad_status`: analog in bit 0, the small
    /// motor in bits 8-15, the large in 16-23.
    pub fn pad(self: *Events, status: u32) void {
        if (status == self.last_pad) return;
        self.last_pad = status;
        self.send(.{ .kind = @backingInt(Kind.pad), .pad = .{
            .analog = @intCast(status & 1),
            .small = @truncate(status >> 8),
            .large = @truncate(status >> 16),
        }, .card_writes = 0, .value = 0 });
    }

    /// Every write is news: `count` is the running total.
    pub fn cardWrite(self: *Events, count: u64) void {
        self.send(.{ .kind = @backingInt(Kind.card_write), .pad = idle_pad, .card_writes = count, .value = 0 });
    }

    /// Sent as seconds at 60 Hz, as `Session.rewindSeconds` reads them.
    pub fn rewind(self: *Events, frames: u32) void {
        if (self.last_rewind_frames == frames) return;
        self.last_rewind_frames = frames;
        const seconds = @as(f64, @floatFromInt(frames)) / 60;
        self.send(.{ .kind = @backingInt(Kind.rewind), .pad = idle_pad, .card_writes = 0, .value = seconds });
    }

    pub fn frame(self: *Events, frames: u64, now_ns: u64) void {
        const rate = self.frame_rate.sample(frames, now_ns) orelse return;
        self.send(.{ .kind = @backingInt(Kind.frame_rate), .pad = idle_pad, .card_writes = 0, .value = rate });
    }

    pub fn paused(self: *Events) void {
        self.frame_rate.reset();
    }

    const idle_pad: capi.Ps1PadStatus = .{ .analog = 0, .small = 0, .large = 0 };

    fn send(self: *const Events, ev: Ps1Event) void {
        const s = self.sink orelse return;
        s.on_event(s.ctx, &ev);
    }
};
