//! Readback requests from the emulator thread, answered on the render
//! thread once the renderer has executed everything the request waits for.
//!
//! The emulator thread posts and blocks (`RenderThread.readback`); the render
//! thread serves the desk after every drain (`FrameRenderer.executeArrived`),
//! which runs on the same run-loop source as an arriving frame and never on
//! the display link, so occlusion cannot starve it. A render thread that
//! stops answers what is left with the texture as it is, so a teardown bug
//! shows up as a wrong pixel and never as a hang.

const std = @import("std");
const pi = @import("prim_instance.zig");
const Lock = @import("lock.zig").Lock;
const LiveRenderer = @import("live_renderer.zig").LiveRenderer;

/// One readback. The caller owns it and its slices until `done` is set.
pub const Readback = struct {
    /// Inclusive, inside VRAM: `LiveRenderer.readNative`'s rect.
    rect: pi.VramRect,
    colour: []u16,
    depth: ?[]u32,
    /// Answered once the queue has consumed this many slots: the
    /// `StreamQueue.ticket` when it was posted. A ticket rather than a seq,
    /// because a GPU-only frame can span several slots.
    through: u64,
    /// Answered by `answerAll` rather than in order.
    served_by_backstop: bool = false,
    done: std.Io.Event = .unset,
    /// What `done` is set through. `RenderThread.readback` fills it in.
    io: std.Io = undefined,
};

pub const ReadbackDesk = struct {
    lock: Lock = .{},
    /// One emulator thread posts one request at a time; more than this is a
    /// programming error.
    posted: [capacity]*Readback = undefined,
    count: usize = 0,

    const capacity = 4;

    pub fn post(self: *ReadbackDesk, req: *Readback) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.count == capacity) @panic("ReadbackDesk: more readbacks posted than one emulator thread can make");
        self.posted[self.count] = req;
        self.count += 1;
    }

    pub fn pendingCount(self: *ReadbackDesk) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.count;
    }

    /// Render thread: answers every request whose ticket the queue has
    /// `consumed` and leaves the rest posted.
    pub fn serve(self: *ReadbackDesk, live: *LiveRenderer, consumed: u64) void {
        var due: [capacity]*Readback = undefined;
        const n = self.take(&due, consumed);
        for (due[0..n]) |req| answer(req, live);
    }

    /// Answers every request regardless of its ticket. Only once nothing else
    /// can serve them: the render thread has exited.
    pub fn answerAll(self: *ReadbackDesk, live: *LiveRenderer) void {
        var due: [capacity]*Readback = undefined;
        const n = self.take(&due, std.math.maxInt(u64));
        for (due[0..n]) |req| {
            req.served_by_backstop = true;
            answer(req, live);
        }
    }

    /// Moves every request due by `consumed` into `due`. The gather runs
    /// outside the lock, which guards a few assignments and never a wait.
    fn take(self: *ReadbackDesk, due: *[capacity]*Readback, consumed: u64) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var n: usize = 0;
        var kept: usize = 0;
        for (self.posted[0..self.count]) |req| {
            if (req.through <= consumed) {
                due[n] = req;
                n += 1;
            } else {
                self.posted[kept] = req;
                kept += 1;
            }
        }
        self.count = kept;
        return n;
    }

    fn answer(req: *Readback, live: *LiveRenderer) void {
        live.readNative(req.rect, req.colour, req.depth);
        req.done.set(req.io);
    }
};
