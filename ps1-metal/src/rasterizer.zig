//! Turns a recorded GP0 command stream into Metal work against a `MetalVram`.
//!
//! Every primitive is one INSTANCE of a bounding-box quad, with all its state
//! resolved here on the CPU and written into a `PrimInstance`. The only
//! pipeline state that differs between drawing primitives is the specialised
//! variant (`PrimVariant`), so a run of one variant is one instanced draw and
//! ordering is preserved by instance index: a run ends at a variant change, a
//! mover or a hazard. Consecutive draws stay in submission order whatever
//! pipeline each uses.
//!
//! Allocation is not on the emulator thread (that one hands over a copied
//! stream and returns), but it is on the render thread once per frame, so the
//! instance and payload buffers are persistent and reused rather than rebuilt.
//!
//! The per-record encoders for lines and the memory movers are in
//! `prim_encoders.zig`; this file is passes and resources, which is where the
//! hazard rule lives.

const std = @import("std");
const ps1_core = @import("ps1_core");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const pi = @import("prim_instance.zig");
const prim_builder = @import("prim_builder.zig");
const encoders = @import("prim_encoders.zig");
const pipelines = @import("pipelines.zig");
const HazardTracker = @import("hazard_tracker.zig").HazardTracker;
const MetalVram = @import("metal_vram.zig").MetalVram;

const Allocator = std.mem.Allocator;
const command = ps1_core.gpu.command;
const Command = command.Command;
const DrawingEnv = ps1_core.gpu.Regs.DrawingEnv;
const WriteCursor = ps1_core.gpu.WriteCursor;
const max_payload_words = ps1_core.gpu.recorder.max_payload_words;
const PrimInstance = pi.PrimInstance;
const VramRect = pi.VramRect;
const Kind = pi.Kind;
const Flag = pi.Flag;

pub const PrimVariant = pipelines.PrimVariant;

/// Which pipeline a draw step binds.
pub const DrawKind = union(enum) {
    prim: PrimVariant,
    fill,
    upload,
    copy,
    depth_clear,

    pub fn eql(a: DrawKind, b: DrawKind) bool {
        return std.meta.eql(a, b);
    }
};

pub const Step = union(enum) {
    /// Instances `[start, end)` of the frame's instance buffer.
    draw: struct { kind: DrawKind, start: usize, end: usize },
    /// Blit VRAM into `scratch`. Forces a pass boundary: a blit cannot be
    /// encoded inside a render pass.
    snapshot,
    pass_break,
};

/// One frame's two persistent buffers, plus the command buffer that may still
/// be reading them.
///
/// Commit order (see `synchronous`) orders GPU work against GPU work; it says
/// nothing about the CPU overwriting a buffer while a committed-but-unfinished
/// command buffer is still issuing reads of it. Blocking the next `beginFrame`
/// on the previous frame's completion is correct but serializes encode
/// against execute: per frame the cost becomes CPU + GPU rather than
/// max(CPU, GPU), and draining a backlog of N frames in one draw callback
/// costs N full frames back to back, so a renderer that fell behind could
/// never catch up. Cycling the buffers lets the CPU write frame n+1 while the
/// GPU still reads frame n.
const FrameBuffers = struct {
    /// Sized once at the recorder's own cap (2 MB) and reused.
    payload: mtl.Buffer,
    /// Grows by doubling and then stays. Instance count is NOT bounded by
    /// record count (a line record becomes one instance per pixel), so this
    /// cannot be sized from the recorder's cap. Per slot, because a grown
    /// buffer must not be shared with a slot whose in-flight command buffer
    /// bound the old one.
    instances: mtl.Buffer,
    instance_capacity: usize,
    /// Retained. Null whenever nothing is genuinely pending, so a frame that
    /// commits no work neither drops a real pending buffer nor makes a later
    /// `beginFrame` wait on a stale one.
    in_flight: ?mtl.CommandBuffer = null,
};

/// Three, matching a triple-buffered drawable: with up to three frames in
/// flight, a depth of two would hit the wait every frame and put the
/// serialization straight back.
const frame_buffer_depth = 3;

/// 65,536 instances is 14 MB at 216 bytes each, and covers every frame in the
/// fixture corpus with room to spare.
const initial_instances = 65_536;

pub const Rasterizer = struct {
    alloc: Allocator,
    vram: *MetalVram,
    pipelines: pipelines.Set,
    scratch: mtl.Texture,
    /// The sidecar's half of the copy snapshot. Blitted in the SAME
    /// `.snapshot` step as `scratch`, so both halves of a VRAM->VRAM copy read
    /// a source frozen at the same instant.
    sidecar_scratch: mtl.Texture,
    frames: [frame_buffer_depth]FrameBuffers,
    frame_index: usize = 0,

    env: DrawingEnv = .{},
    transfer: WriteCursor = .{},

    /// Where the dither pattern is sampled. A UNIFORM, not a flag cleared in
    /// the builder, so the instance bytes stay identical to the ones Gate 1
    /// checks whatever the mode is.
    dither_mode: pi.DitherMode = pi.default_dither,
    /// How 3D textured primitives sample, for the sidecar only. A uniform for
    /// `dither_mode`'s reason.
    texture_filter: pi.TextureFilter = .nearest,
    /// How sprites sample: textured rectangles and screen-aligned 2D polygons.
    sprite_filter: pi.TextureFilter = .nearest,

    /// Whether `endFrame` blocks until the GPU has finished. True for every
    /// fixture gate, which reads VRAM back the instant `endFrame` returns.
    /// False on the live path, where one command queue shared with the
    /// display pass already orders the rasterizer's writes before the
    /// display's sampling.
    synchronous: bool = true,

    /// Called with each frame's command buffer just before it is committed:
    /// the benchmark's way to add a completed handler reading the GPU's own
    /// timestamps. Null on every other path.
    on_commit: ?OnCommit = null,

    pass_count: usize = 0,
    /// Set once `apply` meets a record this backend does not model: without
    /// it a fixture carrying an unhandled kind replays to a wrong hash with
    /// nothing to say why.
    saw_unmodelled_kind: bool = false,

    instances: std.ArrayList(PrimInstance) = .empty,
    steps: std.ArrayList(Step) = .empty,
    hazards: HazardTracker,
    /// The frame's actual payload word count. A slot's payload buffer is
    /// always `max_payload_words` long; this is how much of it is valid.
    payload_count: usize = 0,

    pub const OnCommit = struct { ctx: *anyopaque, f: *const fn (*anyopaque, mtl.CommandBuffer) void };

    /// What a speculative group changes on the CPU side: the environment and
    /// an upload in progress, put back after replaying one as the pixels are.
    pub const State = struct { env: DrawingEnv, transfer: WriteCursor };

    pub fn init(alloc: Allocator, vram: *MetalVram, lib: mtl.Library) !Rasterizer {
        const pool = objc.Pool.push();
        defer pool.pop();
        const device = vram.device;
        var set = try pipelines.Set.init(device, lib);
        errdefer set.deinit();

        const scratch = try pipelines.texture(device, .r16Uint, vram.width(), vram.height());
        errdefer scratch.release();
        const sidecar_scratch = try pipelines.texture(device, .rgba8Uint, vram.width(), vram.height());
        errdefer sidecar_scratch.release();

        var frames: [frame_buffer_depth]FrameBuffers = undefined;
        var made: usize = 0;
        errdefer for (frames[0..made]) |f| {
            f.payload.release();
            f.instances.release();
        };
        const shared = @import("mtl_enums.zig").resourceOptions(.shared);
        for (&frames) |*f| {
            const payload = device.newBuffer(max_payload_words * 4, shared) orelse return error.MetalAllocation;
            const instances = device.newBuffer(initial_instances * @sizeOf(PrimInstance), shared) orelse {
                payload.release();
                return error.MetalAllocation;
            };
            f.* = .{ .payload = payload, .instances = instances, .instance_capacity = initial_instances };
            made += 1;
        }

        return .{
            .alloc = alloc,
            .vram = vram,
            .pipelines = set,
            .scratch = scratch,
            .sidecar_scratch = sidecar_scratch,
            .frames = frames,
            .hazards = HazardTracker.init(alloc),
        };
    }

    pub fn deinit(self: *Rasterizer) void {
        for (&self.frames) |*f| {
            if (f.in_flight) |cmd| {
                cmd.waitUntilCompleted();
                cmd.release();
            }
            f.payload.release();
            f.instances.release();
        }
        self.sidecar_scratch.release();
        self.scratch.release();
        self.pipelines.deinit();
        self.hazards.deinit();
        self.instances.deinit(self.alloc);
        self.steps.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn variantPipelineCount(self: *const Rasterizer) usize {
        return self.pipelines.variantCount();
    }

    pub fn state(self: *const Rasterizer) State {
        return .{ .env = self.env, .transfer = self.transfer };
    }

    pub fn setState(self: *Rasterizer, s: State) void {
        self.env = s.env;
        self.transfer = s.transfer;
    }

    // MARK: Frame lifecycle

    pub fn beginFrame(self: *Rasterizer, payload: []const u32) void {
        // Advance FIRST, then wait on the slot about to be overwritten, and
        // on that slot alone. With three slots this wait is essentially never
        // reached; when it is, it is the genuine "the GPU is a full cycle
        // behind" case that no depth avoids.
        self.frame_index = (self.frame_index + 1) % frame_buffer_depth;
        const f = &self.frames[self.frame_index];
        if (f.in_flight) |cmd| {
            cmd.waitUntilCompleted();
            cmd.release();
            f.in_flight = null;
        }

        self.resetFrame();
        if (payload.len > max_payload_words) @panic("a frame's payload is larger than the recorder's cap");
        self.payload_count = payload.len;
        if (payload.len > 0) {
            const dst: [*]u32 = @ptrCast(@alignCast(f.payload.contents()));
            @memcpy(dst[0..payload.len], payload);
        }
    }

    fn resetFrame(self: *Rasterizer) void {
        self.hazards.reset();
        self.instances.clearRetainingCapacity();
        self.steps.clearRetainingCapacity();
    }

    pub fn endFrame(self: *Rasterizer) void {
        // `endFrame` closes the last pass too, so this is a reset site
        // alongside `beginFrame`/`breakPass`: the next `beginFrame` would
        // reset anyway, but leaving it implicit invites the question.
        defer self.resetFrame();
        if (self.steps.items.len == 0 or self.instances.items.len == 0) return;

        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd = self.vram.queue.commandBuffer() orelse return;

        const f = &self.frames[self.frame_index];
        const count = self.instances.items.len;
        if (count > f.instance_capacity) {
            var cap = f.instance_capacity;
            while (cap < count) cap *= 2;
            const shared = @import("mtl_enums.zig").resourceOptions(.shared);
            const grown = self.vram.device.newBuffer(cap * @sizeOf(PrimInstance), shared) orelse return;
            // A command buffer retains what it binds, so an earlier frame
            // still reading the old buffer keeps it alive.
            f.instances.release();
            f.instances = grown;
            f.instance_capacity = cap;
        }
        const dst: [*]PrimInstance = @ptrCast(@alignCast(f.instances.contents()));
        @memcpy(dst[0..count], self.instances.items);

        var pass: Pass = .{ .r = self, .cmd = cmd, .frame = f };
        for (self.steps.items) |step| switch (step) {
            .pass_break => pass.close(),
            .snapshot => {
                pass.close();
                const blit = cmd.blitCommandEncoder() orelse continue;
                const origin: mtl.Origin = .{ .x = 0, .y = 0, .z = 0 };
                const size: mtl.Size = .{ .width = self.vram.width(), .height = self.vram.height(), .depth = 1 };
                blit.copyTextureToTexture(self.vram.texture, origin, size, self.scratch, origin);
                blit.copyTextureToTexture(self.vram.sidecar, origin, size, self.sidecar_scratch, origin);
                blit.endEncoding();
            },
            .draw => |d| {
                if (d.start == d.end) continue;
                const pipeline = switch (d.kind) {
                    .prim => |v| self.pipelines.prim(self.dither_mode == .true_color, v),
                    .fill => self.pipelines.fill,
                    .upload => self.pipelines.upload,
                    .copy => self.pipelines.copy,
                    .depth_clear => self.pipelines.depth_clear,
                };
                const e = pass.open() orelse continue;
                e.setRenderPipelineState(pipeline);
                // The prim path samples the ATTACHMENT ITSELF; only copy reads
                // the snapshot. Nothing else binds a texture at all.
                e.setFragmentTexture(if (d.kind == .copy) self.scratch else self.vram.texture, 0);
                // Bound for every kind: only the copy fragment declares it,
                // and a declared-but-unbound texture is a validation failure
                // rather than a black pixel.
                e.setFragmentTexture(self.sidecar_scratch, 1);
                e.drawPrimitives(.triangleStrip, 0, 4, d.end - d.start, d.start);
            },
        };
        pass.close();
        if (self.on_commit) |hook| hook.f(hook.ctx, cmd);
        cmd.commit();
        // Retained on THIS slot so the `beginFrame` that comes back round to
        // it waits before overwriting the buffers this command buffer bound.
        f.in_flight = cmd.retain();
        if (self.synchronous) cmd.waitUntilCompleted();
    }

    /// The render pass currently open, if any. Every pass loads and stores
    /// VRAM and the sidecar: both persist across frames and across passes,
    /// and every pass after the first in a frame must see the previous one's
    /// work.
    const Pass = struct {
        r: *Rasterizer,
        cmd: mtl.CommandBuffer,
        frame: *FrameBuffers,
        encoder: ?mtl.RenderCommandEncoder = null,

        fn close(self: *Pass) void {
            if (self.encoder) |e| e.endEncoding();
            self.encoder = null;
        }

        fn open(self: *Pass) ?mtl.RenderCommandEncoder {
            if (self.encoder) |e| return e;
            const r = self.r;
            const desc = mtl.RenderPassDescriptor.renderPassDescriptor();
            const colour = desc.colorAttachment(0);
            colour.setTexture(r.vram.texture);
            // .load, never .clear: VRAM persists across frames.
            colour.setLoadAction(.load);
            colour.setStoreAction(.store);
            const side = desc.colorAttachment(1);
            side.setTexture(r.vram.sidecar);
            side.setLoadAction(.load);
            side.setStoreAction(.store);
            r.vram.attachDepth(desc, false);
            const e = self.cmd.renderCommandEncoder(desc) orelse return null;
            e.setVertexBuffer(self.frame.instances, 0, 0);
            e.setFragmentBuffer(self.frame.instances, 0, 0);
            e.setFragmentBuffer(self.frame.payload, 0, 1);
            const uni: pi.Uniforms = .{
                .scale = r.vram.scale,
                .dither_mode = @backingInt(r.dither_mode),
                .texture_filter = @backingInt(r.texture_filter),
                .sprite_filter = @backingInt(r.sprite_filter),
            };
            e.setVertexBytes(std.mem.asBytes(&uni), 2);
            e.setFragmentBytes(std.mem.asBytes(&uni), 2);
            self.encoder = e;
            r.pass_count += 1;
            return e;
        }
    };

    // MARK: Records

    pub fn apply(self: *Rasterizer, cmd: Command) void {
        // Read as a byte: a record off disk may carry a kind this build does
        // not have, and an out-of-range enum is not a value to switch on.
        if (std.mem.asBytes(&cmd)[0] >= @typeInfo(command.Kind).@"enum".field_names.len) {
            self.saw_unmodelled_kind = true;
            return;
        }
        if (command.isEnvKind(cmd.kind)) return command.applyEnv(cmd, &self.env);
        switch (cmd.kind) {
            .draw_triangle => self.appendTriangle(cmd, Kind.flat_tri),
            .draw_shaded_triangle => self.appendTriangle(cmd, Kind.gouraud_tri),
            .draw_textured_triangle => self.appendTriangle(cmd, Kind.textured_tri),
            .draw_rectangle => self.appendRectangle(cmd, Kind.rect),
            .draw_textured_rectangle => self.appendRectangle(cmd, Kind.textured_rect),
            .draw_line, .draw_shaded_line => encoders.encodeLine(self, cmd),
            .fill_rect => encoders.encodeFill(self, cmd),
            .copy_rect => encoders.encodeCopy(self, cmd),
            .vram_write_setup => self.transfer = WriteCursor.setup(cmd.x, cmd.y, cmd.w, cmd.h),
            .vram_write_data => encoders.encodeUpload(self, cmd),
            .vram_write_abort => self.transfer.abort(),
            // Moves no pixel. GPUREAD is served from the software shadow, so
            // there is nothing to do here, and that is "irrelevant", not
            // "unmodelled".
            .vram_read_setup => {},
            .clear_depth => encoders.encodeDepthClear(self, cmd),
            .set_draw_env, .latch_texpage, .set_texture_disable_allowed, .reset_draw_env => unreachable,
        }
    }

    fn appendTriangle(self: *Rasterizer, cmd: Command, kind: i32) void {
        var inst = prim_builder.triangle(cmd, self.env, kind) orelse return;
        if (kind == Kind.textured_tri) prim_builder.applyTexture(cmd, &inst);
        self.appendPrim(inst);
    }

    fn appendRectangle(self: *Rasterizer, cmd: Command, kind: i32) void {
        var inst = prim_builder.rectangle(cmd, self.env, kind) orelse return;
        if (kind == Kind.textured_rect) prim_builder.applyTexture(cmd, &inst);
        self.appendPrim(inst);
    }

    // MARK: Steps

    /// One instance on the frame's list. Allocation failure here is a
    /// programmer-level event for the same reason as in `HazardTracker`.
    pub fn pushInstance(self: *Rasterizer, inst: PrimInstance) void {
        self.instances.append(self.alloc, inst) catch @panic("rasterizer out of memory");
    }

    pub fn pushStep(self: *Rasterizer, step: Step) void {
        self.steps.append(self.alloc, step) catch @panic("rasterizer out of memory");
    }

    /// Ends the current render pass: the next draw opens a fresh one, whose
    /// texture reads see everything stored before it. A copy brackets itself
    /// with this, because it reads VRAM through a snapshot; fills and uploads
    /// go through `appendWrite` instead.
    pub fn breakPass(self: *Rasterizer) void {
        self.hazards.reset();
        if (self.steps.items.len > 0 and self.steps.items[self.steps.items.len - 1] == .pass_break) return;
        self.pushStep(.pass_break);
    }

    /// Extends the last step when it is a draw of `kind` ending at `start`,
    /// else starts a new one: consecutive instances of one kind are one
    /// instanced draw.
    fn coalesce(self: *Rasterizer, kind: DrawKind, start: usize, end: usize) void {
        if (self.steps.items.len > 0) {
            const last = &self.steps.items[self.steps.items.len - 1];
            if (last.* == .draw and last.draw.kind.eql(kind) and last.draw.end == start) {
                last.draw.end = end;
                return;
            }
        }
        self.pushStep(.{ .draw = .{ .kind = kind, .start = start, .end = end } });
    }

    /// A fill or an upload: it WRITES its boxes and samples nothing, so the
    /// hazard rule orders it exactly as it orders a primitive. It starts a new
    /// pass only when it overwrites what this pass already sampled, and a
    /// later draw sampling its boxes breaks as usual.
    ///
    /// Every mover once ended the pass on both sides. FF8 uploads each movie
    /// frame as ~200 strips, so that was ~200 passes a frame, and at a fixed
    /// cost per pass it saturated the GPU at every scale.
    pub fn appendWrite(self: *Rasterizer, kind: DrawKind, start: usize, end: usize) void {
        if (start == end) return;
        const written = self.instances.items[start..end];
        for (written) |inst| {
            if (self.hazards.needsBreakWriting(boxOf(inst))) {
                self.breakPass();
                break;
            }
        }
        for (written) |inst| self.hazards.markWritten(boxOf(inst));
        self.coalesce(kind, start, end);
    }

    /// Drawing primitives of one `PrimVariant` accumulate into ONE instanced
    /// draw. A run ends at a variant change, a mover or a hazard.
    pub fn appendPrim(self: *Rasterizer, inst: PrimInstance) void {
        var buf: [4]VramRect = undefined;
        const sampled = prim_builder.sampledRects(inst, &buf);
        const box = boxOf(inst);
        if (self.hazards.needsBreakSampling(sampled) or self.hazards.needsBreakWriting(box)) {
            self.breakPass();
        }
        self.hazards.markRead(sampled);
        self.hazards.markWritten(box);
        // The destination is read wherever the shader reads `dst`, `dst_side`
        // or `dst_depth`: blending, the mask check and the depth test, plus a
        // persisting depth plane, where every draw that does not write its
        // own depth writes the stored one back. That last term carries no
        // flag, and only `anUntestedDrawKeepsTheStoredDepthWhileThePlanePersists`
        // pins it: read it before narrowing this.
        const variant: PrimVariant = .{
            .kind = inst.kind,
            .reads_dst = inst.flags & (Flag.transparent | Flag.check_mask | Flag.depth_test) != 0 or
                self.vram.depth_persists,
        };
        const i = self.instances.items.len;
        self.pushInstance(inst);
        self.coalesce(.{ .prim = variant }, i, i + 1);
    }
};

pub fn boxOf(inst: PrimInstance) VramRect {
    return .{ .x0 = inst.box_x0, .y0 = inst.box_y0, .x1 = inst.box_x1, .y1 = inst.box_y1 };
}
