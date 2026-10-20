//! The per-primitive instance record and the per-draw uniforms, as the
//! shaders declare them.
//!
//! Neither struct is declared here: `PrimInstance.h` is the one declaration,
//! read by the Metal compiler and, through translate-c, by this module, so
//! the two cannot drift. What is written out here is the half the header
//! cannot say: the sizes the shader's `static_assert`s pin, and the names a
//! Zig caller wants for its constants.

const std = @import("std");
const c = @import("prim_instance_c");

/// 54 four-byte fields; see the header for what each one carries.
pub const PrimInstance = c.Ps1PrimInstance;

/// Per-DRAW state, bound at buffer index 2 for both stages.
pub const Uniforms = c.Ps1RasterUniforms;

/// `PS1_PRIM_*`: the value of `PrimInstance.kind`.
pub const Kind = struct {
    pub const flat_tri: i32 = c.PS1_PRIM_FLAT_TRI;
    pub const gouraud_tri: i32 = c.PS1_PRIM_GOURAUD_TRI;
    pub const textured_tri: i32 = c.PS1_PRIM_TEXTURED_TRI;
    pub const rect: i32 = c.PS1_PRIM_RECT;
    pub const textured_rect: i32 = c.PS1_PRIM_TEXTURED_RECT;
    pub const line_pixel: i32 = c.PS1_PRIM_LINE_PIXEL;
    pub const shaded_line_pixel: i32 = c.PS1_PRIM_SHADED_LINE_PIXEL;
    pub const fill: i32 = c.PS1_PRIM_FILL;
    pub const upload: i32 = c.PS1_PRIM_UPLOAD;
    pub const copy: i32 = c.PS1_PRIM_COPY;
    pub const depth_clear: i32 = c.PS1_PRIM_DEPTH_CLEAR;
};

/// `PS1_PRIM_*` bits of `PrimInstance.flags`.
pub const Flag = struct {
    pub const transparent: u32 = c.PS1_PRIM_TRANSPARENT;
    pub const dither: u32 = c.PS1_PRIM_DITHER;
    pub const modulate: u32 = c.PS1_PRIM_MODULATE;
    pub const set_mask: u32 = c.PS1_PRIM_SET_MASK;
    pub const check_mask: u32 = c.PS1_PRIM_CHECK_MASK;
    pub const texture_perspective: u32 = c.PS1_PRIM_TEXTURE_PERSPECTIVE;
    pub const color_perspective: u32 = c.PS1_PRIM_COLOR_PERSPECTIVE;
    pub const depth_test: u32 = c.PS1_PRIM_DEPTH_TEST;
    pub const depth_write: u32 = c.PS1_PRIM_DEPTH_WRITE;
};

/// Where the 4x4 dither pattern is sampled; `.true_color` turns dithering off
/// and writes the eight-bit value to the display sidecar.
pub const DitherMode = enum(u32) {
    off = c.PS1_DITHER_OFF,
    native = c.PS1_DITHER_NATIVE,
    scaled = c.PS1_DITHER_SCALED,
    true_color = c.PS1_DITHER_TRUE_COLOR,
};

pub const TextureFilter = enum(u32) {
    nearest = c.PS1_FILTER_NEAREST,
    bilinear = c.PS1_FILTER_BILINEAR,
};

/// The shipped dither setting (`DitherSetting.defaultMode`).
pub const default_dither: DitherMode = .true_color;

/// PS1 VRAM's own dimensions. Every instance field, every `VramRect`, every
/// `.vram` dump and every fixture hash is in THESE units at every internal
/// resolution: nothing that clamps a record may use the scaled ones.
pub const native_width = 1024;
pub const native_height = 512;
pub const native_pixels = native_width * native_height;

/// An inclusive rectangle in native VRAM pixels.
pub const VramRect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn intersects(a: VramRect, b: VramRect) bool {
        return a.x0 <= b.x1 and b.x0 <= a.x1 and a.y0 <= b.y1 and b.y0 <= a.y1;
    }

    pub fn unionWith(a: VramRect, b: VramRect) VramRect {
        return .{
            .x0 = @min(a.x0, b.x0),
            .y0 = @min(a.y0, b.y0),
            .x1 = @max(a.x1, b.x1),
            .y1 = @max(a.y1, b.y1),
        };
    }
};

// The other half of Rasterizer.metal's static_asserts: a field added on one
// side only shears every instance in the buffer.
comptime {
    std.debug.assert(@sizeOf(PrimInstance) == 4 * 54);
    std.debug.assert(@alignOf(PrimInstance) == 4);
    std.debug.assert(@sizeOf(Uniforms) == 16);
    std.debug.assert(@offsetOf(PrimInstance, "kind") == 0);
    std.debug.assert(@offsetOf(PrimInstance, "qx0") == 4 * 11);
    std.debug.assert(@offsetOf(PrimInstance, "rw0") == 4 * 48);
    std.debug.assert(@offsetOf(PrimInstance, "iz2") == 4 * 53);
}
