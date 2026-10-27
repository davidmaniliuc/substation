//! The requests that wait for the emulator thread: save, load, reset and a
//! disc swap, each with a C completion.
//!
//! One `Lock` guards every list, and each `take*` swaps its list out under
//! it, so a completion is answered exactly once whichever thread reaches it
//! first: the emulator thread servicing it or `failAll` at stop. Completions
//! run outside the lock, on that thread. Bytes handed to a completion are
//! valid only during the call; the C caller copies them.

const std = @import("std");
const capi = @import("ps1_capi");
const Lock = @import("ps1_metal").lock.Lock;
const DiscBytes = @import("machine.zig").DiscBytes;
const settings = @import("settings.zig");

pub const SaveDone = *const fn (ctx: ?*anyopaque, code: i32, state: [*]const u8, state_len: usize, png: ?[*]const u8, png_len: usize) callconv(.c) void;
pub const LoadDone = *const fn (ctx: ?*anyopaque, code: i32, undo: [*]const u8, undo_len: usize) callconv(.c) void;
/// A reset or a disc swap.
pub const Done = *const fn (ctx: ?*anyopaque, code: i32) callconv(.c) void;

/// Per kind. A queue rather than one slot: a slot save pressed while a timed
/// auto-save waits must not displace it, and a displaced caller (perhaps an
/// exit) would never be answered. Past the bound a request is answered at
/// once with `PS1_ERR_BUSY`: storage is fixed, nothing allocates.
pub const max_pending = 16;

const empty: [0]u8 = .{};

pub const Save = struct { done: SaveDone, ctx: ?*anyopaque };

pub const Load = struct {
    /// Owned, freed with `alloc` once answered.
    state: []u8,
    alloc: std.mem.Allocator,
    done: LoadDone,
    ctx: ?*anyopaque,

    pub fn answer(self: Load, code: i32, undo: []const u8) void {
        self.done(self.ctx, code, if (undo.len > 0) undo.ptr else &empty, undo.len);
        self.alloc.free(self.state);
    }
};

pub const Simple = struct {
    done: Done,
    ctx: ?*anyopaque,

    pub fn answer(self: Simple, code: i32) void {
        self.done(self.ctx, code);
    }
};

pub const Swap = struct {
    disc: DiscBytes,
    /// The serial `disc` names, read on the asking thread, and the host's
    /// readbacks choice for it.
    serial: settings.Serial,
    readbacks: settings.VramReadbacks,
    done: Done,
    ctx: ?*anyopaque,
};

fn List(comptime T: type) type {
    return struct {
        items: [max_pending]T = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }
    };
}

pub fn answerSave(s: Save, code: i32) void {
    s.done(s.ctx, code, &empty, 0, null, 0);
}

pub const Requests = struct {
    lock: Lock = .{},
    saves: List(Save) = .{},
    loads: List(Load) = .{},
    resets: List(Simple) = .{},
    swap: ?Swap = null,

    pub fn addSave(self: *Requests, done: SaveDone, ctx: ?*anyopaque) void {
        self.lock.lock();
        if (self.saves.len == max_pending) {
            self.lock.unlock();
            return answerSave(.{ .done = done, .ctx = ctx }, capi.PS1_ERR_BUSY);
        }
        self.saves.items[self.saves.len] = .{ .done = done, .ctx = ctx };
        self.saves.len += 1;
        self.lock.unlock();
    }

    /// Takes ownership of `state`, which `alloc` frees once answered.
    pub fn addLoad(self: *Requests, state: []u8, alloc: std.mem.Allocator, done: LoadDone, ctx: ?*anyopaque) void {
        const load: Load = .{ .state = state, .alloc = alloc, .done = done, .ctx = ctx };
        self.lock.lock();
        if (self.loads.len == max_pending) {
            self.lock.unlock();
            return load.answer(capi.PS1_ERR_BUSY, &.{});
        }
        self.loads.items[self.loads.len] = load;
        self.loads.len += 1;
        self.lock.unlock();
    }

    /// Several resets asked before one is serviced are one reset, and every
    /// caller is answered by it.
    pub fn addReset(self: *Requests, done: Done, ctx: ?*anyopaque) void {
        const r: Simple = .{ .done = done, .ctx = ctx };
        self.lock.lock();
        if (self.resets.len == max_pending) {
            self.lock.unlock();
            return r.answer(capi.PS1_ERR_BUSY);
        }
        self.resets.items[self.resets.len] = r;
        self.resets.len += 1;
        self.lock.unlock();
    }

    /// A newer swap answers the older one `PS1_ERR_SUPERSEDED` and releases
    /// its bytes: that disc never went in.
    pub fn setSwap(
        self: *Requests,
        disc: DiscBytes,
        serial: settings.Serial,
        readbacks: settings.VramReadbacks,
        done: Done,
        ctx: ?*anyopaque,
    ) void {
        self.lock.lock();
        const old = self.swap;
        self.swap = .{ .disc = disc, .serial = serial, .readbacks = readbacks, .done = done, .ctx = ctx };
        self.lock.unlock();
        if (old) |o| {
            o.done(o.ctx, capi.PS1_ERR_SUPERSEDED);
            o.disc.releaseBin();
        }
    }

    pub fn takeSaves(self: *Requests) List(Save) {
        self.lock.lock();
        defer self.lock.unlock();
        const taken = self.saves;
        self.saves.len = 0;
        return taken;
    }

    pub fn takeLoads(self: *Requests) List(Load) {
        self.lock.lock();
        defer self.lock.unlock();
        const taken = self.loads;
        self.loads.len = 0;
        return taken;
    }

    pub fn takeResets(self: *Requests) List(Simple) {
        self.lock.lock();
        defer self.lock.unlock();
        const taken = self.resets;
        self.resets.len = 0;
        return taken;
    }

    pub fn takeSwap(self: *Requests) ?Swap {
        self.lock.lock();
        defer self.lock.unlock();
        const taken = self.swap;
        self.swap = null;
        return taken;
    }

    /// Every request still waiting is ANSWERED, never dropped: whoever asked
    /// is waiting on it, perhaps to finish an exit.
    pub fn failAll(self: *Requests, code: i32) void {
        const saves = self.takeSaves();
        for (saves.slice()) |s| answerSave(s, code);
        const loads = self.takeLoads();
        for (loads.slice()) |l| l.answer(code, &.{});
        const resets = self.takeResets();
        for (resets.slice()) |r| r.answer(code);
        if (self.takeSwap()) |s| {
            s.done(s.ctx, code);
            s.disc.releaseBin();
        }
    }
};
