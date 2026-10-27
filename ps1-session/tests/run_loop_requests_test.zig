//! The emulator thread's requests: save, load, reset, swap and the cards,
//! against a real machine on a zero BIOS or the scripted one where the call
//! log is the assertion.

const std = @import("std");
const session = @import("ps1_session");
const metal = @import("ps1_metal");
const capi = session.capi;
const FakeMachine = @import("fake_machine.zig").FakeMachine;

const machine = session.machine;
const cards = session.cards;
const requests = session.requests;
const HandleMachine = machine.HandleMachine;
const Exchange = metal.frame_exchange.Exchange;
const AudioRing = session.audio_ring.AudioRing;

const alloc = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const zero_bios: [512 * 1024]u8 = @splat(0);

/// A card directory under a fresh temporary directory, not yet created.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    buf: [256]u8 = undefined,

    fn init() Scratch {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn store(self: *Scratch) cards.CardStore {
        const p = std.fmt.bufPrint(&self.buf, ".zig-cache/tmp/{s}/cards", .{self.tmp.sub_path}) catch unreachable;
        return cards.CardStore.open(p);
    }

    fn deinit(self: *Scratch) void {
        self.tmp.cleanup();
    }
};

fn Rig(comptime M: type) type {
    return struct {
        const Self = @This();
        x: *Exchange,
        ring: AudioRing,
        scratch: Scratch,
        store: cards.CardStore,
        loop: *session.run_loop.RunLoop(M),

        fn init(self: *Self, m: *M, with_cards: bool) !void {
            self.x = try Exchange.init(alloc);
            self.ring = try AudioRing.init(alloc, session.pacing.ring_capacity);
            self.scratch = Scratch.init();
            self.store = self.scratch.store();
            self.loop = try session.run_loop.RunLoop(M).create(alloc, io, m, self.x, &self.ring, if (with_cards) &self.store else null);
        }

        fn deinit(self: *Self) void {
            self.loop.destroy();
            self.scratch.deinit();
            self.ring.deinit();
            self.x.deinit();
        }
    };
}

fn handle() !HandleMachine {
    return HandleMachine.create(&zero_bios);
}

/// The whole machine, owned by the caller.
fn saved(m: *HandleMachine) ![]u8 {
    const buf = try alloc.alloc(u8, m.saveStateSize());
    errdefer alloc.free(buf);
    const n = try m.saveState(buf);
    return alloc.realloc(buf, n);
}

/// What a save completion was handed, copied: the bytes are valid only
/// during the call.
const SaveAnswer = struct {
    calls: usize = 0,
    code: i32 = 1,
    states: [2]?[]u8 = .{ null, null },
    had_png: bool = false,

    fn done(ctx: ?*anyopaque, code: i32, state: [*]const u8, state_len: usize, png: ?[*]const u8, png_len: usize) callconv(.c) void {
        const self: *SaveAnswer = @ptrCast(@alignCast(ctx.?));
        if (self.calls < 2 and code == 0) self.states[self.calls] = alloc.dupe(u8, state[0..state_len]) catch null;
        self.calls += 1;
        self.code = code;
        self.had_png = png != null and png_len > 0;
    }

    fn deinit(self: *SaveAnswer) void {
        for (self.states) |s| if (s) |b| alloc.free(b);
    }
};

const LoadAnswer = struct {
    calls: usize = 0,
    code: i32 = 1,
    undo: ?[]u8 = null,

    fn done(ctx: ?*anyopaque, code: i32, undo: [*]const u8, undo_len: usize) callconv(.c) void {
        const self: *LoadAnswer = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.code = code;
        if (code == 0) self.undo = alloc.dupe(u8, undo[0..undo_len]) catch null;
    }

    fn deinit(self: *LoadAnswer) void {
        if (self.undo) |b| alloc.free(b);
    }
};

const Answer = struct {
    calls: usize = 0,
    code: i32 = 1,

    fn done(ctx: ?*anyopaque, code: i32) callconv(.c) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.code = code;
    }
};

/// A load request owns its bytes; `requestLoad` takes a copy.
fn requestLoad(loop: anytype, bytes: []const u8, a: *LoadAnswer) !void {
    loop.requests.addLoad(try alloc.dupe(u8, bytes), alloc, LoadAnswer.done, a);
}

// Saving

test "RunLoop: aSaveRequestIsServicedWithAStateThatLoadsBack" {
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var a: SaveAnswer = .{};
    defer a.deinit();
    r.loop.requests.addSave(SaveAnswer.done, &a);
    r.loop.serviceSaveRequests();
    try expectEqual(0, a.code);

    var other = try handle();
    defer other.destroy();
    try other.loadState(a.states[0].?);
}

test "RunLoop: withNoRequestServicingDoesNothing" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    r.loop.serviceSaveRequests();
    try expectEqual(0, m.calls.items.len);
}

test "RunLoop: aRequestIsAnsweredExactlyOnce" {
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var a: SaveAnswer = .{};
    defer a.deinit();
    r.loop.requests.addSave(SaveAnswer.done, &a);
    r.loop.serviceSaveRequests();
    r.loop.serviceSaveRequests();
    r.loop.failPendingRequests();
    try expectEqual(1, a.calls);
}

test "RunLoop: aRequestPendingWhenTheRunnerStopsIsAnsweredWithAFailure" {
    // Never dropped: whoever asked is waiting on this completion.
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var a: SaveAnswer = .{};
    defer a.deinit();
    r.loop.requests.addSave(SaveAnswer.done, &a);
    r.loop.failPendingRequests();
    try expectEqual(1, a.calls);
    try expectEqual(capi.PS1_ERR_SESSION_STOPPED, a.code);
}

test "RunLoop: twoSaveRequestsBeforeOneFrameAreBothAnswered" {
    // A slot save pressed while an auto-save waits: the second must not
    // displace the first, which would then never be answered.
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var a: SaveAnswer = .{};
    defer a.deinit();
    r.loop.requests.addSave(SaveAnswer.done, &a);
    r.loop.requests.addSave(SaveAnswer.done, &a);
    r.loop.serviceSaveRequests();
    try expectEqual(2, a.calls);
    try expect(std.mem.eql(u8, a.states[0].?, a.states[1].?));
}

// Loading

test "RunLoop: aLoadAnswersWithTheMachineItReplaced" {
    // The target and the running machine differ by a frame, so an answer
    // that handed back the loaded state instead of the replaced one shows.
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    const target = try saved(&m);
    defer alloc.free(target);
    m.runFrame();
    const before = try saved(&m);
    defer alloc.free(before);
    try expect(!std.mem.eql(u8, before, target));

    var a: LoadAnswer = .{};
    defer a.deinit();
    try requestLoad(r.loop, target, &a);
    r.loop.serviceLoadRequests();
    try expectEqual(0, a.code);
    try expect(std.mem.eql(u8, a.undo.?, before));
    const now = try saved(&m);
    defer alloc.free(now);
    try expect(std.mem.eql(u8, now, target));
}

test "RunLoop: aRefusedLoadLeavesTheMachineAsItWas" {
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    const before = try saved(&m);
    defer alloc.free(before);
    var a: LoadAnswer = .{};
    defer a.deinit();
    try requestLoad(r.loop, "garbage", &a);
    r.loop.serviceLoadRequests();
    try expect(a.code < 0);
    const now = try saved(&m);
    defer alloc.free(now);
    try expect(std.mem.eql(u8, now, before));
}

test "RunLoop: aPendingCardWriteReachesDiskBeforeTheLoad" {
    // A card write still waiting must reach disk before the load: the load
    // re-installs the cards from disk, and a stale file would undo the save.
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    r.loop.pending_cards.images[0] = @splat(0x5A);
    const state = try saved(&m);
    defer alloc.free(state);
    var a: LoadAnswer = .{};
    defer a.deinit();
    try requestLoad(r.loop, state, &a);
    r.loop.serviceLoadRequests();
    var out: [cards.bytes]u8 = undefined;
    try expect(r.store.load(io, 0, &out));
    try expect(std.mem.allEqual(u8, &out, 0x5A));
    try expect(r.loop.pending_cards.isEmpty());
}

test "RunLoop: aLoadReinstallsTheCardsFromDisk" {
    // The state restores the card's flag byte but not its contents, so a
    // load puts the card on disk back into the machine.
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    try expect(r.store.write(io, 1, &@as([cards.bytes]u8, @splat(0xA5))));
    var a: LoadAnswer = .{};
    defer a.deinit();
    try requestLoad(r.loop, "state", &a);
    r.loop.serviceLoadRequests();
    try expectEqual(1, m.count("loadMemcard 1"));
    try expectEqual(0, m.count("loadMemcard 0"));
}

test "RunLoop: aRefusedLoadReinstallsNoCard" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    m.fail_load = true;
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    try expect(r.store.write(io, 0, &@as([cards.bytes]u8, @splat(0xA5))));
    var a: LoadAnswer = .{};
    defer a.deinit();
    try requestLoad(r.loop, "garbage", &a);
    r.loop.serviceLoadRequests();
    try expectEqual(0, m.count("loadMemcard 0") + m.count("loadMemcard 1"));
    try expect(a.code < 0);
}

test "RunLoop: aLoadPendingWhenTheRunnerStopsIsAnsweredWithAFailure" {
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    const state = try saved(&m);
    defer alloc.free(state);
    var a: LoadAnswer = .{};
    defer a.deinit();
    try requestLoad(r.loop, state, &a);
    r.loop.failPendingRequests();
    try expectEqual(1, a.calls);
    try expectEqual(capi.PS1_ERR_SESSION_STOPPED, a.code);
}

// The memory cards

test "RunLoop: flushingWithNothingPendingWritesNoFile" {
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    // No game has run, so the machine has never dirtied a card.
    r.loop.flushMemoryCards();
    var out: [cards.bytes]u8 = undefined;
    try expect(!r.store.load(io, 0, &out));
    try expect(!r.store.load(io, 1, &out));
    // The write path only creates the directory once it has bytes to put
    // there; a flush that finds nothing pending must not conjure one.
    try std.testing.expectError(error.FileNotFound, r.scratch.tmp.dir.statFile(io, "cards", .{}));
}

test "RunLoop: writePendingCardsPutsTheRightBytesInTheRightSlotFile" {
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    r.loop.pending_cards.images[1] = @splat(0x5A);
    r.loop.pending_cards.writeAll(&r.store, io);
    var out: [cards.bytes]u8 = undefined;
    try expect(r.store.load(io, 1, &out));
    try expect(std.mem.allEqual(u8, &out, 0x5A));
    try expect(!r.store.load(io, 0, &out));
    try expect(r.loop.pending_cards.isEmpty());
}

test "RunLoop: writePendingCardsWritesEverySlotThatWasStaged" {
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    r.loop.pending_cards.images[0] = @splat(0x11);
    r.loop.pending_cards.images[1] = @splat(0x22);
    r.loop.pending_cards.writeAll(&r.store, io);
    var out: [cards.bytes]u8 = undefined;
    try expect(r.store.load(io, 0, &out));
    try expect(std.mem.allEqual(u8, &out, 0x11));
    try expect(r.store.load(io, 1, &out));
    try expect(std.mem.allEqual(u8, &out, 0x22));
}

test "RunLoop: aDirtyCardIsTakenCountedAndWrittenOnceItSettles" {
    // The span the Swift suite could not reach: the machine reporting a
    // dirty card, which the scripted machine can.
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    m.dirty_cards[0] = true;
    r.loop.serviceMemoryCards(0);
    try expectEqual(1, r.loop.card_writes.load(.acquire));
    var out: [cards.bytes]u8 = undefined;
    try expect(!r.store.load(io, 0, &out));
    r.loop.serviceMemoryCards(cards.FlushPolicy.settle_ns);
    try expect(r.store.load(io, 0, &out));
    try expect(std.mem.allEqual(u8, &out, m.card_fill));
}

const CardEvents = struct {
    n: usize = 0,
    last: u64 = 0,
    fn record(ctx: ?*anyopaque, ev: *const session.events.Ps1Event) callconv(.c) void {
        const self: *CardEvents = @ptrCast(@alignCast(ctx.?));
        if (ev.kind != @backingInt(session.events.Kind.card_write)) return;
        self.n += 1;
        self.last = ev.card_writes;
    }
};

test "RunLoop: aDirtiedCardSendsTheRunningCount" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var seen: CardEvents = .{};
    r.loop.events.sink = .{ .on_event = CardEvents.record, .ctx = &seen };
    m.dirty_cards[0] = true;
    r.loop.serviceMemoryCards(0);
    try expectEqual(1, seen.n);
    try expectEqual(1, seen.last);
}

test "RunLoop: aFailedCardWriteIsRetriedAfterAnotherSettle" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    // The card directory's path is a file: the write fails.
    try r.scratch.tmp.dir.writeFile(io, .{ .sub_path = "cards", .data = "x" });
    m.dirty_cards[0] = true;
    r.loop.serviceMemoryCards(0);
    r.loop.serviceMemoryCards(cards.FlushPolicy.settle_ns);
    try expect(!r.loop.pending_cards.isEmpty());

    try r.scratch.tmp.dir.deleteFile(io, "cards");
    // No new write from the game: the kept image goes out at the next settle.
    r.loop.serviceMemoryCards(2 * cards.FlushPolicy.settle_ns);
    try expect(r.loop.pending_cards.isEmpty());
    var out: [cards.bytes]u8 = undefined;
    try expect(r.store.load(io, 0, &out));
}

// Reset

test "RunLoop: aResetRequestWaitsForTheEmulatorThread" {
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, false);
    defer r.deinit();
    m.runFrame();
    m.runFrame();
    const before = try saved(&m);
    defer alloc.free(before);

    var a: Answer = .{};
    r.loop.requests.addReset(Answer.done, &a);
    const still = try saved(&m);
    defer alloc.free(still);
    try expect(std.mem.eql(u8, still, before));

    r.loop.serviceResetRequest();
    try expectEqual(0, a.code);
    var fresh = try handle();
    defer fresh.destroy();
    const want = try saved(&fresh);
    defer alloc.free(want);
    const now = try saved(&m);
    defer alloc.free(now);
    try expect(std.mem.eql(u8, now, want));
}

test "RunLoop: withNoResetRequestServicingDoesNothing" {
    var m = try handle();
    defer m.destroy();
    var r: Rig(HandleMachine) = undefined;
    try r.init(&m, false);
    defer r.deinit();
    m.runFrame();
    const before = try saved(&m);
    defer alloc.free(before);
    r.loop.serviceResetRequest();
    const now = try saved(&m);
    defer alloc.free(now);
    try expect(std.mem.eql(u8, now, before));
}

// The rules the Swift runner's comments carried.

test "RunLoop: aSaveAskedBeforeALoadCapturesTheMachineThePlayerWasLookingAt" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var la: LoadAnswer = .{};
    defer la.deinit();
    try requestLoad(r.loop, "state", &la);
    var sa: SaveAnswer = .{};
    defer sa.deinit();
    r.loop.requests.addSave(SaveAnswer.done, &sa);
    r.loop.serviceRequests(0);
    // saveState (the save), saveState (the load's undo), then loadState.
    const first_save = m.first("saveState").?;
    const last_save = m.last("saveState").?;
    try expect(first_save < last_save);
    try expect(last_save < m.first("loadState").?);
    try expectEqual(0, sa.code);
    try expectEqual(0, la.code);
}

test "RunLoop: aLoadAndAResetBothRequestAResync" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    r.x.queue.clearResync();
    var la: LoadAnswer = .{};
    defer la.deinit();
    try requestLoad(r.loop, "state", &la);
    r.loop.serviceLoadRequests();
    try expect(r.x.queue.needsResync());

    r.x.queue.clearResync();
    var a: Answer = .{};
    r.loop.requests.addReset(Answer.done, &a);
    r.loop.serviceResetRequest();
    try expect(r.x.queue.needsResync());
}

test "RunLoop: aRequestPastTheBoundIsAnsweredAtOnceWithBusy" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var answers: [requests.max_pending + 1]SaveAnswer = @splat(.{});
    defer for (&answers) |*a| a.deinit();
    for (&answers) |*a| r.loop.requests.addSave(SaveAnswer.done, a);
    try expectEqual(1, answers[requests.max_pending].calls);
    try expectEqual(capi.PS1_ERR_BUSY, answers[requests.max_pending].code);
    try expectEqual(0, answers[0].calls);
    r.loop.serviceSaveRequests();
    for (answers[0..requests.max_pending]) |a| try expectEqual(1, a.calls);
}

const Released = struct {
    n: usize = 0,

    fn release(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Released = @ptrCast(@alignCast(ctx.?));
        self.n += 1;
    }
};

test "RunLoop: aNewerSwapAnswersTheOlderOneSuperseded" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var older_bytes: Released = .{};
    var newer_bytes: Released = .{};
    var older: Answer = .{};
    var newer: Answer = .{};
    r.loop.requests.setSwap(.{ .bin = "a", .release = Released.release, .release_ctx = &older_bytes }, no_serial, .on, Answer.done, &older);
    r.loop.requests.setSwap(.{ .bin = "b", .release = Released.release, .release_ctx = &newer_bytes }, no_serial, .on, Answer.done, &newer);
    try expectEqual(capi.PS1_ERR_SUPERSEDED, older.code);
    // The superseded disc never went in, so its bytes are released at once.
    try expectEqual(1, older_bytes.n);
    try expectEqual(0, newer.calls);
    r.loop.serviceSwap();
    try expectEqual(0, newer.code);
    try expectEqual(1, m.count("swapDisc"));
    try expectEqual(0, newer_bytes.n);
}

const no_serial: session.settings.Serial = @splat(0);

/// What the disc hook was handed, and whether the swap's answer had run.
const DiscSeen = struct {
    calls: usize = 0,
    serial: session.settings.Serial = @splat(0),
    readbacks: session.settings.VramReadbacks = .on,
    answer: *const Answer,
    answered_before: usize = 0,

    fn hook(ctx: *anyopaque, serial: session.settings.Serial, readbacks: session.settings.VramReadbacks) void {
        const self: *DiscSeen = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.serial = serial;
        self.readbacks = readbacks;
        self.answered_before = self.answer.calls;
    }
};

fn serialOf(text: []const u8) session.settings.Serial {
    var s: session.settings.Serial = @splat(0);
    @memcpy(s[0..text.len], text);
    return s;
}

test "RunLoop: aRefusedSwapCallsNoDiscHook" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    m.fail_swap = true;
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var bytes: Released = .{};
    var a: Answer = .{};
    var seen: DiscSeen = .{ .answer = &a };
    r.loop.on_disc = .{ .f = DiscSeen.hook, .ctx = &seen };
    r.loop.requests.setSwap(.{ .bin = "a", .release = Released.release, .release_ctx = &bytes }, serialOf("SCES-00010"), .off, Answer.done, &a);
    r.loop.serviceSwap();
    try expectEqual(capi.PS1_ERR_BAD_CUE, a.code);
    try expectEqual(0, seen.calls);
}

test "RunLoop: anAcceptedSwapHandsTheHookItsSerialAndChoiceBeforeTheAnswer" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var bytes: Released = .{};
    var a: Answer = .{};
    var seen: DiscSeen = .{ .answer = &a };
    r.loop.on_disc = .{ .f = DiscSeen.hook, .ctx = &seen };
    r.loop.requests.setSwap(.{ .bin = "a", .release = Released.release, .release_ctx = &bytes }, serialOf("SCES-00010"), .off, Answer.done, &a);
    r.loop.serviceSwap();
    try expectEqual(capi.PS1_OK, a.code);
    try expectEqual(1, seen.calls);
    try std.testing.expectEqualStrings("SCES-00010", session.settings.serialSlice(&seen.serial));
    try expectEqual(.off, seen.readbacks);
    try expectEqual(0, seen.answered_before);
}

const PushProbe = struct {
    x: *Exchange,
    resync_at_copy: ?bool = null,
};

fn resyncAtCopy(m: *FakeMachine) void {
    const p: *PushProbe = @ptrCast(@alignCast(m.ctx.?));
    p.resync_at_copy = p.x.queue.needsResync();
}

test "RunLoop: aLoadPushesTheLoadedVramBeforeTheResync" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    r.loop.controls.gpu_vram = true;
    r.x.queue.clearResync();
    var probe: PushProbe = .{ .x = r.x };
    m.ctx = &probe;
    m.on_copy = resyncAtCopy;
    var la: LoadAnswer = .{};
    defer la.deinit();
    try requestLoad(r.loop, "state", &la);
    r.loop.serviceRequests(0);
    try expect(m.first("loadState").? < m.first("copyVramAsIs").?);
    try expectEqual(0, m.count("copyVram"));
    try expectEqual(false, probe.resync_at_copy.?);
    try expect(r.x.queue.needsResync());
    try expectEqual(1, r.x.acquireShadow().?.seq);
}

test "RunLoop: aResetPushesAZeroedVram" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    r.loop.controls.gpu_vram = true;
    r.x.queue.clearResync();
    var a: Answer = .{};
    r.loop.requests.addReset(Answer.done, &a);
    r.loop.serviceRequests(0);
    try expect(m.first("reset").? < m.first("copyVramAsIs").?);
    try expect(r.x.queue.needsResync());
    try expect(r.x.acquireShadow() != null);
}

test "RunLoop: aDualLoadStillRaisesTheResyncAlone" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    r.x.queue.clearResync();
    var la: LoadAnswer = .{};
    defer la.deinit();
    try requestLoad(r.loop, "state", &la);
    r.loop.serviceRequests(0);
    try expect(r.x.queue.needsResync());
    try expectEqual(0, m.count("copyVram"));
    try expectEqual(0, m.count("copyVramAsIs"));
}

test "RunLoop: aSaveReadsVramBackOnceForTheStateAndItsThumbnail" {
    var m = FakeMachine.init(alloc);
    defer m.deinit();
    var r: Rig(FakeMachine) = undefined;
    try r.init(&m, true);
    defer r.deinit();
    var sa: SaveAnswer = .{};
    defer sa.deinit();
    r.loop.requests.addSave(SaveAnswer.done, &sa);
    r.loop.serviceRequests(0);
    try expectEqual(0, sa.code);
    try expectEqual(0, m.count("copyVram"));
    try expect(m.first("saveState").? < m.first("copyVramAsIs").?);
}
