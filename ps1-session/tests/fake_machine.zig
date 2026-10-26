//! A scripted machine: every call the run loop makes is appended to `calls`
//! by name, and every output comes from a field a test sets. It needs no
//! BIOS and no disc, which is what lets the orderings that matter be tested
//! at all.

const std = @import("std");
const session = @import("ps1_session");
const ps1_core = @import("ps1_core");

const machine = session.machine;
const command = ps1_core.gpu.command;
const Display = @import("ps1_metal").stream_queue.Display;
const RasterState = @import("ps1_metal").rasterizer.Rasterizer.State;
const native_pixels = @import("ps1_metal").prim_instance.native_pixels;
const card_bytes = session.cards.bytes;
const PendingVram = ps1_core.savestate.Rewind.PendingVram;
const VramMode = session.capi.VramMode;

pub const FakeMachine = struct {
    alloc: std.mem.Allocator,
    /// Names only, all static strings, so nothing to free per entry.
    calls: std.ArrayList([]const u8) = .empty,

    audio_per_frame: usize = 6,
    /// The value every audio float carries: a test of the rewind's reversed
    /// audio sets it per frame through `on_run`.
    audio_value: f32 = 1,
    record: command.Command = .{ .kind = .fill_rect, .w = 1, .h = 1 },
    /// An incomplete stream on every take.
    incomplete: bool = false,
    display_value: Display = .{ .vram_x = 320, .width = 320, .height = 240, .enabled = true },
    /// What every shadow says the rasterizer's environment and upload are.
    raster_state: RasterState = .{ .env = .{}, .transfer = .{} },
    /// Frames of rewind history, set by the test; each step goes back
    /// `rewind_step_frames`.
    rewind_history: u32 = 0,
    rewind_step_frames: u32 = 2,
    rewind_budget: usize = 0,
    fail_load: bool = false,
    fail_engine: bool = false,
    fail_mark: bool = false,
    pad: u32 = 0,
    /// Which slots `takeMemcard` reports dirty, cleared as it reports them.
    dirty_cards: [2]bool = .{ false, false },
    card_fill: u8 = 0xC4,
    frames_run: u32 = 0,
    /// Called inside `runFrame` and both VRAM copies, with `ctx` for the
    /// test.
    /// Deferred-VRAM rewind captures, as the core numbers them.
    pending_first: ?u64 = null,
    next_capture: u64 = 0,
    /// The ids `rewindFillVram` took, in order.
    filled: std.ArrayList(u64) = .empty,
    /// The machine's VRAM mode, and what it was at the first `runFrame`.
    vram_mode: VramMode = .dual,
    mode_at_first_run: ?VramMode = null,
    on_run: ?*const fn (*FakeMachine) void = null,
    on_copy: ?*const fn (*FakeMachine) void = null,
    ctx: ?*anyopaque = null,

    pub fn init(alloc: std.mem.Allocator) FakeMachine {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *FakeMachine) void {
        self.calls.deinit(self.alloc);
        self.filled.deinit(self.alloc);
    }

    fn log(self: *FakeMachine, name: []const u8) void {
        self.calls.append(self.alloc, name) catch @panic("FakeMachine: out of memory");
    }

    /// How many times `name` was called.
    pub fn count(self: *const FakeMachine, name: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| n += @intFromBool(std.mem.eql(u8, c, name));
        return n;
    }

    /// The index of the first call named `name`, or null.
    pub fn first(self: *const FakeMachine, name: []const u8) ?usize {
        for (self.calls.items, 0..) |c, i| if (std.mem.eql(u8, c, name)) return i;
        return null;
    }

    pub fn last(self: *const FakeMachine, name: []const u8) ?usize {
        var at: ?usize = null;
        for (self.calls.items, 0..) |c, i| if (std.mem.eql(u8, c, name)) {
            at = i;
        };
        return at;
    }

    pub fn runFrame(self: *FakeMachine) void {
        self.log("run");
        self.frames_run += 1;
        if (self.mode_at_first_run == null) self.mode_at_first_run = self.vram_mode;
        if (self.on_run) |f| f(self);
    }

    pub fn readAudio(self: *FakeMachine, dst: []f32) usize {
        self.log("audio");
        const n = @min(dst.len, self.audio_per_frame);
        @memset(dst[0..n], self.audio_value);
        return n;
    }

    pub fn takeFrameStream(self: *FakeMachine) command.Stream {
        self.log("stream");
        return .{ .records = (&self.record)[0..1], .payload = &.{}, .complete = !self.incomplete };
    }

    pub fn display(self: *FakeMachine) Display {
        self.log("display");
        return self.display_value;
    }

    pub fn rasterState(self: *FakeMachine) RasterState {
        self.log("rasterState");
        return self.raster_state;
    }

    pub fn copyVram(self: *FakeMachine, dst: *[native_pixels]u16) void {
        self.log("copyVram");
        if (self.on_copy) |f| f(self);
        @memset(dst, @truncate(self.frames_run));
    }

    pub fn copyDepth(self: *FakeMachine, dst: *[native_pixels]u32) void {
        self.log("copyDepth");
        @memset(dst, self.frames_run);
    }

    pub fn copyVramAsIs(self: *FakeMachine, dst: *[native_pixels]u16) void {
        self.log("copyVramAsIs");
        if (self.on_copy) |f| f(self);
        @memset(dst, @truncate(self.frames_run));
    }

    pub fn copyDepthAsIs(self: *FakeMachine, dst: *[native_pixels]u32) void {
        self.log("copyDepthAsIs");
        @memset(dst, self.frames_run);
    }

    pub fn setVramHost(self: *FakeMachine, host: ?ps1_core.gpu.Host) void {
        _ = host;
        self.log("setVramHost");
    }

    /// As the handle's: a change forgets the rewind history.
    pub fn setVramMode(self: *FakeMachine, mode: VramMode) void {
        self.log("setVramMode");
        if (mode == self.vram_mode) return;
        self.vram_mode = mode;
        self.rewind_history = 0;
        self.clearRewind();
    }

    pub fn saveStateSize(self: *FakeMachine) usize {
        _ = self;
        return 16;
    }

    pub fn saveState(self: *FakeMachine, dst: []u8) machine.Error!usize {
        self.log("saveState");
        @memset(dst[0..16], @truncate(self.frames_run));
        return 16;
    }

    pub fn loadState(self: *FakeMachine, src: []const u8) machine.Error!void {
        _ = src;
        self.log("loadState");
        if (self.fail_load) return error.StateCorrupt;
    }

    pub fn snapshotMark(self: *FakeMachine) machine.Error!void {
        self.log("mark");
        if (self.fail_mark) return error.NoSnapshot;
    }

    pub fn snapshotReturn(self: *FakeMachine) machine.Error!void {
        self.log("return");
    }

    pub fn reset(self: *FakeMachine) void {
        self.log("reset");
    }

    pub fn swapDisc(self: *FakeMachine, disc: machine.DiscBytes) machine.Error!void {
        _ = disc;
        self.log("swapDisc");
    }

    pub fn setButtons(self: *FakeMachine, mask: u16) void {
        _ = mask;
        self.log("setButtons");
    }

    pub fn setAnalog(self: *FakeMachine, sticks: [4]u8) void {
        _ = sticks;
        self.log("setAnalog");
    }

    pub fn pressAnalogButton(self: *FakeMachine) void {
        self.log("pressAnalogButton");
    }

    pub fn padStatus(self: *FakeMachine) u32 {
        return self.pad;
    }

    pub fn takeMemcard(self: *FakeMachine, slot: u1, dst: *[card_bytes]u8) bool {
        self.log(if (slot == 0) "takeMemcard 0" else "takeMemcard 1");
        if (!self.dirty_cards[slot]) return false;
        self.dirty_cards[slot] = false;
        @memset(dst, self.card_fill);
        return true;
    }

    pub fn loadMemcard(self: *FakeMachine, slot: u1, src: *const [card_bytes]u8) machine.Error!void {
        _ = src;
        self.log(if (slot == 0) "loadMemcard 0" else "loadMemcard 1");
    }

    pub fn applyPgxp(self: *FakeMachine, p: machine.Pgxp) void {
        _ = p;
        self.log("applyPgxp");
    }

    pub fn setVertexCache(self: *FakeMachine, on: bool) void {
        _ = on;
        self.log("setVertexCache");
    }

    pub fn setEngine(self: *FakeMachine, e: machine.Engine) machine.Error!void {
        _ = e;
        self.log("setEngine");
        if (self.fail_engine) return error.EngineUnavailable;
    }

    pub fn configureRewind(self: *FakeMachine, bytes: usize) machine.Error!void {
        self.log("configureRewind");
        self.rewind_budget = bytes;
        if (bytes == 0) self.rewind_history = 0;
    }

    pub fn rewindStep(self: *FakeMachine) bool {
        self.log("rewindStep");
        if (self.rewind_history == 0) return false;
        self.rewind_history -|= self.rewind_step_frames;
        return true;
    }

    pub fn rewindFramesCovered(self: *FakeMachine) u32 {
        return self.rewind_history;
    }

    /// What `ps1_run_frame` does under a deferred-VRAM history: one more
    /// capture waits for its VRAM.
    pub fn captureRewind(self: *FakeMachine) void {
        if (self.pending_first == null) self.pending_first = self.next_capture;
        self.next_capture += 1;
    }

    /// A load, a reset or a budget change: the history forgets its captures.
    pub fn clearRewind(self: *FakeMachine) void {
        self.pending_first = null;
    }

    pub fn rewindPendingVram(self: *FakeMachine) ?PendingVram {
        const oldest = self.pending_first orelse return null;
        return .{ .first = oldest, .last = self.next_capture - 1 };
    }

    pub fn rewindFillVram(self: *FakeMachine, id: u64, pixels: *const [native_pixels]u16) bool {
        _ = pixels;
        self.log("rewindFillVram");
        if (self.pending_first != id) return false;
        self.filled.append(self.alloc, id) catch @panic("FakeMachine: out of memory");
        self.pending_first = if (id + 1 == self.next_capture) null else id + 1;
        return true;
    }

    pub fn rewindDropVramFrom(self: *FakeMachine, id: u64) void {
        self.log("rewindDropVramFrom");
        const oldest = self.pending_first orelse return;
        const from = @max(id, oldest);
        self.next_capture = @min(self.next_capture, from);
        if (from == oldest) self.pending_first = null;
    }
};
