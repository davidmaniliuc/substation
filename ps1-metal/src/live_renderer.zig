//! The live command-stream renderer: drains the queue into the GPU's VRAM.
//!
//! Deliberately NOT the view's draw callback. A callback is not reachable
//! without a view, and the letterbox bug of 2026-08-20 is the standing
//! reminder of what that costs: it survived every compile-and-pipeline test
//! because only the pixels were ever wrong. The policy lives here so it is
//! testable offscreen; the view keeps only its own plumbing.

const std = @import("std");
const mtl = @import("mtl.zig");
const objc = @import("objc.zig");
const enums = @import("mtl_enums.zig");
const gather = @import("gather.zig");
const pi = @import("prim_instance.zig");
const speculative_region = @import("speculative_region.zig");
const stream_queue = @import("stream_queue.zig");
const MetalVram = @import("metal_vram.zig").MetalVram;
const Rasterizer = @import("rasterizer.zig").Rasterizer;
const pipelines = @import("pipelines.zig");

const Allocator = std.mem.Allocator;
const Display = stream_queue.Display;
const StreamQueue = stream_queue.StreamQueue;
const StreamSlot = stream_queue.StreamSlot;
const VramRect = pi.VramRect;
const native_width = pi.native_width;
const native_height = pi.native_height;
const native_pixels = pi.native_pixels;

/// One sample of the software side, from a SINGLE read: the VRAM, the PGXP
/// depth plane when the depth buffer is on (else null), and the seq they
/// were published under. The whole resync rule is written against that seq,
/// and two samples would not describe the same instant.
pub const Shadow = struct {
    pixels: *const [native_pixels]u16,
    depth: ?*const [native_pixels]u32,
    seq: u64,
};

/// Both switches are debug-only and read by the APP, never by a test.
pub const Options = struct {
    /// `PS1_LIVE_DIFF`: print the oracle's running tally.
    diff: bool = false,
    /// `PS1_LIVE_STATS`: the TEMPORARY drain-frequency probe.
    stats: bool = false,
};

/// The first divergence the oracle found between the texture and the shadow.
pub const DiffReport = struct {
    seq: u64,
    differing: usize,
    first_x: usize,
    first_y: usize,
    gpu: u16,
    shadow: u16,

    pub fn format(self: DiffReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("PS1_LIVE_DIFF: seq {d} diverged; {d} pixels, first at ({d}, {d}) gpu=0x{X} shadow=0x{X}", .{
            self.seq, self.differing, self.first_x, self.first_y, self.gpu, self.shadow,
        });
    }
};

/// Decisions between running tallies. About five seconds at 60 Hz, often
/// enough to see the ratio move against what is on screen, rare enough not
/// to bury a divergence report.
const diff_report_interval = 300;

pub const LiveRenderer = struct {
    alloc: Allocator,
    options: Options,
    vram: MetalVram,
    rasterizer: Rasterizer,

    /// The seq of the most recently executed stream. The divergence oracle
    /// compares against the shadow only when this matches the newest
    /// published frame, so it never diffs two different instants.
    last_executed_seq: u64 = 0,

    /// The seq of the newest stream to leave the queue, executed or
    /// discarded. The producer publishes a shadow only when something reads
    /// it, so the newest one can be older than frames this texture has
    /// already taken, and those are gone from the queue: a shadow is
    /// adoptable only at or above this.
    consumed_seq: u64 = 0,

    /// A dropped frame's mutations are still missing from the texture.
    ///
    /// Set when a frame is lost above 1x, where the answer is to KEEP the
    /// scaled picture rather than adopt a native shadow, and cleared by the
    /// adoption that eventually settles it. It exists because "keep the
    /// picture" was mistaken for a complete answer: the frame's mutations are
    /// gone from the stream either way, so without a debt recorded here
    /// nothing ever puts them back.
    repair_owed: bool = false,

    /// The region a speculative group drew over, saved before it did. Put
    /// back before the next real frame executes, never sooner: the display
    /// pass after this drain must still sample the speculative picture.
    /// Between frames the texture therefore holds only the real timeline,
    /// so the resync and dropped-frame rules apply unchanged.
    pending_restore: ?VramRect = null,

    /// Where the display pass should read the picture from while a
    /// speculative group is in the texture: a game that flips buffers draws
    /// its future frame somewhere the real frame's display does not point.
    present_display: ?Display = null,

    /// How many frames the oracle actually compared, and how many it
    /// declined to.
    ///
    /// Counted because the absence of output is otherwise ambiguous: a run
    /// that skipped every frame prints exactly what a run in which every
    /// frame matched prints; nothing. Only the second is evidence, and the
    /// skip is not rare. The diff runs after `drain`, which blocks on the
    /// GPU, so any frame the emulator publishes in that window advances the
    /// newest seq past `last_executed_seq` and the oracle goes quiet for it.
    diff_checked: usize = 0,
    diff_skipped: usize = 0,
    /// The native readback the oracle compares, allocated on its first
    /// comparison: most runs never diff.
    diff_buffer: ?*[native_pixels]u16 = null,

    stats: Stats = .{},

    /// Where `readNative` gathers into: native colour, then the native depth
    /// plane at `gather_depth_offset`. Shared storage, allocated on the first
    /// readback and kept, since a game that reads back reads back often.
    gather_buffer: ?mtl.Buffer = null,

    const gather_depth_offset = native_pixels * 2;

    pub const Metal = @import("metal_context.zig").Metal;

    /// On the heap, because the rasterizer holds a pointer to the VRAM.
    /// `set` is borrowed and must outlive the renderer.
    pub fn init(alloc: Allocator, m: Metal, set: *const pipelines.Set, scale: u32, depth_buffer: bool, o: Options) !*LiveRenderer {
        const self = try alloc.create(LiveRenderer);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .options = o, .vram = undefined, .rasterizer = undefined };
        self.vram = try MetalVram.init(alloc, m.device, m.queue, scale, depth_buffer);
        errdefer self.vram.deinit();
        self.rasterizer = try Rasterizer.init(alloc, &self.vram, set);
        // The display pass shares this queue, so commit order orders the
        // rasterizer's writes before its sampling. Blocking the draw callback
        // on the GPU would cost a frame for nothing.
        self.rasterizer.synchronous = false;
        return self;
    }

    /// A scale or depth-buffer change: a new `MetalVram` holding the old
    /// one's native VRAM, and a rasterizer over it that keeps the pipelines,
    /// the settings and the CPU state (environment, upload in progress) the
    /// stream has built up.
    ///
    /// The carry is what keeps a rebuild from needing a resync: a BLANK
    /// texture under an incremental stream is the bug behind Crash 1's level
    /// vanishing (2026-09-27), and the carry hands the new texture every
    /// page and CLUT the stream uploaded once. The picture drops to native
    /// until the game repaints it, as adopting a native shadow did. The depth
    /// plane is carried when it persists on both sides; otherwise the new
    /// plane starts far. A speculative picture is put back before the carry
    /// reads, so only the real timeline crosses.
    pub fn rebuildVram(self: *LiveRenderer, scale: u32, depth_buffer: bool) !void {
        // Both halves are built before the old ones go, so a failure leaves
        // the renderer as it was.
        var vram = try MetalVram.init(self.alloc, self.vram.device, self.vram.queue, scale, depth_buffer);
        errdefer vram.deinit();
        var r = try Rasterizer.init(self.alloc, &vram, self.rasterizer.pipelines);
        errdefer r.deinit();
        try self.carryInto(&vram);
        const old = self.rasterizer;
        self.rasterizer.deinit();
        self.vram.deinit();
        self.vram = vram;
        r.vram = &self.vram;
        self.rasterizer = r;
        self.rasterizer.setState(old.state());
        self.rasterizer.dither_mode = old.dither_mode;
        self.rasterizer.texture_filter = old.texture_filter;
        self.rasterizer.sprite_filter = old.sprite_filter;
        self.rasterizer.synchronous = old.synchronous;
        self.rasterizer.on_commit = old.on_commit;
        self.pending_restore = null;
        self.present_display = null;
    }

    /// The whole native VRAM (and the depth plane, while both sides keep one)
    /// from this renderer's texture into `vram`.
    fn carryInto(self: *LiveRenderer, vram: *MetalVram) !void {
        const full: VramRect = .{ .x0 = 0, .y0 = 0, .x1 = native_width - 1, .y1 = native_height - 1 };
        const colour = try self.alloc.create([native_pixels]u16);
        defer self.alloc.destroy(colour);
        if (self.vram.depth_persists and vram.depth_persists) {
            const plane = try self.alloc.create([native_pixels]u32);
            defer self.alloc.destroy(plane);
            self.readNative(full, colour, plane);
            vram.uploadNativeDepth(plane);
        } else self.readNative(full, colour, null);
        vram.uploadNative(colour);
    }

    /// Reached on eject, which is where a run shorter than one report
    /// interval would otherwise end with no tally at all.
    pub fn deinit(self: *LiveRenderer) void {
        if (self.options.diff and self.diff_checked + self.diff_skipped > 0) self.printSummary();
        if (self.diff_buffer) |b| self.alloc.destroy(b);
        if (self.gather_buffer) |b| b.release();
        self.rasterizer.deinit();
        self.vram.deinit();
        self.alloc.destroy(self);
    }

    /// Executes everything queued, in order, then returns.
    ///
    /// `shadow` has `fn sample(self) Shadow`, rather than being a value,
    /// because building it is a 1 MB copy (more with the depth plane) and the
    /// ordinary path never needs it. It is called only when a resync or a
    /// repair needs it, and at most once per drain.
    ///
    /// The producer publishes VRAM (and the depth plane, when valid) before
    /// the stream, so a shadow sampled at seq `S` accounts for every frame up
    /// to and including `S` and for none above it. It publishes one only when
    /// asked, so `S` may predate frames already executed; such a shadow is
    /// never adopted. That is what makes both halves of a resync exact: see
    /// `StreamQueue.discardThrough`. "Adopt the newest shadow and discard the
    /// whole backlog" is sound only if the shadow is sampled before the queue
    /// is inspected, which no ordering here can guarantee across two threads.
    pub fn drain(self: *LiveRenderer, queue: *StreamQueue, shadow: anytype) void {
        // TEMPORARY probe (2026-09-04). Remove with the fix.
        const stat_t = if (self.options.stats) now() else 0;
        defer if (self.options.stats) self.reportStats(queue, stat_t);

        const hard = queue.needsResync();
        // Read-and-clear, so a drop the producer records during this call is
        // seen next time rather than lost.
        const lost_frames = queue.takeDroppedFrames();

        // A dropped frame is answered DIFFERENTLY by scale, which is why the
        // decision lives here and not in the queue.
        //
        // At 1x adopting the shadow is exact (`uploadNative` IS `upload`),
        // and costs one upload, so a lost frame is genuinely repaired. That
        // exactness is what `PS1_LIVE_DIFF` at 1x is, and the default scale
        // must not opt out of the only oracle covering real games.
        //
        // Above 1x the shadow is a NATIVE image and adopting it replicates
        // each pixel N x N: the entire picture drops to nearest-neighbour 1x
        // until the game repaints it. A demanding game at 8x costs more than a
        // 60 Hz frame period to replay (silent-hill 28.5 ms against 16.7 ms),
        // so the ring fills over and over and the collapse fires with it: the
        // flicker between 8x and 1x. Keeping the scaled texture is the cheaper
        // error by far while the deficit lasts: what it costs is a stale
        // region rather than the whole image.
        //
        // This is the one place the "execution never skips a frame" rule is
        // relaxed, and it is narrower than it looks: a frame that never
        // reached the queue has NO records here to execute. The choice is not
        // whether to run it, nothing can, but whether to answer its absence
        // by throwing the scaled picture away.
        //
        // Deferred, though, and NOT abandoned. "Games clear and redraw every
        // frame, so it is corrected on the next one" is true of the display
        // area and false of the rest of VRAM: a texture page, a CLUT and a
        // VRAM->VRAM copy are written ONCE and sampled by every frame after,
        // and no later stream repeats them. FF7's main menu is the measured
        // case: the frame that opens it carries one 256x3 upload at
        // (256, 493), its palettes, and every frame after it carries 197
        // textured rectangles and zero payload words. Dropping that one frame
        // left the menu drawing its text through a stale CLUT for as long as
        // it stayed open, with nothing in the design that could ever repair
        // it.
        //
        // So a lost frame above 1x records a DEBT and keeps the picture, and
        // the debt is settled by the first drain that loses nothing. Settling
        // it while frames are still being lost would re-adopt a native shadow
        // on every draw of a sustained deficit, which is the 8x/1x flicker
        // under another name; waiting for the deficit to lift costs one frame
        // of nearest-neighbour picture at the end of a burst and repairs
        // everything the burst lost. A deficit that NEVER lifts is not
        // repaired at all: at that point no policy here both keeps the scale
        // and stays correct, and the remedy is a lower internal resolution.
        if (lost_frames) self.repair_owed = true;
        // At 1x this reduces to "adopt on the drop", the previous behaviour
        // and the exact one: there `uploadNative` IS `upload`, so the debt is
        // never carried and `PS1_LIVE_DIFF`'s per-frame equality is unbroken.
        const repair_due = self.repair_owed and (self.vram.scale == 1 or !lost_frames);

        if (!hard and !repair_due) return self.executeAll(queue);

        // Cleared BEFORE the sample, never after. `clearResync` is a store,
        // not a compare-and-clear, so a request raised by the producer after
        // the sample and cleared here would be swallowed, and the frame that
        // raised it was never enqueued, so its mutations would be lost for
        // good. Clearing first costs at worst one redundant resync.
        queue.clearResync();

        const s: Shadow = shadow.sample();
        // Too old to adopt: frames above it have already left the queue. Ask
        // for a fresh one, which the producer publishes with its next frame,
        // and adopt that on a later draw.
        if (s.seq < self.consumed_seq) {
            if (hard) {
                // The producer publishes a shadow with every frame while this
                // is raised, so the one it publishes next folds in everything
                // queued now. Replaying it onto a texture that is not a
                // picture of anything would only put garbage on screen.
                queue.requestResync();
                if (queue.discardAll()) |last| self.consumed_seq = last;
            } else {
                queue.requestShadow();
                self.executeAll(queue);
            }
            return;
        }
        self.repair_owed = false;
        // Adopting the shadow replaces the whole texture, the speculative
        // region with it, so there is nothing left to put back.
        self.pending_restore = null;
        self.present_display = null;
        // TEMPORARY probe (2026-09-04). Remove with the fix.
        const adopt_t = if (self.options.stats) now() else 0;
        self.vram.uploadNative(s.pixels);
        // The depth plane is part of the same shadow, adopted under the same
        // seq: a resync while depth is on must not leave the next frame
        // depth-testing against a blank plane, which would let a far polygon
        // cover a near one the software rasterizer kept hidden.
        if (s.depth) |d| self.vram.uploadNativeDepth(d);
        if (self.options.stats) {
            self.stats.adoptions += 1;
            self.stats.adopt_ns += now() - adopt_t;
        }
        // The texture now IS that frame, exactly. Adopting its seq is not
        // bookkeeping: it is the one moment the texture is known equal to a
        // specific shadow, and the oracle needs it to compare at all.
        self.last_executed_seq = s.seq;
        self.consumed_seq = s.seq;

        // A hole between the adopted shadow and the oldest surviving stream
        // means frames were lost (a full ring drops them at the producer), so
        // what remains cannot be replayed onto a matching base. Execute it
        // anyway to keep moving, and leave the flag raised so the next draw
        // adopts a shadow that covers the hole.
        if (queue.discardThrough(s.seq)) |next| {
            if (next != s.seq +% 1) queue.requestResync();
        }

        self.executeAll(queue);
    }

    /// Every queued slot, then the runahead group that follows them. Speculation
    /// runs after every drain, whichever path the drain took.
    fn executeAll(self: *LiveRenderer, queue: *StreamQueue) void {
        queue.drain(self, execute);
        self.speculate(queue);
    }

    fn execute(self: *LiveRenderer, slot: *const StreamSlot) void {
        // A real frame continues the real timeline, which the texture must
        // hold again first.
        self.settleSpeculation();
        self.replay(slot);
        self.last_executed_seq = slot.seq;
        self.consumed_seq = slot.seq;
        if (self.options.stats) self.stats.executed += 1;
    }

    fn replay(self: *LiveRenderer, slot: *const StreamSlot) void {
        const r = &self.rasterizer;
        r.beginFrame(slot.payload[0..slot.payload_count]);
        for (slot.records[0..slot.record_count]) |c| r.apply(c);
        r.endFrame();
    }

    /// Replays the runahead group that follows the newest real frame, for
    /// this drain's display only: the region it may write is saved first,
    /// and the rasterizer's own state is put back at once. With no new group
    /// the last speculative picture stays up until a real frame arrives.
    fn speculate(self: *LiveRenderer, queue: *StreamQueue) void {
        const group = queue.takeSpeculativeGroup(self.last_executed_seq) orelse return;
        defer queue.releaseSpeculativeGroup();
        self.settleSpeculation();
        const saved = self.rasterizer.state();
        if (speculative_region.of(group.frames(), self.rasterizer.env, self.rasterizer.transfer)) |region| {
            self.vram.saveRegion(region);
            self.pending_restore = region;
        }
        for (group.frames()) |*slot| self.replay(slot);
        self.rasterizer.setState(saved);
        self.present_display = group.display;
    }

    /// Puts the real timeline back in the texture. Public for the
    /// speculation gate, which hashes the texture between frames.
    pub fn settleSpeculation(self: *LiveRenderer) void {
        if (self.pending_restore) |r| self.vram.restoreRegion(r);
        self.pending_restore = null;
        self.present_display = null;
    }

    /// A native rect of the REAL timeline: `colour` (and `depth`) are the
    /// inclusive rect's `w * h` pixels, row-major, by `readbackNative`'s
    /// top-left-subtexel rule. Synchronous: gathered on its own command
    /// buffer after everything this renderer has committed.
    ///
    /// A speculative picture is put back first, because a readback is what
    /// the machine reads and the machine never ran those frames; the next
    /// group brings the picture back. A depth read while the plane is
    /// memoryless is far (0) everywhere: there is nothing to read.
    ///
    /// The rect must lie inside VRAM (splitting one that wraps is the
    /// caller's), and a wrong length panics, like `MetalVram.upload`.
    pub fn readNative(self: *LiveRenderer, r: VramRect, colour: []u16, depth: ?[]u32) void {
        if (r.x0 < 0 or r.y0 < 0 or r.x0 > r.x1 or r.y0 > r.y1 or r.x1 >= native_width or r.y1 >= native_height)
            @panic("LiveRenderer.readNative: the rect is not inside VRAM");
        const n: usize = @intCast((r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1));
        if (colour.len != n) @panic("LiveRenderer.readNative: colour is not the rect's pixel count");
        if (depth) |d| if (d.len != n) @panic("LiveRenderer.readNative: depth is not the rect's pixel count");

        self.settleSpeculation();
        const read_depth = depth != null and self.vram.depth_persists;
        const buffer = self.gatherBuffer();
        const set = self.rasterizer.pipelines;
        {
            const pool = objc.Pool.push();
            defer pool.pop();
            const cmd = self.vram.queue.commandBuffer() orelse @panic("LiveRenderer.readNative: queue.commandBuffer() returned nil");
            gather.encode(cmd, set.gather_colour, self.vram.texture, buffer, 0, r, self.vram.scale);
            if (read_depth) gather.encode(cmd, set.gather_depth, self.vram.depth, buffer, gather_depth_offset, r, self.vram.scale);
            cmd.commit();
            cmd.waitUntilCompleted();
            if (cmd.status() != .completed) @panic("LiveRenderer.readNative: the gather did not complete");
        }

        const base: [*]const u8 = @ptrCast(buffer.contents());
        const gathered: [*]const u16 = @ptrCast(@alignCast(base));
        @memcpy(colour, gathered[0..n]);
        if (depth) |d| {
            if (read_depth) {
                const planes: [*]const u32 = @ptrCast(@alignCast(base + gather_depth_offset));
                @memcpy(d, planes[0..n]);
            } else @memset(d, 0);
        }
    }

    fn gatherBuffer(self: *LiveRenderer) mtl.Buffer {
        if (self.gather_buffer) |b| return b;
        const b = self.vram.device.newBuffer(native_pixels * 6, enums.resourceOptions(.shared)) orelse
            @panic("LiveRenderer.readNative: newBuffer returned nil");
        self.gather_buffer = b;
        return b;
    }

    // MARK: The oracle

    /// The exploratory oracle: the render texture against the software
    /// shadow, per frame, on whatever is actually being played. Returns null
    /// when the texture matches, or when `seq` is not the frame the texture
    /// currently holds.
    ///
    /// The fixture corpus is a handful of streams; games booting and playing
    /// is coverage it does not have. This is how a divergence gets LOCALISED
    /// once it exists: the response is then to bank that window as a fixture
    /// with `zig build fixtures`, never to weaken a gate.
    ///
    /// The seq check is what keeps this usable: without it, every frame the
    /// emulator runs ahead of the renderer reports a divergence, and the real
    /// ones drown. It is also what makes the counters necessary: see
    /// `diff_checked`.
    ///
    /// `shadow` has `fn pixels(self) *const [native_pixels]u16` for the same
    /// reason `drain`'s source is not a value, and it matters MORE here: a
    /// skip is the common case rather than the rare one, so building the 1 MB
    /// copy before the seq check spends it on exactly the frames that were
    /// never going to read it. Compares VRAM only, never the sidecar.
    pub fn diff(self: *LiveRenderer, seq: u64, shadow: anytype) ?DiffReport {
        // A speculative picture is a future the shadow has not reached.
        if (seq != self.last_executed_seq or self.pending_restore != null or self.present_display != null) {
            return self.skipped();
        }
        // Without a buffer to read back into nothing was compared, so that
        // is one more way to return null as a skip.
        const got = self.diffBuffer() orelse return self.skipped();
        const want: *const [native_pixels]u16 = shadow.pixels();
        self.diff_checked += 1;
        self.reportTally();

        self.vram.readbackNative(got);

        var differing: usize = 0;
        var first: ?usize = null;
        for (got, want, 0..) |g, w, i| {
            if (g == w) continue;
            differing += 1;
            if (first == null) first = i;
        }
        const i = first orelse return null;
        return .{
            .seq = seq,
            .differing = differing,
            .first_x = i % native_width,
            .first_y = i / native_width,
            .gpu = got[i],
            .shadow = want[i],
        };
    }

    /// "PS1_LIVE_DIFF: checked N frames, skipped M", into `buf`.
    pub fn diffSummary(self: *const LiveRenderer, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "PS1_LIVE_DIFF: checked {d} frames, skipped {d}", .{ self.diff_checked, self.diff_skipped });
    }

    fn diffBuffer(self: *LiveRenderer) ?*[native_pixels]u16 {
        if (self.diff_buffer == null) self.diff_buffer = self.alloc.create([native_pixels]u16) catch null;
        return self.diff_buffer;
    }

    fn skipped(self: *LiveRenderer) ?DiffReport {
        self.diff_skipped += 1;
        self.reportTally();
        return null;
    }

    fn reportTally(self: *const LiveRenderer) void {
        if (!self.options.diff or (self.diff_checked + self.diff_skipped) % diff_report_interval != 0) return;
        self.printSummary();
    }

    fn printSummary(self: *const LiveRenderer) void {
        var buf: [96]u8 = undefined;
        const line = self.diffSummary(&buf) catch return;
        std.debug.print("{s}\n", .{line});
    }

    // MARK: TEMPORARY probe (2026-09-04)
    //
    // Frequency evidence for the "8x is laggy on Crash Warped" report. The
    // measured costs say an adoption at 8x is a ~20 ms scalar replication of
    // 67 MB plus a synchronous blit; what no offline measurement can say is
    // how often a live run takes that path. Remove with the fix.

    const Stats = struct {
        drains: usize = 0,
        executed: usize = 0,
        adoptions: usize = 0,
        adopt_ns: u64 = 0,
        drain_ns: u64 = 0,
        window_t: u64 = 0,
        published: u64 = 0,
        dropped: u64 = 0,
    };

    fn reportStats(self: *LiveRenderer, queue: *const StreamQueue, t0: u64) void {
        const st = &self.stats;
        const t = now();
        st.drain_ns += t - t0;
        st.drains += 1;
        if (st.window_t == 0) st.window_t = t;
        const elapsed = @as(f64, @floatFromInt(t - st.window_t)) / 1e9;
        if (elapsed < 1.0) return;

        const published = queue.published_count.load(.monotonic);
        const dropped = queue.dropped_count.load(.monotonic);
        std.debug.print(
            "[live-stats] {d:.1}s  scale={d}  published={d} dropped={d}  drains={d} ({d:.1} ms avg) executed={d}  adoptions={d} ({d:.1} ms avg)  pending={d}\n",
            .{
                elapsed,                          self.vram.scale,
                published - st.published,         dropped - st.dropped,
                st.drains,                        avgMs(st.drain_ns, st.drains),
                st.executed,                      st.adoptions,
                avgMs(st.adopt_ns, st.adoptions), queue.pendingCount(),
            },
        );
        st.* = .{ .window_t = t, .published = published, .dropped = dropped };
    }
};

fn avgMs(ns: u64, n: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6 / @as(f64, @floatFromInt(@max(n, 1)));
}

/// Darwin's CLOCK_UPTIME_RAW, the clock DispatchTime's uptime reads: the
/// probe has no `Io` to read one through.
extern "c" fn clock_gettime_nsec_np(clock_id: u32) u64;
const clock_uptime_raw = 8;

fn now() u64 {
    return clock_gettime_nsec_np(clock_uptime_raw);
}
