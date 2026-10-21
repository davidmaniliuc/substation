//! The one lock the renderer and the session share for their short critical
//! sections: a few assignments, never a copy and never a wait.
//!
//! `os_unfair_lock` on Darwin, because the threads that contend for it run at
//! different QoS (the emulator thread at user-interactive, the render thread
//! below it) and an unfair lock donates the waiter's priority to the owner,
//! which a spin lock cannot: a spinning high-priority waiter can starve the
//! low-priority owner it waits on. Elsewhere a spin, so the pure tests still
//! build on any host.

const std = @import("std");
const builtin = @import("builtin");

const darwin = builtin.os.tag.isDarwin();
const counting = builtin.mode == .debug;

/// Debug builds count every acquisition per thread, so a test can show a
/// real-time path (the audio callback's) took none.
threadlocal var acquisitions: usize = 0;

pub fn acquisitionsOnThisThread() usize {
    return acquisitions;
}

pub const Lock = struct {
    inner: if (darwin) std.c.os_unfair_lock else std.atomic.Mutex = if (darwin) .{} else .unlocked,

    pub fn lock(self: *Lock) void {
        if (counting) acquisitions += 1;
        if (darwin) {
            std.c.os_unfair_lock_lock(&self.inner);
        } else {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Lock) void {
        if (darwin) std.c.os_unfair_lock_unlock(&self.inner) else self.inner.unlock();
    }
};
