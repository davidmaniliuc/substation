//! Every pipeline the rasterizer draws with, built once in `init` so the
//! first use of a variant mid-game is not a compile hitch.
//!
//! Primitives draw through 28 pipelines: seven `PS1_PRIM_*` classes times
//! whether the destination is read (`PrimVariant`) times true colour on or
//! off, which picks the table. The four memory movers carry no constants.

const std = @import("std");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const enums = @import("mtl_enums.zig");
const pi = @import("prim_instance.zig");

/// Which specialised pipeline a primitive draws with. True colour is NOT
/// here: it is one per-frame setting, so it selects the pipeline TABLE.
pub const PrimVariant = struct {
    /// The `PS1_PRIM_*` class, 0 (flat triangle) to 6 (shaded line pixel).
    kind: i32,
    /// Whether the draw's output depends on the destination pixel: blended,
    /// mask-checked, depth-tested, or the depth plane persisting (the shader
    /// writes the stored depth back where it does not write its own).
    reads_dst: bool,
};

const class_count = pi.Kind.shaded_line_pixel - pi.Kind.flat_tri + 1;

// Rasterizer.metal's PS1_FC_CLASS and PS1_FC_TRUE_COLOR.
const fc_class = 1;
const fc_true_colour = 2;

pub const Set = struct {
    /// [true colour][class][reads dst].
    prims: [2][class_count][2]mtl.RenderPipelineState,
    fill: mtl.RenderPipelineState,
    upload: mtl.RenderPipelineState,
    copy: mtl.RenderPipelineState,
    depth_clear: mtl.RenderPipelineState,

    /// Needs an enclosing pool: function names cross as autoreleased strings.
    pub fn init(device: mtl.Device, lib: mtl.Library) !Set {
        const vertex = lib.newFunction("ps1_vertex") orelse return missing("ps1_vertex");
        defer vertex.release();

        // Everything built so far, released if a later one fails.
        var built: Built = .{};
        errdefer built.releaseAll();

        var self: Set = undefined;
        self.fill = built.keep(try plain(device, lib, vertex, "ps1_fill_fragment"));
        self.upload = built.keep(try plain(device, lib, vertex, "ps1_upload_fragment"));
        self.copy = built.keep(try plain(device, lib, vertex, "ps1_copy_fragment"));
        self.depth_clear = built.keep(try plain(device, lib, vertex, "ps1_depth_clear_fragment"));
        for (0..2) |tc| {
            for (0..class_count) |class| {
                for (0..2) |dst| {
                    const name: [:0]const u8 = if (dst == 1) "ps1_prim_fragment_dst" else "ps1_prim_fragment_nodst";
                    self.prims[tc][class][dst] = built.keep(try specialised(device, lib, vertex, name, @intCast(class), tc == 1));
                }
            }
        }
        return self;
    }

    pub fn deinit(self: *Set) void {
        for (&self.prims) |*table| for (table) |*pair| for (pair) |p| p.release();
        self.fill.release();
        self.upload.release();
        self.copy.release();
        self.depth_clear.release();
        self.* = undefined;
    }

    pub fn prim(self: *const Set, true_colour: bool, v: PrimVariant) mtl.RenderPipelineState {
        return self.prims[@intFromBool(true_colour)][@intCast(v.kind)][@intFromBool(v.reads_dst)];
    }

    pub fn variantCount(self: *const Set) usize {
        _ = self;
        return 2 * class_count * 2;
    }
};

const Built = struct {
    items: [4 + 2 * class_count * 2]mtl.RenderPipelineState = undefined,
    len: usize = 0,

    fn keep(self: *Built, p: mtl.RenderPipelineState) mtl.RenderPipelineState {
        self.items[self.len] = p;
        self.len += 1;
        return p;
    }

    fn releaseAll(self: *Built) void {
        for (self.items[0..self.len]) |p| p.release();
    }
};

fn missing(name: []const u8) error{MissingFunction} {
    std.log.err("the shader library has no function {s}", .{name});
    return error.MissingFunction;
}

fn plain(device: mtl.Device, lib: mtl.Library, vertex: mtl.Function, fragment: [:0]const u8) !mtl.RenderPipelineState {
    const f = lib.newFunction(fragment) orelse return missing(fragment);
    defer f.release();
    return pipeline(device, vertex, f);
}

fn specialised(device: mtl.Device, lib: mtl.Library, vertex: mtl.Function, fragment: [:0]const u8, class: i32, true_colour: bool) !mtl.RenderPipelineState {
    const values = mtl.FunctionConstantValues.new();
    defer values.release();
    values.setConstantValue(&class, .int, fc_class);
    values.setConstantValue(&true_colour, .bool, fc_true_colour);
    const f = try lib.newFunctionWithConstants(fragment, values);
    defer f.release();
    return pipeline(device, vertex, f);
}

fn pipeline(device: mtl.Device, vertex: mtl.Function, fragment: mtl.Function) !mtl.RenderPipelineState {
    const desc = mtl.RenderPipelineDescriptor.new();
    defer desc.release();
    desc.setVertexFunction(vertex);
    desc.setFragmentFunction(fragment);
    // Every rasterizer pipeline declares the same three colour formats
    // unconditionally, so every pass shares one attachment set and no
    // fragment function's [[color(1)]]/[[color(2)]] output ever finds nothing
    // behind it.
    desc.colorAttachment(0).setPixelFormat(.r16Uint);
    desc.colorAttachment(1).setPixelFormat(.rgba8Uint);
    desc.colorAttachment(2).setPixelFormat(.r32Uint);
    return device.newRenderPipelineState(desc);
}
