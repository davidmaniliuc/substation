//! The display pass: the picture the window shows, drawn from the render
//! texture, the 1x shadow or the true-colour sidecar into a BGRA target,
//! letterboxed to 4:3. Plus the pure pieces the draw loop feeds it: the
//! letterbox scale, the pause grey-out and the toolbar band.

const std = @import("std");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const pi = @import("prim_instance.zig");

const assert = std.debug.assert;
const native_width = pi.native_width;
const native_height = pi.native_height;
pub const native_pixels = pi.native_pixels;

/// Mirrors `Params` in Shaders/DisplayShader.metal. Field order and types
/// must match exactly.
///
/// Both sides are 4-byte aligned throughout, so this is 68 bytes with no
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
};

comptime {
    assert(@sizeOf(Params) == 68);
}

/// Multipliers that fit a 4:3 picture inside a drawable of `width` x `height`.
///
/// The PS1 output is 4:3 whatever the pixel resolution is, so aspect
/// correction is a property of the display, not of the framebuffer's
/// `width/height`.
///
/// Exactly `(1, 1)` when the drawable is already 4:3, and SNAPPED there
/// rather than computed: the window is aspect-locked so the ratio lands a
/// hair off 1.0, and a scale of 0.99999 blacks out the outermost pixel column
/// for nothing. A zero-sized drawable also returns `(1, 1)`: the shader
/// divides by these, so 0 would hand it a NaN uv.
pub fn letterboxScale(width: f64, height: f64) struct { x: f32, y: f32 } {
    if (!(width > 0 and height > 0)) return .{ .x = 1, .y = 1 };
    const target = 4.0 / 3.0;
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

/// The display pipeline and the 1x shadow it reads 24bpp (and the
/// `PS1_SOFTWARE_DISPLAY` seam) from.
pub const DisplayPass = struct {
    pipeline: mtl.RenderPipelineState,
    /// `.r16Uint` 1024x512, `.managed`: 24bpp scans out of the 1x shadow
    /// permanently, because it byte-packs across adjacent 16-bit words and
    /// that arithmetic cannot survive N x N replication.
    shadow: mtl.Texture,

    pub fn init(device: mtl.Device, lib: mtl.Library) !DisplayPass {
        const pool = objc.Pool.push();
        defer pool.pop();
        const vertex = lib.newFunction("display_vertex") orelse return error.MissingFunction;
        defer vertex.release();
        const fragment = lib.newFunction("display_fragment") orelse return error.MissingFunction;
        defer fragment.release();
        const desc = mtl.RenderPipelineDescriptor.new();
        defer desc.release();
        desc.setVertexFunction(vertex);
        desc.setFragmentFunction(fragment);
        desc.colorAttachment(0).setPixelFormat(.bgra8Unorm);
        const pipeline = try device.newRenderPipelineState(desc);
        errdefer pipeline.release();

        const shadow = try device.newTexture2D(.{
            .format = .r16Uint,
            .width = native_width,
            .height = native_height,
            .storage = .managed,
            .usage = .{ .shaderRead = true },
        });
        return .{ .pipeline = pipeline, .shadow = shadow };
    }

    pub fn deinit(self: *DisplayPass) void {
        self.shadow.release();
        self.pipeline.release();
        self.* = undefined;
    }

    /// Only the two paths that READ the shadow (24bpp and the software
    /// seam) need to pay this 1 MB upload.
    pub fn uploadShadow(self: *DisplayPass, pixels: *const [native_pixels]u16) void {
        self.shadow.replaceRegion(.{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{ .width = native_width, .height = native_height, .depth = 1 },
        }, std.mem.asBytes(pixels), native_width * @sizeOf(u16));
    }

    /// Binds all three textures always, then draws one triangle into `target`.
    ///
    /// ALL THREE bindings, always: an unbound texture2d is a Metal validation
    /// failure, not a black pixel. The target is cleared to opaque black
    /// first, which is what the letterbox bars and a disabled display show.
    ///
    /// False where Metal handed back no encoder: that frame is skipped, as
    /// the Swift view skipped it, and nothing was encoded into `cmd`.
    pub fn encode(self: *DisplayPass, cmd: mtl.CommandBuffer, target: mtl.Texture, vram: mtl.Texture, sidecar: mtl.Texture, p: Params) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pass = mtl.RenderPassDescriptor.renderPassDescriptor();
        const colour = pass.colorAttachment(0);
        colour.setTexture(target);
        colour.setLoadAction(.clear);
        colour.setClearColor(.{ .red = 0, .green = 0, .blue = 0, .alpha = 1 });
        colour.setStoreAction(.store);
        const enc = cmd.renderCommandEncoder(pass) orelse return false;
        enc.setRenderPipelineState(self.pipeline);
        enc.setFragmentTexture(vram, 0);
        enc.setFragmentTexture(self.shadow, 1);
        enc.setFragmentTexture(sidecar, 2);
        enc.setVertexBytes(std.mem.asBytes(&p), 0);
        enc.setFragmentBytes(std.mem.asBytes(&p), 0);
        enc.drawPrimitives(.triangle, 0, 3, 1, 0);
        enc.endEncoding();
        return true;
    }
};
