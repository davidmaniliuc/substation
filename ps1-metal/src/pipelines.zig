//! Every pipeline the rasterizer draws with, built once in `init` so the
//! first use of a variant mid-game is not a compile hitch.
//!
//! Primitives draw through 28 pipelines: seven `PS1_PRIM_*` classes times
//! whether the destination is read (`PrimVariant`) times true colour on or
//! off, which picks the table. The four memory movers carry no constants, and
//! the two readback gathers are compute.
//!
//! Those 28 sample Nearest. The texture filters are function constants too
//! (compiling all twelve into every textured pipeline cost Nearest 15-75% of
//! its GPU time), so a filtered table of the two textured classes is built
//! the first time its pair of filters is drawn with, and kept: the cold
//! build is paid once per pair, when the player changes the setting.

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

// Rasterizer.metal's PS1_FC_CLASS, PS1_FC_TRUE_COLOR, PS1_FC_TEXTURE_FILTER
// and PS1_FC_SPRITE_FILTER.
const fc_class = 1;
const fc_true_colour = 2;
const fc_texture_filter = 3;
const fc_sprite_filter = 4;

const filter_count = @typeInfo(pi.TextureFilter).@"enum".field_names.len;

/// One textured class's pipelines under one pair of filters:
/// [true colour][reads dst].
const Table = [2][2]mtl.RenderPipelineState;

/// The two filter settings a textured pipeline is built for.
pub const Filters = struct {
    texture: pi.TextureFilter = .nearest,
    sprite: pi.TextureFilter = .nearest,

    /// What a class's pipeline depends on: a textured triangle follows either
    /// setting (`ps1_is_sprite` decides per primitive), a textured rectangle
    /// is always a sprite, and nothing else samples a texture.
    fn of(self: Filters, kind: i32) Filters {
        return switch (kind) {
            pi.Kind.textured_tri => self,
            pi.Kind.textured_rect => .{ .sprite = self.sprite },
            else => .{},
        };
    }

    fn nearest(self: Filters) bool {
        return self.texture == .nearest and self.sprite == .nearest;
    }
};

pub const Set = struct {
    /// [true colour][class][reads dst], every texture sampled Nearest.
    prims: [2][class_count][2]mtl.RenderPipelineState,
    /// The filtered tables, built by `useFilters`: a textured triangle's by
    /// [texture][sprite] filter, a textured rectangle's by sprite filter.
    /// The Nearest entries stay null; `prims` holds them.
    tris: [filter_count][filter_count]?Table = @splat(@splat(null)),
    rects: [filter_count]?Table = @splat(null),
    /// What `useFilters` needs to build a table later.
    device: mtl.Device,
    lib: mtl.Library,
    fill: mtl.RenderPipelineState,
    upload: mtl.RenderPipelineState,
    copy: mtl.RenderPipelineState,
    depth_clear: mtl.RenderPipelineState,
    /// A native rect of VRAM and of the depth plane, by `readbackNative`'s
    /// top-left-subtexel rule (`Readback.metal`).
    gather_colour: mtl.ComputePipelineState,
    gather_depth: mtl.ComputePipelineState,

    /// Needs an enclosing pool: function names cross as autoreleased strings.
    pub fn init(device: mtl.Device, lib: mtl.Library) !Set {
        const vertex = lib.newFunction("ps1_vertex") orelse return missing("ps1_vertex");
        defer vertex.release();

        // Everything built so far, released if a later one fails.
        var built: Built = .{};
        errdefer built.releaseAll();

        var self: Set = .{
            .prims = undefined,
            .fill = undefined,
            .upload = undefined,
            .copy = undefined,
            .depth_clear = undefined,
            .gather_colour = undefined,
            .gather_depth = undefined,
            .device = device,
            .lib = lib,
        };
        self.fill = built.keep(try plain(device, lib, vertex, "ps1_fill_fragment"));
        self.upload = built.keep(try plain(device, lib, vertex, "ps1_upload_fragment"));
        self.copy = built.keep(try plain(device, lib, vertex, "ps1_copy_fragment"));
        self.depth_clear = built.keep(try plain(device, lib, vertex, "ps1_depth_clear_fragment"));
        for (0..2) |tc| {
            for (0..class_count) |class| {
                for (0..2) |dst| {
                    const name: [:0]const u8 = if (dst == 1) "ps1_prim_fragment_dst" else "ps1_prim_fragment_nodst";
                    self.prims[tc][class][dst] = built.keep(try specialised(device, lib, vertex, name, @intCast(class), tc == 1, .{}));
                }
            }
        }
        self.gather_colour = try kernel(device, lib, "ps1_gather_colour");
        errdefer self.gather_colour.release();
        self.gather_depth = try kernel(device, lib, "ps1_gather_depth");
        return self;
    }

    pub fn deinit(self: *Set) void {
        for (&self.prims) |*table| for (table) |*pair| for (pair) |p| p.release();
        for (&self.tris) |*row| for (row) |*t| if (t.*) |*table| releaseTable(table);
        for (&self.rects) |*t| if (t.*) |*table| releaseTable(table);
        self.fill.release();
        self.upload.release();
        self.copy.release();
        self.depth_clear.release();
        self.gather_colour.release();
        self.gather_depth.release();
        self.* = undefined;
    }

    /// The pipeline for `v` under `f`, whose tables `useFilters(f)` built.
    pub fn prim(self: *const Set, true_colour: bool, v: PrimVariant, f: Filters) mtl.RenderPipelineState {
        const tc = @intFromBool(true_colour);
        const dst = @intFromBool(v.reads_dst);
        const own = f.of(v.kind);
        if (own.nearest()) return self.prims[tc][@intCast(v.kind)][dst];
        return self.slot(v.kind, own).*.?[tc][dst];
    }

    /// Builds whichever of `f`'s two filtered tables does not exist yet.
    /// A cold build compiles four large fragment functions per table, so it
    /// belongs between frames, never inside an encoder. Needs an enclosing
    /// pool, as `init` does.
    pub fn useFilters(self: *Set, f: Filters) !void {
        for ([_]i32{ pi.Kind.textured_tri, pi.Kind.textured_rect }) |kind| {
            const own = f.of(kind);
            if (own.nearest()) continue;
            const t = self.slot(kind, own);
            if (t.* == null) t.* = try self.buildTable(kind, own);
        }
    }

    fn slot(self: anytype, kind: i32, f: Filters) switch (@TypeOf(self)) {
        *Set => *?Table,
        else => *const ?Table,
    } {
        return if (kind == pi.Kind.textured_rect)
            &self.rects[@backingInt(f.sprite)]
        else
            &self.tris[@backingInt(f.texture)][@backingInt(f.sprite)];
    }

    fn buildTable(self: *Set, kind: i32, f: Filters) !Table {
        const vertex = self.lib.newFunction("ps1_vertex") orelse return missing("ps1_vertex");
        defer vertex.release();
        var built: Built = .{};
        errdefer built.releaseAll();
        var t: Table = undefined;
        for (0..2) |tc| {
            for (0..2) |dst| {
                const name: [:0]const u8 = if (dst == 1) "ps1_prim_fragment_dst" else "ps1_prim_fragment_nodst";
                t[tc][dst] = built.keep(try specialised(self.device, self.lib, vertex, name, kind, tc == 1, f));
            }
        }
        return t;
    }

    pub fn variantCount(self: *const Set) usize {
        _ = self;
        return 2 * class_count * 2;
    }
};

fn releaseTable(t: *Table) void {
    for (t) |pair| for (pair) |p| p.release();
}

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

fn kernel(device: mtl.Device, lib: mtl.Library, name: [:0]const u8) !mtl.ComputePipelineState {
    const f = lib.newFunction(name) orelse return missing(name);
    defer f.release();
    return device.newComputePipelineState(f);
}

fn specialised(device: mtl.Device, lib: mtl.Library, vertex: mtl.Function, fragment: [:0]const u8, class: i32, true_colour: bool, f: Filters) !mtl.RenderPipelineState {
    const values = mtl.FunctionConstantValues.new();
    defer values.release();
    const texture: u32 = @backingInt(f.texture);
    const sprite: u32 = @backingInt(f.sprite);
    values.setConstantValue(&class, .int, fc_class);
    values.setConstantValue(&true_colour, .bool, fc_true_colour);
    values.setConstantValue(&texture, .uint, fc_texture_filter);
    values.setConstantValue(&sprite, .uint, fc_sprite_filter);
    const function = try lib.newFunctionWithConstants(fragment, values);
    defer function.release();
    return pipeline(device, vertex, function);
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
