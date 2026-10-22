//! The session C ABI called through its C signatures, with C callbacks, as
//! the app will call it. Needs Metal, so it runs under `zig build test-metal`.

const std = @import("std");
const session = @import("ps1_session");

const capi = session.capi;
const abi = session.abi;
const Session = session.session.Session;

const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

extern fn ps1_session_new_headless(cfg: *const abi.Ps1SessionConfig, out: **Session) callconv(.c) i32;
extern fn ps1_session_start(s: *Session) callconv(.c) i32;
extern fn ps1_session_free(s: ?*Session) callconv(.c) void;
extern fn ps1_session_frames_produced(s: *Session) callconv(.c) u64;
extern fn ps1_session_request_save(s: *Session, done: *const fn (?*anyopaque, i32, [*]const u8, usize, ?[*]const u8, usize) callconv(.c) void, ctx: ?*anyopaque) callconv(.c) void;
extern fn ps1_session_request_load(s: *Session, state: [*]const u8, len: usize, done: *const fn (?*anyopaque, i32, [*]const u8, usize) callconv(.c) void, ctx: ?*anyopaque) callconv(.c) void;
extern fn ps1_session_pad_status(s: *Session, out: *capi.Ps1PadStatus) callconv(.c) void;

comptime {
    _ = abi;
}

const zero_bios: [512 * 1024]u8 = @splat(0);

/// The card directory: never written, because no test here runs a game
/// that saves to a card.
const card_dir = ".zig-cache/tmp/ps1-session-abi-cards";

fn config() abi.Ps1SessionConfig {
    return .{
        .bios = &zero_bios,
        .bios_len = zero_bios.len,
        .disc = std.mem.zeroes(abi.Ps1DiscBytes),
        .resume_state = null,
        .resume_len = 0,
        .card_dir = card_dir,
        .ns_view = null,
        .band_height = 0,
        .band_edge = 0,
        .band_sigma = 0,
        .cpu_engine = 0,
        .fast_boot = 0,
    };
}

/// A session, or a skip where there is no GPU.
fn make() !*Session {
    var s: *Session = undefined;
    const code = ps1_session_new_headless(&config(), &s);
    if (code == capi.PS1_ERR_NO_METAL) {
        std.debug.print("no Metal device\n", .{});
        return error.SkipZigTest;
    }
    try expectEqual(capi.PS1_OK, code);
    return s;
}

const Answer = struct {
    count: std.atomic.Value(u32) = .init(0),
    code: std.atomic.Value(i32) = .init(1),
    len: usize = 0,

    fn save(ctx: ?*anyopaque, code: i32, _: [*]const u8, len: usize, _: ?[*]const u8, _: usize) callconv(.c) void {
        record(ctx, code, len);
    }

    fn load(ctx: ?*anyopaque, code: i32, _: [*]const u8, len: usize) callconv(.c) void {
        record(ctx, code, len);
    }

    fn record(ctx: ?*anyopaque, code: i32, len: usize) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        self.len = len;
        self.code.store(code, .release);
        _ = self.count.fetchAdd(1, .acq_rel);
    }
};

/// Waits up to two seconds for `a`, pulling the mixer as the output
/// callback would, so the emulator thread never parks on a full ring.
fn awaitAnswer(s: *Session, a: *Answer) !void {
    var left: [512]f32 = undefined;
    var right: [512]f32 = undefined;
    const t0 = std.Io.Clock.awake.now(io);
    while (a.count.load(.acquire) == 0) {
        if (t0.untilNow(io, .awake).nanoseconds > 2 * std.time.ns_per_s) return error.Timeout;
        s.mixer.pull(&left, &right);
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(1), .clock = .awake }, io);
    }
}

test "SessionAbi: aSaveCompletesThroughTheCSignatures" {
    const s = try make();
    defer ps1_session_free(s);
    try expectEqual(capi.PS1_OK, ps1_session_start(s));
    var saved: Answer = .{};
    ps1_session_request_save(s, Answer.save, &saved);
    try awaitAnswer(s, &saved);
    try expectEqual(capi.PS1_OK, saved.code.load(.acquire));
    try expect(saved.len > 0);
    try expectEqual(1, saved.count.load(.acquire));
    var pad: capi.Ps1PadStatus = undefined;
    ps1_session_pad_status(s, &pad);
    try expectEqual(0, pad.large);
}

test "SessionAbi: freeAnswersAPendingLoadSessionStopped" {
    // Never started: nothing can service the load before the free.
    const s = try make();
    var loaded: Answer = .{};
    const state = [_]u8{ 1, 2, 3 };
    ps1_session_request_load(s, &state, state.len, Answer.load, &loaded);
    try expectEqual(0, loaded.count.load(.acquire));
    ps1_session_free(s);
    try expectEqual(1, loaded.count.load(.acquire));
    try expectEqual(capi.PS1_ERR_SESSION_STOPPED, loaded.code.load(.acquire));
}

test "SessionAbi: freeToleratesNull" {
    ps1_session_free(null);
}
