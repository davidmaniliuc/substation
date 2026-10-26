//! The emulator thread's work, one pass at a time: the requests it services
//! between frames, and (in `frame_path.zig`) the frame itself.
//!
//! `RunLoop(M)` is generic over the machine so every ordering rule below is
//! tested against a scripted one. Only the emulator thread calls into it,
//! except where a function says otherwise; every other thread's action is a
//! request queued in `requests` or a store into `controls`.

const std = @import("std");
const capi = @import("ps1_capi");
const metal = @import("ps1_metal");
const machine = @import("machine.zig");
const cards = @import("cards.zig");
const thumbnail = @import("thumbnail.zig");
const requests = @import("requests.zig");
const Requests = requests.Requests;
const AudioRing = @import("audio_ring.zig").AudioRing;
const frame_path = @import("frame_path.zig");
const picture_frames = @import("ps1_core").savestate.rewind.picture_frames;

pub const Controls = @import("controls.zig").Controls;
pub const Outcome = frame_path.Outcome;
pub const Wait = frame_path.Wait;

/// Floats one `readAudio` may return: a frame's worth with plenty of room.
const audio_scratch_floats = 8192;

const Allocator = std.mem.Allocator;
const Exchange = metal.frame_exchange.Exchange;
const Lock = metal.lock.Lock;
const native_pixels = metal.prim_instance.native_pixels;
const log = std.log.scoped(.session);

pub fn RunLoop(comptime M: type) type {
    machine.check(M);
    return struct {
        const Self = @This();

        /// Used ONLY by save and load, which allocate the state buffer: the
        /// frame path allocates nothing.
        alloc: Allocator,
        io: std.Io,
        m: *M,
        x: *Exchange,
        ring: *AudioRing,
        requests: Requests = .{},

        /// Null where nothing persists the cards (a test): they are then
        /// never taken from the machine at all.
        cards: ?*const cards.CardStore,
        /// Images taken from the machine and not yet on disk, the debounce,
        /// and the scratch a card is taken into, all under `card_lock`. The
        /// emulator thread services them and the session's stop flushes them,
        /// after the join; the lock is what keeps that true if a later change
        /// ever lets the two overlap.
        pending_cards: cards.Pending = .{},
        flush: cards.FlushPolicy = .{},
        card_scratch: [cards.bytes]u8 = undefined,
        card_lock: Lock = .{},

        /// Polled by the frontend's 60 Hz HUD.
        card_writes: std.atomic.Value(u64) = .init(0),
        pad_status: std.atomic.Value(u32) = .init(0),

        /// The disc the machine is reading, released when a swap replaces it
        /// or the session ends.
        current_disc: ?machine.DiscBytes = null,

        controls: Controls = .{},
        /// What the machine was last told, so these cross only on change.
        /// Plain fields: this thread is their only reader and writer.
        applied_vertex_cache: bool = false,
        applied_engine: ?u8 = null,
        applied_rewind_budget: usize = 0,
        /// The seq of the newest frame run, shadow and stream alike.
        seq: u64 = 0,
        /// Frames of rewind history left, for the HUD.
        rewind_frames: std.atomic.Value(u32) = .init(0),
        audio_scratch: [audio_scratch_floats]f32 = undefined,
        /// A rewind step's went-back audio, reversed before it is written.
        rewind_audio: [picture_frames * audio_scratch_floats]f32 = undefined,

        pub fn create(alloc: Allocator, io: std.Io, m: *M, x: *Exchange, ring: *AudioRing, store: ?*const cards.CardStore) !*Self {
            const self = try alloc.create(Self);
            self.* = .{ .alloc = alloc, .io = io, .m = m, .x = x, .ring = ring, .cards = store };
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.alloc.destroy(self);
        }

        /// The texture no longer pictures the machine: a load, a reset, a
        /// rewind step. Raised on the queue the renderer drains.
        pub fn iterate(self: *Self, now_ns: u64) Outcome {
            return frame_path.iterate(self, now_ns);
        }

        pub fn setSpeed(self: *Self, n: u32) void {
            self.controls.speed.store(n, .release);
        }

        pub fn requestResync(self: *Self) void {
            self.x.queue.requestResync();
        }

        /// A load, a reset or a session start put a different machine under
        /// the texture. Dual raises the resync and lets the next frame's
        /// shadow answer it. GPU-only has no next shadow, so the machine's
        /// VRAM (complete: it came from a file or a zeroing) is pushed as one
        /// under a seq of its own FIRST, and the resync raised after it: one
        /// raised before would let the renderer adopt the previous shadow.
        pub fn machineReplaced(self: *Self) void {
            if (self.controls.gpu_vram) {
                self.seq +%= 1;
                self.x.frames_produced.store(self.seq, .release);
                frame_path.publishShadow(self, .as_is);
                self.x.publishDisplay(self.m.display());
            }
            self.requestResync();
        }

        pub fn publishPadStatus(self: *Self) void {
            self.pad_status.store(self.m.padStatus(), .release);
        }

        /// Everything serviced above the paused early-out, in its order: the
        /// cards (a player who saves and pauses at once must still find the
        /// save on disk), saves (the exit sheet PAUSES the game, and a save
        /// parked behind the pause would never run), then loads, so a save
        /// asked for before a load captures the machine the player was
        /// looking at, then a reset.
        pub fn serviceRequests(self: *Self, now_ns: u64) void {
            self.serviceMemoryCards(now_ns);
            self.serviceSaveRequests();
            self.serviceLoadRequests();
            self.serviceResetRequest();
        }

        /// Takes whatever the game has written and writes it out once the
        /// burst settles. Taken BEFORE the frame rather than after, which
        /// costs nothing: a block committed in frame N is collected at the
        /// top of frame N+1, and this way it also runs while the emulator is
        /// paused or waiting on the audio ring.
        pub fn serviceMemoryCards(self: *Self, now_ns: u64) void {
            const store = self.cards orelse return;
            self.card_lock.lock();
            defer self.card_lock.unlock();
            const dirty = self.takeCards();
            if (dirty) _ = self.card_writes.fetchAdd(1, .release);
            if (!self.flush.shouldWrite(dirty, now_ns)) return;
            self.pending_cards.writeAll(store, self.io);
            // A write that failed keeps its image and is tried again a settle
            // from now, whether or not the game writes again.
            if (!self.pending_cards.isEmpty()) self.flush.pending_since_ns = now_ns;
        }

        /// The unconditional flush: before a load, and at stop AFTER the
        /// emulator thread is joined, never before.
        pub fn flushMemoryCards(self: *Self) void {
            const store = self.cards orelse return;
            self.card_lock.lock();
            defer self.card_lock.unlock();
            _ = self.takeCards();
            self.pending_cards.writeAll(store, self.io);
            // Anything still held is due again on the next service.
            self.flush = .{ .pending_since_ns = if (self.pending_cards.isEmpty()) null else 0 };
        }

        /// Every slot's newly dirtied card into `pending_cards`. Caller holds
        /// `card_lock`.
        fn takeCards(self: *Self) bool {
            var dirty = false;
            for (0..cards.slots) |i| {
                const slot: u1 = @intCast(i);
                if (self.m.takeMemcard(slot, &self.card_scratch)) {
                    self.pending_cards.images[slot] = self.card_scratch;
                    dirty = true;
                }
            }
            return dirty;
        }

        /// Also what a session's `start` reads the cards with. A state
        /// carries no card bytes, but it does carry the card's flag byte, so without this the game would trust a directory it read
        /// before the state was saved. Re-installing marks the card freshly
        /// inserted, as a launch-time resume does.
        pub fn reinstallMemoryCards(self: *Self) void {
            const store = self.cards orelse return;
            self.card_lock.lock();
            defer self.card_lock.unlock();
            for (0..cards.slots) |i| {
                const slot: u1 = @intCast(i);
                if (!store.load(self.io, slot, &self.card_scratch)) continue;
                self.m.loadMemcard(slot, &self.card_scratch) catch |err| {
                    log.warn("memory card slot {d} failed to re-install: {s}", .{ i + 1, @errorName(err) });
                };
            }
        }

        /// The state and its thumbnail, taken in one go so the picture is
        /// exactly the saved frame. Every save waiting is answered from ONE
        /// snapshot.
        pub fn serviceSaveRequests(self: *Self) void {
            const saves = self.requests.takeSaves();
            if (saves.len == 0) return;
            const answers = saves.slice();
            const state = self.alloc.alloc(u8, self.m.saveStateSize()) catch {
                for (answers) |s| requests.answerSave(s, capi.PS1_ERR_OOM);
                return;
            };
            defer self.alloc.free(state);
            const written = self.m.saveState(state) catch |err| {
                for (answers) |s| requests.answerSave(s, machine.errorCode(err));
                return;
            };
            const png = self.thumbnailPng();
            defer if (png) |p| self.alloc.free(p);
            for (answers) |s| s.done(s.ctx, capi.PS1_OK, state.ptr, written, if (png) |p| p.ptr else null, if (png) |p| p.len else 0);
        }

        /// Null when the display is off or the encode failed: a save without
        /// a picture is still a save. Right after `saveState`, which settled
        /// all of VRAM, so the pixels are taken as they are: under GPU-only a
        /// second settle would read the whole texture back again.
        fn thumbnailPng(self: *Self) ?[]u8 {
            const vram = self.alloc.create([native_pixels]u16) catch return null;
            defer self.alloc.destroy(vram);
            self.m.copyVramAsIs(vram);
            return thumbnail.png(self.alloc, vram, self.m.display()) catch null;
        }

        /// The cards are flushed FIRST, then re-installed from disk after the
        /// load: see `reinstallMemoryCards`. Each completion gets the machine
        /// the load replaced (the undo state), or the refusal, in which case
        /// nothing changed: the load is all-or-nothing, and a refused load
        /// re-installs nothing.
        pub fn serviceLoadRequests(self: *Self) void {
            const loads = self.requests.takeLoads();
            for (loads.slice()) |l| {
                self.flushMemoryCards();
                const undo = self.alloc.alloc(u8, self.m.saveStateSize()) catch {
                    l.answer(capi.PS1_ERR_OOM, &.{});
                    continue;
                };
                defer self.alloc.free(undo);
                const written = self.m.saveState(undo) catch |err| {
                    l.answer(machine.errorCode(err), &.{});
                    continue;
                };
                self.m.loadState(l.state) catch |err| {
                    l.answer(machine.errorCode(err), &.{});
                    continue;
                };
                self.reinstallMemoryCards();
                self.publishPadStatus();
                // The texture still holds the replaced machine's picture.
                self.machineReplaced();
                l.answer(capi.PS1_OK, undo[0..written]);
            }
        }

        /// A reset frees the machine a frame may be running in (under the
        /// recompiler, the code buffer the thread executes), so only this
        /// thread may do it. The resync follows: the reset clears software
        /// VRAM while the texture still holds the old picture, and nothing
        /// queued carries that news.
        pub fn serviceResetRequest(self: *Self) void {
            const resets = self.requests.takeResets();
            if (resets.len == 0) return;
            self.m.reset();
            self.publishPadStatus();
            self.machineReplaced();
            for (resets.slice()) |r| r.answer(capi.PS1_OK);
        }

        /// A refused swap is not actionable from this thread and must not
        /// take the emulator down: the core rolled it back, the game runs on
        /// the disc it had, and the refused disc's bytes are released. A
        /// swap that goes in releases the disc it replaced.
        pub fn serviceSwap(self: *Self) void {
            const s = self.requests.takeSwap() orelse return;
            self.m.swapDisc(s.disc) catch |err| {
                s.done(s.ctx, machine.errorCode(err));
                s.disc.releaseBin();
                return;
            };
            if (self.current_disc) |old| old.releaseBin();
            self.current_disc = s.disc;
            s.done(s.ctx, capi.PS1_OK);
        }

        /// Called once the emulator thread is gone.
        pub fn failPendingRequests(self: *Self) void {
            self.requests.failAll(capi.PS1_ERR_SESSION_STOPPED);
        }
    };
}
