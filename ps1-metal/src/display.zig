//! The display pass: the picture the window shows, drawn from the render
//! texture (or, behind the debug seam, the 1x shadow) and the true-colour
//! sidecar into a BGRA target,
//! letterboxed to 4:3. Plus the pure pieces the draw loop feeds it: the
//! letterbox scale, the pause grey-out and the toolbar band.

const std = @import("std");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const mtl_enums = @import("mtl_enums.zig");
const pi = @import("prim_instance.zig");
const Display = @import("stream_queue.zig").Display;

const assert = std.debug.assert;
const native_width = pi.native_width;
const native_height = pi.native_height;
pub const native_pixels = pi.native_pixels;

/// Mirrors `Params` in Shaders/DisplayShader.metal. Field order and types
/// must match exactly.
///
/// Both sides are 4-byte aligned throughout, so this is 80 bytes with no
/// padding question: pinned by `static_assert` over there and by the
/// `comptime` below here.
pub const Params = extern struct {
    vram_x: u32,
    vram_y: u32,
    width: u32,
    height: u32,
    depth24: u32,
    enabled: u32,
    /// Letterboxing: 1 on the axis that fills.
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    /// Debug seam: read the 1x shadow at 15bpp too.
    software_display: u32 = 0,
    /// Internal resolution, 1...8. Defaults to 1 and never 0: the fragment
    /// shader divides by it.
    scale: u32 = 1,
    /// 1 draws the picture as is; the paused game eases toward 0.6.
    saturation: f32 = 1,
    /// The toolbar band, in drawable pixels: `applyBand` fills these in.
    /// A `band_mix` of 0 draws no band, which is what every offscreen render
    /// (screenshots, the tests) gets by default.
    band_px: f32 = 0,
    band_edge_px: f32 = 0,
    band_sigma_px: f32 = 0,
    band_mix: f32 = 0,
    uv_per_px_x: f32 = 0,
    uv_per_px_y: f32 = 0,
    /// `deinterlace.Mode`'s raw value when the picture is rebuilt from its
    /// fields, else 0: the texture as drawn. Only `deinterlace.picture`
    /// sets it.
    deint: u32 = 0,
    /// The newest field's row parity, counted from the display's first row.
    newest: u32 = 0,
    /// Adaptive: 1 when the source's `reference` is an older picture to
    /// judge motion against. Without one the picture is woven.
    has_reference: u32 = 0,
};

comptime {
    assert(@sizeOf(Params) == 80);
}

/// What a picture is drawn from: the render texture and its sidecar, and
/// Adaptive's older picture. A null `reference` binds the pass's own
/// stand-in, since every texture a fragment declares must be bound.
pub const Source = struct {
    vram: mtl.Texture,
    sidecar: mtl.Texture,
    reference: ?mtl.Texture = null,
};

/// The display mode as the producer published it, with every per-draw value
/// (letterbox, scale, fades, band) at its default for the caller to set.
pub fn paramsFor(d: Display) Params {
    return .{
        .vram_x = d.vram_x,
        .vram_y = d.vram_y,
        .width = d.width,
        .height = d.height,
        .depth24 = @intFromBool(d.depth24),
        .enabled = @intFromBool(d.enabled),
    };
}

/// Multipliers that fit a picture of shape `target` (width over height)
/// inside a drawable of `width` x `height`.
///
/// The PS1 output is 4:3 whatever the pixel resolution is, so aspect
/// correction is a property of the display, not of the framebuffer's
/// `width/height`; the widescreen hack only changes which shape that is.
///
/// Exactly `(1, 1)` when the drawable is already `target`, and SNAPPED there
/// rather than computed: the window is aspect-locked so the ratio lands a
/// hair off 1.0, and a scale of 0.99999 blacks out the outermost pixel column
/// for nothing. A zero-sized drawable also returns `(1, 1)`: the shader
/// divides by these, so 0 would hand it a NaN uv.
pub fn letterboxScale(width: f64, height: f64, target: f64) struct { x: f32, y: f32 } {
    if (!(width > 0 and height > 0)) return .{ .x = 1, .y = 1 };
    const view_aspect = width / height;
    // Total bar width in device pixels is height * |view_aspect - target|.
    if (height * @abs(view_aspect - target) < 0.5) return .{ .x = 1, .y = 1 };
    return if (view_aspect > target)
        .{ .x = @floatCast(target / view_aspect), .y = 1 }
    else
        .{ .x = 1, .y = @floatCast(view_aspect / target) };
}

/// An ease-in-out over `duration` between 0 and 1, driven by the draw loop's
/// own clock. The first draw lands on its target, and a long stall between
/// draws is one full step, never an overshoot.
pub const DrawFade = struct {
    duration: f64,
    /// 0 off, 1 on, before easing.
    progress: f64 = 0,
    last: ?f64 = null,

    pub fn eased(self: *DrawFade, on: bool, now: f64) f32 {
        const step = if (self.last) |l| @min(now - l, self.duration) / self.duration else 1;
        self.last = now;
        self.progress = if (on) @min(self.progress + step, 1) else @max(self.progress - step, 0);
        const p = self.progress;
        return @floatCast(p * p * (3 - 2 * p));
    }
};

/// The paused picture's grey-out toward `paused_saturation`.
pub const PauseFade = struct {
    pub const paused_saturation: f32 = 0.6;
    pub const duration = 0.25;

    fade: DrawFade = .{ .duration = duration },

    pub fn saturation(self: *PauseFade, paused: bool, now: f64) f32 {
        return 1 - self.fade.eased(paused, now) * (1 - paused_saturation);
    }
};

/// The toolbar band drawn into the picture behind the traffic lights and the
/// title. It is the shader's because no AppKit blur reaches the Metal
/// picture: a material frosts it into a flat tint, and the toolbar's own
/// scroll-edge band drew an opaque bar over it.
///
/// ToolbarBand's geometry stays a Swift constant (spec); it arrives here as points.
pub const Band = struct {
    /// The unified toolbar's height, which centres the traffic lights.
    height: f64,
    /// The hard scroll edge's short fade at the bottom.
    edge: f64,
    sigma: f64,
};

/// Fills the band's fields for a drawable of `size_px` pixels laid out in
/// `points`, the letterbox already in `p`.
pub fn applyBand(p: *Params, band: Band, mix: f32, size_px: [2]f64, points: [2]f64) void {
    if (!(size_px[0] > 0 and size_px[1] > 0 and points[1] > 0)) return;
    const px_per_pt = size_px[1] / points[1];
    p.band_px = @floatCast(band.height * px_per_pt);
    p.band_edge_px = @floatCast(band.edge * px_per_pt);
    p.band_sigma_px = @floatCast(band.sigma * px_per_pt);
    p.band_mix = mix;
    // uv spans the picture, which the letterbox shrinks inside the drawable.
    const w: f32 = @floatCast(size_px[0]);
    const h: f32 = @floatCast(size_px[1]);
    p.uv_per_px_x = 1 / (w * p.scale_x);
    p.uv_per_px_y = 1 / (h * p.scale_y);
}

/// A post-process over the finished picture. The raw values are the C ABI's
/// `PS1_EFFECT_*`, pinned in ps1-session's `abi.zig`.
pub const Effect = enum(u32) {
    none = 0,
    sharp_bilinear = 1,
    scanlines = 2,
    crt = 3,
    composite = 4,

    /// The fragment function that draws the effect, null for `none`: the one
    /// table from an effect to its shader.
    pub fn fragmentName(self: Effect) ?[:0]const u8 {
        return switch (self) {
            .none => null,
            .sharp_bilinear => "effect_sharp_bilinear_fragment",
            .scanlines => "effect_scanlines_fragment",
            .crt => "effect_crt_fragment",
            .composite => "effect_composite_fragment",
        };
    }
};

/// Mirrors `EffectParams` in Shaders/DisplayShader.metal, bound at fragment
/// buffer 1 beside `Params`. Scalars only, 48 bytes: pinned by `static_assert`
/// over there and by the `comptime` below.
pub const EffectParams = extern struct {
    /// The picture texture, in texels.
    picture_w: f32 = 0,
    picture_h: f32 = 0,
    /// The letterboxed picture in drawable pixels, and its left edge.
    out_w: f32 = 0,
    out_h: f32 = 0,
    origin_x: f32 = 0,
    /// The programmed display area, in native pixels.
    native_w: f32 = 0,
    native_h: f32 = 0,
    scan_rows: f32 = 0,
    /// Whole drawable pixels per picture texel, never below 1.
    sharp_x: f32 = 1,
    sharp_y: f32 = 1,
    scan_strength: f32 = 0,
    mask_strength: f32 = 0,
};

comptime {
    assert(@sizeOf(EffectParams) == 48);
}

/// The scan rows a display has: a screen of more than 256 lines is two
/// interlaced fields, and a scan row is one line of a field.
pub fn scanRows(height: u32) u32 {
    return if (height > 256) height / 2 else height;
}

/// 0 at or below `lo`, 1 at or above `hi`, linear between: how far a
/// structure that needs `lo`...`hi` drawable pixels per unit has room to show.
pub fn floorFade(px_per_unit: f32, lo: f32, hi: f32) f32 {
    return std.math.clamp((px_per_unit - lo) / (hi - lo), 0, 1);
}

/// A scan row needs 2 pixels to exist and 3 to be drawn in full.
const scan_floor = [2]f32{ 2, 3 };
/// A phosphor triad of three stripes needs 3 pixels a native column to exist,
/// and 4.5 for the stripes to carry colour.
const mask_floor = [2]f32{ 3, 4.5 };

/// Whole drawable pixels per texel, at least 1: what keeps a texel a hard
/// square at a whole ratio.
pub fn sharpPrescale(out_px: f32, picture_px: f32) f32 {
    if (!(picture_px > 0)) return 1;
    return @max(1, @floor(out_px / picture_px));
}

/// What the effect fragments need for a picture drawn from `p` (the
/// letterbox and band already in it) into a drawable of `drawable_px`. A
/// degenerate drawable or display gives the safe zeros the shader paints
/// black over.
pub fn effectParams(p: Params, drawable_px: [2]f64) EffectParams {
    if (!(drawable_px[0] > 0 and drawable_px[1] > 0) or p.width == 0 or p.height == 0) return .{};
    const drawable_w: f32 = @floatCast(drawable_px[0]);
    const drawable_h: f32 = @floatCast(drawable_px[1]);
    const scale: f32 = @floatFromInt(p.scale);
    const native_w: f32 = @floatFromInt(p.width);
    const native_h: f32 = @floatFromInt(p.height);
    const rows: f32 = @floatFromInt(scanRows(p.height));
    const picture_w = native_w * scale;
    const picture_h = native_h * scale;
    const out_w = drawable_w * p.scale_x;
    const out_h = drawable_h * p.scale_y;
    return .{
        .picture_w = picture_w,
        .picture_h = picture_h,
        .out_w = out_w,
        .out_h = out_h,
        .origin_x = (drawable_w - out_w) / 2,
        .native_w = native_w,
        .native_h = native_h,
        .scan_rows = rows,
        .sharp_x = sharpPrescale(out_w, picture_w),
        .sharp_y = sharpPrescale(out_h, picture_h),
        .scan_strength = floorFade(out_h / rows, scan_floor[0], scan_floor[1]),
        .mask_strength = floorFade(out_w / native_w, mask_floor[0], mask_floor[1]),
    };
}

/// The display pipeline and the 1x shadow the `PS1_SOFTWARE_DISPLAY` seam
/// reads from.
pub const DisplayPass = struct {
    pipeline: mtl.RenderPipelineState,
    /// `.r16Uint` 1024x512, `.managed`: the software rasterizer's VRAM, shown
    /// at 15bpp in place of the render texture to A/B a suspect frame.
    shadow: mtl.Texture,
    /// An effect's first pass: the picture at the internal resolution.
    picture_pipeline: mtl.RenderPipelineState,
    /// An effect's second pass, by effect; `none` has none.
    effects: std.EnumArray(Effect, ?mtl.RenderPipelineState),
    /// Adaptive's history pictures: the woven picture at native size.
    woven_pipeline: mtl.RenderPipelineState,
    /// 1x1, bound where there is no reference picture.
    no_reference: mtl.Texture,
    /// The picture an effect draws, kept while it keeps its size.
    picture: ?mtl.Texture = null,
    picture_size: [2]usize = .{ 0, 0 },

    pub fn init(device: mtl.Device, lib: mtl.Library) !DisplayPass {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pipeline = try buildPipeline(device, lib, "display_fragment");
        errdefer pipeline.release();
        const picture_pipeline = try buildPipeline(device, lib, "picture_fragment");
        errdefer picture_pipeline.release();
        const woven_pipeline = try buildPipeline(device, lib, "woven_fragment");
        errdefer woven_pipeline.release();

        var effects = std.EnumArray(Effect, ?mtl.RenderPipelineState).initFill(null);
        errdefer for (&effects.values) |e| if (e) |pl| pl.release();
        for (std.enums.values(Effect)) |fx| {
            const name = fx.fragmentName() orelse continue;
            effects.set(fx, try buildPipeline(device, lib, name));
        }

        const shadow = try device.newTexture2D(.{
            .format = .r16Uint,
            .width = native_width,
            .height = native_height,
            .storage = .managed,
            .usage = .{ .shaderRead = true },
        });
        errdefer shadow.release();
        const no_reference = try device.newTexture2D(.{
            .format = .bgra8Unorm,
            .width = 1,
            .height = 1,
            .storage = .private,
            .usage = .{ .shaderRead = true },
        });
        return .{
            .pipeline = pipeline,
            .shadow = shadow,
            .picture_pipeline = picture_pipeline,
            .woven_pipeline = woven_pipeline,
            .no_reference = no_reference,
            .effects = effects,
        };
    }

    /// `display_vertex` and the named fragment, into a BGRA target.
    fn buildPipeline(device: mtl.Device, lib: mtl.Library, fragment_name: [:0]const u8) !mtl.RenderPipelineState {
        const vertex = lib.newFunction("display_vertex") orelse return error.MissingFunction;
        defer vertex.release();
        const fragment = lib.newFunction(fragment_name) orelse return error.MissingFunction;
        defer fragment.release();
        const desc = mtl.RenderPipelineDescriptor.new();
        defer desc.release();
        desc.setVertexFunction(vertex);
        desc.setFragmentFunction(fragment);
        desc.colorAttachment(0).setPixelFormat(.bgra8Unorm);
        return device.newRenderPipelineState(desc);
    }

    pub fn deinit(self: *DisplayPass) void {
        self.dropPicture();
        for (self.effects.values) |e| if (e) |pl| pl.release();
        self.no_reference.release();
        self.woven_pipeline.release();
        self.picture_pipeline.release();
        self.shadow.release();
        self.pipeline.release();
        self.* = undefined;
    }

    /// Only the software seam READS the shadow, so only it pays this 1 MB
    /// upload.
    pub fn uploadShadow(self: *DisplayPass, pixels: *const [native_pixels]u16) void {
        self.shadow.replaceRegion(.{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{ .width = native_width, .height = native_height, .depth = 1 },
        }, std.mem.asBytes(pixels), native_width * @sizeOf(u16));
    }

    /// The picture texture at exactly `w` x `h`, reallocated only when the
    /// size changes. False where Metal refused it.
    pub fn ensurePicture(self: *DisplayPass, device: mtl.Device, w: usize, h: usize) bool {
        if (self.picture != null and self.picture_size[0] == w and self.picture_size[1] == h) return true;
        self.dropPicture();
        self.picture = device.newTexture2D(.{
            .format = .bgra8Unorm,
            .width = w,
            .height = h,
            .storage = .private,
            .usage = .{ .renderTarget = true, .shaderRead = true },
        }) catch return false;
        self.picture_size = .{ w, h };
        return true;
    }

    /// Frees the picture texture: a setting that turns the effect off holds
    /// no memory for it.
    pub fn dropPicture(self: *DisplayPass) void {
        if (self.picture) |t| t.release();
        self.picture = null;
        self.picture_size = .{ 0, 0 };
    }

    /// Binds all four textures always, then draws one triangle into `target`.
    ///
    /// ALL FOUR bindings, always: an unbound texture2d is a Metal validation
    /// failure, not a black pixel. The target is cleared to opaque black
    /// first, which is what the letterbox bars and a disabled display show.
    ///
    /// False where Metal handed back no encoder: that frame is skipped, as
    /// the Swift view skipped it, and nothing was encoded into `cmd`.
    pub fn encode(self: *DisplayPass, cmd: mtl.CommandBuffer, target: mtl.Texture, src: Source, p: Params) bool {
        return self.drawPicture(cmd, target, .clear, self.pipeline, src, p);
    }

    /// `encode` with `fx` over the picture: two passes, the picture at the
    /// internal resolution first and then the effect's fragment over it, into
    /// `target` with the letterbox and the band. The first pass is the plain
    /// display's own `display_color`, with nothing over it, so the effect only
    /// ever sees the finished picture. `.none`, a display that is off, a
    /// picture that cannot be allocated: all fall back to `encode`.
    pub fn encodeEffect(self: *DisplayPass, cmd: mtl.CommandBuffer, target: mtl.Texture, src: Source, p: Params, e: EffectParams, fx: Effect) bool {
        const pipeline = self.effects.get(fx) orelse return self.encode(cmd, target, src, p);
        if (p.enabled == 0 or p.width == 0 or p.height == 0) return self.encode(cmd, target, src, p);
        if (!self.ensurePicture(cmd.device(), p.width * p.scale, p.height * p.scale)) return self.encode(cmd, target, src, p);
        const picture = self.picture.?;
        if (!self.drawPicture(cmd, picture, .dontCare, self.picture_pipeline, src, bare(p))) return false;

        const pool = objc.Pool.push();
        defer pool.pop();
        const enc = cmd.renderCommandEncoder(passInto(target, .clear)) orelse return false;
        enc.setRenderPipelineState(pipeline);
        enc.setFragmentTexture(picture, 0);
        enc.setVertexBytes(std.mem.asBytes(&p), 0);
        enc.setFragmentBytes(std.mem.asBytes(&p), 0);
        enc.setFragmentBytes(std.mem.asBytes(&e), 1);
        enc.drawPrimitives(.triangle, 0, 3, 1, 0);
        enc.endEncoding();
        return true;
    }

    /// The woven picture, one texel per native pixel at its top-left
    /// subtexel, into `target` (`p.width` x `p.height`): what Adaptive keeps
    /// of a picture to judge the next ones' motion against.
    pub fn encodeWoven(self: *DisplayPass, cmd: mtl.CommandBuffer, target: mtl.Texture, src: Source, p: Params) bool {
        var q = bare(p);
        q.deint = 0;
        q.has_reference = 0;
        var woven = src;
        woven.reference = null;
        return self.drawPicture(cmd, target, .dontCare, self.woven_pipeline, woven, q);
    }

    /// `p` without anything drawn over the picture: no letterbox, grey-out
    /// or band.
    fn bare(p: Params) Params {
        var q = p;
        q.scale_x = 1;
        q.scale_y = 1;
        q.saturation = 1;
        q.band_mix = 0;
        return q;
    }

    fn passInto(target: mtl.Texture, load: mtl_enums.LoadAction) mtl.RenderPassDescriptor {
        const pass = mtl.RenderPassDescriptor.renderPassDescriptor();
        const colour = pass.colorAttachment(0);
        colour.setTexture(target);
        colour.setLoadAction(load);
        colour.setClearColor(.{ .red = 0, .green = 0, .blue = 0, .alpha = 1 });
        colour.setStoreAction(.store);
        return pass;
    }

    fn drawPicture(self: *DisplayPass, cmd: mtl.CommandBuffer, target: mtl.Texture, load: mtl_enums.LoadAction, pipeline: mtl.RenderPipelineState, src: Source, p: Params) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const enc = cmd.renderCommandEncoder(passInto(target, load)) orelse return false;
        enc.setRenderPipelineState(pipeline);
        enc.setFragmentTexture(src.vram, 0);
        enc.setFragmentTexture(self.shadow, 1);
        enc.setFragmentTexture(src.sidecar, 2);
        enc.setFragmentTexture(src.reference orelse self.no_reference, 3);
        enc.setVertexBytes(std.mem.asBytes(&p), 0);
        enc.setFragmentBytes(std.mem.asBytes(&p), 0);
        enc.drawPrimitives(.triangle, 0, 3, 1, 0);
        enc.endEncoding();
        return true;
    }
};
