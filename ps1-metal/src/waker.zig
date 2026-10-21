//! How one thread tells another that what it waits for may have changed.
//!
//! `Waker` is a callback with its context, so a queue can wake whoever
//! produces into it without knowing who that is. `Pacer` is what such a
//! producer waits on: ONE futex word every event bumps, so a thread with
//! several reasons to wake waits on all of them at once, and the waker needs
//! neither a lock nor an allocation. That last part is what makes `bump`
//! legal on the CoreAudio render thread.

const std = @import("std");

pub const Waker = struct {
    ctx: *anyopaque,
    wake: *const fn (*anyopaque) void,

    pub fn call(self: Waker) void {
        self.wake(self.ctx);
    }
};

pub const Pacer = struct {
    word: std.atomic.Value(u32) = .init(0),

    /// Something the waiter may be waiting for has changed. No lock, no
    /// allocation, no wait.
    pub fn bump(self: *Pacer, io: std.Io) void {
        _ = self.word.fetchAdd(1, .release);
        io.futexWake(u32, &self.word.raw, 1);
    }

    /// Read BEFORE deciding to wait: a bump between this read and `wait`
    /// changes the word, so the wait returns at once instead of missing it.
    pub fn generation(self: *const Pacer) u32 {
        return self.word.load(.acquire);
    }

    /// Returns on a bump, on the timeout, or at once if the word has moved
    /// past `seen`. Spurious returns are allowed; the caller re-checks its
    /// own condition either way.
    pub fn wait(self: *Pacer, io: std.Io, seen: u32, timeout: std.Io.Timeout) void {
        io.futexWaitTimeout(u32, &self.word.raw, seen, timeout) catch |err| switch (err) {
            // A cancel is a wake by another name: the loop re-checks.
            error.Canceled => {},
        };
    }
};
