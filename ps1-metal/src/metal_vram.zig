//! The GPU-side PS1 VRAM: 1024x512 R16Uint, private storage, render target
//! and texture source at once.
//!
//! R16Uint and NOT RGBA8 is the decision the whole renderer hangs on. PS1
//! VRAM is simultaneously framebuffer, texture memory and CLUT storage: a
//! game draws into it and then samples the result as 4bpp, 8bpp or 16bpp
//! indexed data. Storing decoded colour destroys the bit patterns texture
//! sampling depends on, and hides bit 15: the mask/STP bit.
//!
//! Beside it (NOT instead of it) sits `sidecar`, an RGBA8 texture holding the
//! eight-bit colour of every pixel a draw has touched. It is written by the
//! same fragment shader invocation as a second colour attachment and read
//! only by the display shader. It is never sampled as a texel, never read
//! back by the game, never hashed by a gate and never compared by
//! `PS1_LIVE_DIFF`; VRAM is unchanged in every mode, which is why true colour
//! needs no gate exemption.
//!
//! The sidecar's ALPHA is per-pixel presence: 255 where it holds a real
//! eight-bit colour, 0 where the display falls back to `c << 3 | c >> 2` over
//! VRAM. Per-pixel rather than CPU-side dirty rectangles because it costs no
//! bookkeeping, cannot go stale, and is exact at rect boundaries.
//!
//! Every method that encodes a command traps rather than degrades, as the
//! Swift original did: a silently skipped clear or a readback that quietly
//! hands back zeroes is indistinguishable from a correct blank VRAM, and this
//! type is the trust anchor every gate reads its answer from.
//!
//! Autorelease: command buffers and encoders are autoreleased, so each
//! method that makes one drains its own `objc.Pool`.

const std = @import("std");
const fixture = @import("fixture");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const enums = @import("mtl_enums.zig");
const prim = @import("prim_instance.zig");

const Allocator = std.mem.Allocator;

pub const native_width = prim.native_width;
pub const native_height = prim.native_height;
pub const native_pixels = prim.native_pixels;

const zero_origin: mtl.Origin = .{ .x = 0, .y = 0, .z = 0 };

pub const MetalVram = struct {
    /// Internal resolution multiplier, 1...8. At 8 the render texture is
    /// 8192 x 4096 x 2 = 67 MB, and the scratch copy target is another 67 MB.
    ///
    /// Out of range PANICS rather than returning an error, unlike every other
    /// failure in `init`: whatever reads a scale back from a persisted
    /// setting clamps or rejects a bad value before it reaches here, so
    /// anything out of range now is a programming error, and a crash naming
    /// it beats a silent failure.
    scale: u32,

    device: mtl.Device,
    queue: mtl.CommandQueue,
    texture: mtl.Texture,
    /// The display-only eight-bit sidecar. Always allocated, at every dither
    /// mode: the mode is a runtime uniform on an already-built pipeline, and
    /// making the allocation conditional would put a texture rebuild behind a
    /// setting that deliberately has none.
    sidecar: mtl.Texture,
    /// The PGXP depth plane: `.r32Uint`, scaled like `texture`. `.private` and
    /// persisting while the depth buffer is on; `.memoryless` while it is off,
    /// which costs no RAM on an Apple GPU: the attachment has to exist for
    /// every pipeline to share one set of formats, but with nothing
    /// depth-tested its contents never need to leave tile memory.
    depth: mtl.Texture,
    depth_persists: bool,

    /// Staging for both directions. Shared storage, allocated once: readback
    /// runs per fixture frame and a per-frame allocation of up to 67 MB is
    /// pure waste.
    staging: mtl.Buffer,
    /// Allocated on FIRST USE and then kept. Lazy because the app never
    /// takes this path (the display samples the sidecar on the GPU): only
    /// tests and Gate 3 pull it back over the bus, and at scale 8 an eager
    /// allocation is 134 MB that a shipped build would never touch.
    sidecar_staging: ?mtl.Buffer = null,
    /// Allocated on first use, like `sidecar_staging`: a resync that adopts
    /// the depth plane is rare, and most builds run with the depth buffer
    /// off and never touch it.
    depth_staging: ?mtl.Buffer = null,
    /// Where `saveRegion` keeps a region of all three attachments, grown to
    /// the largest region seen and never shrunk: a game's speculative region
    /// is about the same size every frame.
    region_scratch: ?Scratch = null,

    const Scratch = struct {
        colour: mtl.Texture,
        sidecar: mtl.Texture,
        depth: ?mtl.Texture,

        fn release(self: Scratch) void {
            self.colour.release();
            self.sidecar.release();
            if (self.depth) |d| d.release();
        }
    };

    /// `alloc` is part of the interface the later tasks build against; nothing
    /// here needs the heap, since the caller owns every pixel array.
    pub fn init(alloc: Allocator, device: mtl.Device, queue: mtl.CommandQueue, scale: u32, depth_buffer: bool) !MetalVram {
        _ = alloc;
        if (scale < 1 or scale > 8) @panic("internal resolution must be 1...8");
        const w: usize = native_width * scale;
        const h: usize = native_height * scale;

        // .shaderRead as well as .renderTarget: the same texture is `read()`
        // at arbitrary coordinates by the fragment shader that is drawing
        // into it. That aliasing is legal only under the pass-splitting
        // invariant (nothing sampled during a render pass may have been
        // written during that pass), which the encoder's hazard tracking
        // enforces.
        const texture = try device.newTexture2D(.{ .format = .r16Uint, .width = w, .height = h, .storage = .private, .usage = .{ .renderTarget = true, .shaderRead = true } });
        errdefer texture.release();
        const staging = device.newBuffer(w * h * 2, enums.resourceOptions(.shared)) orelse return error.MetalAllocation;
        errdefer staging.release();
        // .shaderRead as well as .renderTarget for the same reason: the copy
        // path samples a frozen snapshot of it, and the display pass reads it
        // every frame.
        const sidecar = try device.newTexture2D(.{ .format = .rgba8Uint, .width = w, .height = h, .storage = .private, .usage = .{ .renderTarget = true, .shaderRead = true } });
        errdefer sidecar.release();
        const depth = try device.newTexture2D(.{ .format = .r32Uint, .width = w, .height = h, .storage = if (depth_buffer) .private else .memoryless, .usage = .{ .renderTarget = true } });
        errdefer depth.release();

        // The queue and device are the caller's; a reference of our own makes
        // `deinit` independent of the order the caller tears down in.
        _ = objc.retain(device.id);
        _ = objc.retain(queue.id);
        var self: MetalVram = .{
            .scale = scale,
            .device = device,
            .queue = queue,
            .texture = texture,
            .sidecar = sidecar,
            .depth = depth,
            .depth_persists = depth_buffer,
            .staging = staging,
        };
        self.clear();
        return self;
    }

    pub fn deinit(self: *MetalVram) void {
        if (self.region_scratch) |s| s.release();
        if (self.depth_staging) |b| b.release();
        if (self.sidecar_staging) |b| b.release();
        self.staging.release();
        self.depth.release();
        self.sidecar.release();
        self.texture.release();
        self.queue.release();
        self.device.release();
        self.* = undefined;
    }

    pub fn width(self: *const MetalVram) usize {
        return native_width * @as(usize, self.scale);
    }

    pub fn height(self: *const MetalVram) usize {
        return native_height * @as(usize, self.scale);
    }

    pub fn pixelCount(self: *const MetalVram) usize {
        return self.width() * self.height();
    }

    /// A .private texture's initial contents are unspecified. Every fixture
    /// replay starts from a blank VRAM by the format's own rule, so this is
    /// not hygiene.
    pub fn clear(self: *MetalVram) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pass = mtl.RenderPassDescriptor.renderPassDescriptor();
        const colour = pass.colorAttachment(0);
        colour.setTexture(self.texture);
        colour.setLoadAction(.clear);
        colour.setClearColor(.{ .red = 0, .green = 0, .blue = 0, .alpha = 0 });
        colour.setStoreAction(.store);
        // Alpha 0 is ABSENT, so a cleared sidecar is the correct starting
        // state: the display expands VRAM, which is blank too.
        self.clearSidecarAttachment(pass);
        self.attachDepth(pass, true);
        self.runClearPass(pass, "MetalVram.clear");
    }

    /// Marks the WHOLE sidecar absent without touching VRAM.
    ///
    /// The invalidation half of the coherence rules: a resync from a software
    /// frame carries a 5551 picture with no extra precision in it, so there
    /// is nothing to keep and claiming otherwise would display stale
    /// eight-bit colour under a new frame.
    ///
    /// Attachment 0 LOADS and STORES rather than being left off the
    /// descriptor: a pass with a hole at index 0 is a shape Metal validation
    /// has opinions about, and load/store says exactly what is meant; VRAM
    /// survives this.
    pub fn clearSidecar(self: *MetalVram) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pass = mtl.RenderPassDescriptor.renderPassDescriptor();
        const colour = pass.colorAttachment(0);
        colour.setTexture(self.texture);
        colour.setLoadAction(.load);
        colour.setStoreAction(.store);
        self.clearSidecarAttachment(pass);
        self.attachDepth(pass, false);
        self.runClearPass(pass, "MetalVram.clearSidecar");
    }

    fn clearSidecarAttachment(self: *MetalVram, pass: mtl.RenderPassDescriptor) void {
        const a = pass.colorAttachment(1);
        a.setTexture(self.sidecar);
        a.setLoadAction(.clear);
        a.setClearColor(.{ .red = 0, .green = 0, .blue = 0, .alpha = 0 });
        a.setStoreAction(.store);
    }

    /// Attachment 2, as every pass that draws into VRAM needs it. A memoryless
    /// texture cannot load or store, so off means clear-and-discard; on means
    /// load-and-store unless this pass is the one clearing it.
    pub fn attachDepth(self: *const MetalVram, pass: mtl.RenderPassDescriptor, clearing: bool) void {
        const a = pass.colorAttachment(2);
        a.setTexture(self.depth);
        a.setLoadAction(if (self.depth_persists and !clearing) .load else .clear);
        a.setClearColor(.{ .red = 0, .green = 0, .blue = 0, .alpha = 0 });
        a.setStoreAction(if (self.depth_persists) .store else .dontCare);
    }

    /// The encode-and-wait both clears above share. Needs an enclosing pool.
    fn runClearPass(self: *MetalVram, pass: mtl.RenderPassDescriptor, label: []const u8) void {
        const cmd = self.queue.commandBuffer() orelse fail(label, "queue.commandBuffer() returned nil");
        const enc = cmd.renderCommandEncoder(pass) orelse fail(label, "renderCommandEncoder(descriptor:) returned nil");
        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    fn fail(label: []const u8, what: []const u8) noreturn {
        std.debug.panic("{s}: {s}", .{ label, what });
    }

    fn size(self: *const MetalVram) mtl.Size {
        return .{ .width = self.width(), .height = self.height(), .depth = 1 };
    }

    /// A blit encoder on its own command buffer. Needs an enclosing pool.
    fn blitCommand(self: *MetalVram, label: []const u8) struct { mtl.CommandBuffer, mtl.BlitCommandEncoder } {
        const cmd = self.queue.commandBuffer() orelse fail(label, "queue.commandBuffer() returned nil");
        const blit = cmd.blitCommandEncoder() orelse fail(label, "blitCommandEncoder() returned nil");
        return .{ cmd, blit };
    }

    fn blitStagingToTexture(self: *MetalVram) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd, const blit = self.blitCommand("MetalVram.upload");
        blit.copyBufferToTexture(self.staging, 0, self.width() * 2, self.pixelCount() * 2, self.size(), self.texture, zero_origin);
        blit.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    fn blitTextureToStaging(self: *MetalVram) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd, const blit = self.blitCommand("MetalVram.readback");
        blit.copyTextureToBuffer(self.texture, zero_origin, self.size(), self.staging, 0, self.width() * 2, self.pixelCount() * 2);
        blit.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    fn stagingPixels(self: *const MetalVram, buffer: mtl.Buffer) []u16 {
        const base: [*]u16 = @ptrCast(@alignCast(buffer.contents()));
        return base[0..self.pixelCount()];
    }

    /// A SCALED image: `pixelCount()` entries. Identical to Phase B's at scale 1.
    pub fn upload(self: *MetalVram, pixels: []const u16) void {
        if (pixels.len != self.pixelCount()) @panic("MetalVram.upload: pixels is not pixelCount() entries");
        @memcpy(self.stagingPixels(self.staging), pixels);
        self.blitStagingToTexture();
        // INVALIDATE WHOLE. The incoming picture is 5551 with no extra
        // precision, and it replaces everything, so does its presence.
        self.clearSidecar();
    }

    /// A NATIVE image, replicated N x N into the scaled texture.
    ///
    /// This is the resync path the frame-pacing rules require when the frame
    /// queue or the stream buffer overflows and the software side's VRAM
    /// becomes the truth. CPU-side replication into the existing staging
    /// buffer is sufficient: the path is rare by construction, and a
    /// blit-and-blow-up render pass would need a pipeline and a pass
    /// boundary to save a copy nobody is waiting on.
    pub fn uploadNative(self: *MetalVram, pixels: *const [native_pixels]u16) void {
        // `upload` invalidates the sidecar, which covers the scale == 1 case
        // below as well as this one.
        if (self.scale == 1) return self.upload(pixels);
        const dst = self.stagingPixels(self.staging);
        const w = self.width();
        const s: usize = self.scale;
        for (0..native_height) |y| {
            const src_row = y * native_width;
            for (0..s) |sy| {
                var o = (y * s + sy) * w;
                for (0..native_width) |x| {
                    const v = pixels[src_row + x];
                    for (0..s) |_| {
                        dst[o] = v;
                        o += 1;
                    }
                }
            }
        }
        self.blitStagingToTexture();
        self.clearSidecar();
    }

    /// The SCALED image: `pixelCount()` entries.
    pub fn readback(self: *MetalVram, out: []u16) void {
        if (out.len != self.pixelCount()) @panic("MetalVram.readback: out is not pixelCount() entries");
        self.blitTextureToStaging();
        @memcpy(out, self.stagingPixels(self.staging));
    }

    /// The NATIVE view: each N x N block's TOP-LEFT subtexel. Subpixels other
    /// than the top-left may legitimately differ from their block's native
    /// value (that is what supersampling is), and this discards them, which
    /// is what makes the exactness property checkable.
    ///
    /// Reads out of the staging buffer directly rather than through
    /// `readback`: at scale 8 that would materialize a 67 MB copy per frame
    /// to keep 1/64th of it.
    pub fn readbackNative(self: *MetalVram, out: *[native_pixels]u16) void {
        self.blitTextureToStaging();
        const src = self.stagingPixels(self.staging);
        const s: usize = self.scale;
        const w = self.width();
        for (0..native_height) |y| {
            const src_row = y * s * w;
            const dst_row = y * native_width;
            for (0..native_width) |x| out[dst_row + x] = src[src_row + x * s];
        }
    }

    fn sidecarStagingBuffer(self: *MetalVram) mtl.Buffer {
        if (self.sidecar_staging) |b| return b;
        const b = self.device.newBuffer(self.pixelCount() * 4, enums.resourceOptions(.shared)) orelse
            fail("MetalVram.readbackSidecar", "newBuffer returned nil");
        self.sidecar_staging = b;
        return b;
    }

    fn blitSidecarToStaging(self: *MetalVram) mtl.Buffer {
        const buffer = self.sidecarStagingBuffer();
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd, const blit = self.blitCommand("MetalVram.readbackSidecar");
        blit.copyTextureToBuffer(self.sidecar, zero_origin, self.size(), buffer, 0, self.width() * 4, self.pixelCount() * 4);
        blit.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
        return buffer;
    }

    /// The SCALED sidecar: `pixelCount() * 4` bytes, R, G, B, A per pixel.
    pub fn readbackSidecar(self: *MetalVram, out: []u8) void {
        if (out.len != self.pixelCount() * 4) @panic("MetalVram.readbackSidecar: out is not pixelCount() * 4 bytes");
        const buffer = self.blitSidecarToStaging();
        const src: [*]const u8 = @ptrCast(buffer.contents());
        @memcpy(out, src[0..out.len]);
    }

    /// The NATIVE view of the sidecar: each N x N block's TOP-LEFT subtexel,
    /// `native_pixels * 4` bytes. The same view (and the same reasoning) as
    /// `readbackNative`.
    pub fn readbackSidecarNative(self: *MetalVram, out: *[native_pixels * 4]u8) void {
        const buffer = self.blitSidecarToStaging();
        const src: [*]const u8 = @ptrCast(buffer.contents());
        const s: usize = self.scale;
        const w = self.width();
        for (0..native_height) |y| {
            const src_row = y * s * w * 4;
            const dst_row = y * native_width * 4;
            for (0..native_width) |x| {
                const from = src_row + x * s * 4;
                const to = dst_row + x * 4;
                @memcpy(out[to..][0..4], src[from..][0..4]);
            }
        }
    }

    /// A NATIVE depth plane, replicated N x N like `uploadNative`'s pixels.
    /// A no-op while the plane is memoryless: there is nothing to persist.
    pub fn uploadNativeDepth(self: *MetalVram, plane: *const [native_pixels]u32) void {
        if (!self.depth_persists) return;
        const buffer = self.depth_staging orelse blk: {
            const b = self.device.newBuffer(self.pixelCount() * 4, enums.resourceOptions(.shared)) orelse
                fail("MetalVram.uploadNativeDepth", "newBuffer returned nil");
            self.depth_staging = b;
            break :blk b;
        };
        const base: [*]u32 = @ptrCast(@alignCast(buffer.contents()));
        const dst = base[0..self.pixelCount()];
        const s: usize = self.scale;
        const w = self.width();
        for (0..self.height()) |y| {
            for (0..w) |x| dst[y * w + x] = plane[(y / s) * native_width + x / s];
        }
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd, const blit = self.blitCommand("MetalVram.uploadNativeDepth");
        blit.copyBufferToTexture(buffer, 0, w * 4, self.pixelCount() * 4, self.size(), self.depth, zero_origin);
        blit.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    /// FNV-1a 64 over the full SCALED texture as little-endian u16, straight
    /// over the shared staging buffer. At scale 1 this is the value every
    /// Phase B gate compares.
    pub fn hash(self: *MetalVram) u64 {
        self.blitTextureToStaging();
        return fixture.fnv1a(std.mem.sliceAsBytes(self.stagingPixels(self.staging)));
    }

    /// FNV-1a 64 over the native view. This is the Phase C gate's currency:
    /// at every scale it must equal the 1x `hash` of the same replay.
    pub fn nativeHash(self: *MetalVram) u64 {
        self.blitTextureToStaging();
        if (self.scale == 1) return fixture.fnv1a(std.mem.sliceAsBytes(self.stagingPixels(self.staging)));
        // The top-left subtexels gathered into the front of the staging
        // buffer itself: row y*s only ever moves to row y, and a row's
        // gather reads ahead of where it writes, so nothing is overwritten
        // before it is read.
        const src = self.stagingPixels(self.staging);
        const s: usize = self.scale;
        const w = self.width();
        for (0..native_height) |y| {
            const src_row = y * s * w;
            const dst_row = y * native_width;
            for (0..native_width) |x| src[dst_row + x] = src[src_row + x * s];
        }
        return fixture.fnv1a(std.mem.sliceAsBytes(src[0..native_pixels]));
    }

    // MARK: Speculation

    /// Copies a native rectangle of VRAM, the sidecar and (while it persists)
    /// the depth plane aside. Encoded on this queue, so it lands after every
    /// pass committed before it and before every one after.
    pub fn saveRegion(self: *MetalVram, r: prim.VramRect) void {
        const s = self.scratch(self.regionWidth(r), self.regionHeight(r)) orelse return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd, const blit = self.blitRegionCommand();
        const origin = self.regionOrigin(r);
        const extent = self.regionSize(r);
        blit.copyTextureToTexture(self.texture, origin, extent, s.colour, zero_origin);
        blit.copyTextureToTexture(self.sidecar, origin, extent, s.sidecar, zero_origin);
        if (s.depth) |d| blit.copyTextureToTexture(self.depth, origin, extent, d, zero_origin);
        blit.endEncoding();
        cmd.setLabel("speculative region");
        cmd.commit();
    }

    /// Puts back what the last `saveRegion` of `r` copied aside.
    pub fn restoreRegion(self: *MetalVram, r: prim.VramRect) void {
        const s = self.region_scratch orelse return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd, const blit = self.blitRegionCommand();
        const origin = self.regionOrigin(r);
        const extent = self.regionSize(r);
        blit.copyTextureToTexture(s.colour, zero_origin, extent, self.texture, origin);
        blit.copyTextureToTexture(s.sidecar, zero_origin, extent, self.sidecar, origin);
        if (s.depth) |d| blit.copyTextureToTexture(d, zero_origin, extent, self.depth, origin);
        blit.endEncoding();
        cmd.setLabel("speculative region");
        cmd.commit();
    }

    fn blitRegionCommand(self: *MetalVram) struct { mtl.CommandBuffer, mtl.BlitCommandEncoder } {
        return self.blitCommand("MetalVram: no blit encoder for a speculative region");
    }

    fn regionWidth(self: *const MetalVram, r: prim.VramRect) usize {
        return @as(usize, @intCast(r.x1 - r.x0 + 1)) * self.scale;
    }

    fn regionHeight(self: *const MetalVram, r: prim.VramRect) usize {
        return @as(usize, @intCast(r.y1 - r.y0 + 1)) * self.scale;
    }

    fn regionOrigin(self: *const MetalVram, r: prim.VramRect) mtl.Origin {
        return .{ .x = @as(usize, @intCast(r.x0)) * self.scale, .y = @as(usize, @intCast(r.y0)) * self.scale, .z = 0 };
    }

    fn regionSize(self: *const MetalVram, r: prim.VramRect) mtl.Size {
        return .{ .width = self.regionWidth(r), .height = self.regionHeight(r), .depth = 1 };
    }

    fn scratch(self: *MetalVram, w: usize, h: usize) ?Scratch {
        if (self.region_scratch) |s| {
            if (s.colour.width() >= w and s.colour.height() >= h) return s;
        }
        const old = self.region_scratch;
        const gw = @max(w, if (old) |s| s.colour.width() else 0);
        const gh = @max(h, if (old) |s| s.colour.height() else 0);
        const colour = self.device.newTexture2D(.{ .format = self.texture.pixelFormat(), .width = gw, .height = gh, .storage = .private, .usage = .{} }) catch return null;
        const side = self.device.newTexture2D(.{ .format = self.sidecar.pixelFormat(), .width = gw, .height = gh, .storage = .private, .usage = .{} }) catch {
            colour.release();
            return null;
        };
        var depth: ?mtl.Texture = null;
        if (self.depth_persists) {
            depth = self.device.newTexture2D(.{ .format = self.depth.pixelFormat(), .width = gw, .height = gh, .storage = .private, .usage = .{} }) catch {
                colour.release();
                side.release();
                return null;
            };
        }
        if (old) |s| s.release();
        self.region_scratch = .{ .colour = colour, .sidecar = side, .depth = depth };
        return self.region_scratch;
    }
};
