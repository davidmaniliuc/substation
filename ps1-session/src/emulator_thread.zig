//! The emulator thread: `iterate` in a loop, and the one futex word it waits
//! on between passes.
//!
//! Every wait is bounded or woken: a setter, a request, the audio callback's
//! low-water wake and the queue's drain all bump the same `Pacer`, and so
//! does `stop`. That is what lets `stop` JOIN with no timeout, where the
//! Swift runner gave up after a second and could race the cards.

const std = @import("std");
const builtin = @import("builtin");
const metal = @import("ps1_metal");
const RunLoop = @import("run_loop.zig").RunLoop;

const Pacer = metal.waker.Pacer;
const objc = metal.objc;

/// The emulator thread runs the core's recursive descent in the BIOS and the
/// recompiler; Swift gave it 1 MB and it never came close.
const stack_bytes = 1 << 20;

pub fn EmulatorThread(comptime M: type) type {
    return struct {
        const Self = @This();

        thread: ?std.Thread = null,
        running: std.atomic.Value(bool) = .init(false),
        loop: *RunLoop(M) = undefined,
        pacer: *Pacer = undefined,
        io: std.Io = undefined,

        pub fn start(self: *Self, loop: *RunLoop(M), pacer: *Pacer, io: std.Io) !void {
            std.debug.assert(self.thread == null);
            self.loop = loop;
            self.pacer = pacer;
            self.io = io;
            self.running.store(true, .release);
            self.thread = std.Thread.spawn(.{ .stack_size = stack_bytes }, run, .{self}) catch |err| {
                self.running.store(false, .release);
                return err;
            };
        }

        fn run(self: *Self) void {
            if (builtin.os.tag.isDarwin()) {
                _ = std.c.pthread_setname_np("ps1.emulator");
                // The frame is what the player sees and hears next: the
                // audio ring is the clock, and it cannot be made to wait.
                _ = std.c.pthread_set_qos_class_self_np(.USER_INTERACTIVE, 0);
            }
            while (self.running.load(.acquire)) {
                // No implicit pool exists on a thread Zig started.
                const pool = objc.Pool.push();
                defer pool.pop();
                // Read BEFORE the pass: an event during it moves the word, so
                // the wait after it returns at once rather than missing it.
                const seen = self.pacer.generation();
                switch (self.loop.iterate(now(self.io))) {
                    .ran_frame, .rewound => {},
                    .wait => |w| {
                        if (!self.running.load(.acquire)) break;
                        const timeout: std.Io.Timeout = if (w.timeout_ns) |ns|
                            .{ .duration = .{ .raw = .fromNanoseconds(ns), .clock = .awake } }
                        else
                            .none;
                        self.pacer.wait(self.io, seen, timeout);
                    },
                }
            }
        }

        /// Stops the thread and joins it, with no timeout: every wait above
        /// is bounded or woken by the bump.
        pub fn stop(self: *Self) void {
            const t = self.thread orelse return;
            self.running.store(false, .release);
            self.pacer.bump(self.io);
            t.join();
            self.thread = null;
        }

        /// `stop`, then the two things that must follow the join and never
        /// precede it: every request still waiting is answered, then the
        /// cards are flushed. Safe to call twice, and on a thread that never
        /// started.
        pub fn shutdown(self: *Self) void {
            const started = self.thread != null;
            self.stop();
            if (!started) return;
            self.loop.failPendingRequests();
            self.loop.flushMemoryCards();
        }
    };
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}
