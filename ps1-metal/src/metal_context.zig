//! What every client of the renderer opens first: the device, its queue and
//! the shader library. And the smallest thing that draws, a `MetalVram` with
//! the rasterizer drawing into it, which the tests and the benchmark replay
//! fixtures through.

const std = @import("std");
const mtl = @import("mtl.zig");
const shaders = @import("shaders.zig");
const MetalVram = @import("metal_vram.zig").MetalVram;
const Rasterizer = @import("rasterizer.zig").Rasterizer;
const objc = @import("objc.zig");
const pipelines = @import("pipelines.zig");
const Command = @import("ps1_core").gpu.command.Command;

const Allocator = std.mem.Allocator;

pub const Metal = struct {
    device: mtl.Device,
    queue: mtl.CommandQueue,
    lib: mtl.Library,

    /// `error.NoMetalDevice` where the machine has no GPU: a caller that can
    /// go on without one (a test, which skips) tells it apart from a device
    /// that failed.
    pub fn open() !Metal {
        const device = mtl.Device.createSystemDefault() orelse return error.NoMetalDevice;
        errdefer device.release();
        const queue = device.newCommandQueue() orelse return error.NoCommandQueue;
        errdefer queue.release();
        const lib = try shaders.makeLibrary(device);
        return .{ .device = device, .queue = queue, .lib = lib };
    }

    /// Every pipeline the rasterizer draws with. Built once per `Metal` by
    /// whoever keeps it, and borrowed by every rasterizer drawn with it.
    pub fn buildPipelines(self: Metal) !pipelines.Set {
        const pool = objc.Pool.push();
        defer pool.pop();
        return pipelines.Set.init(self.device, self.lib);
    }

    pub fn deinit(self: Metal) void {
        self.lib.release();
        self.queue.release();
        self.device.release();
    }
};

/// A `MetalVram` and the rasterizer drawing into it, on the heap so the
/// rasterizer's pointer to the VRAM stays put.
pub const Rig = struct {
    alloc: Allocator,
    vram: MetalVram,
    r: Rasterizer,
    /// The set this rig built for itself when it was given none.
    own_set: ?pipelines.Set,

    /// `set` is borrowed and outlives the rig; null builds one for this rig
    /// alone, which a single fixture replay can afford and a loop of them
    /// (the benchmark) should not.
    pub const Options = struct { scale: u32 = 1, depth_buffer: bool = false, set: ?*const pipelines.Set = null };

    pub fn create(alloc: Allocator, m: Metal, o: Options) !*Rig {
        const self = try alloc.create(Rig);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.own_set = if (o.set == null) try m.buildPipelines() else null;
        errdefer if (self.own_set) |*s| s.deinit();
        self.vram = try MetalVram.init(alloc, m.device, m.queue, o.scale, o.depth_buffer);
        errdefer self.vram.deinit();
        self.r = try Rasterizer.init(alloc, &self.vram, o.set orelse &self.own_set.?);
        return self;
    }

    pub fn destroy(self: *Rig) void {
        self.r.deinit();
        self.vram.deinit();
        if (self.own_set) |*s| s.deinit();
        self.alloc.destroy(self);
    }

    /// One frame: begin, every record, end.
    pub fn frame(self: *Rig, payload: []const u32, records: []const Command) void {
        self.r.beginFrame(payload);
        for (records) |c| self.r.apply(c);
        self.r.endFrame();
    }

    /// The scaled texture, owned by the caller.
    pub fn readback(self: *Rig, alloc: Allocator) ![]u16 {
        const out = try alloc.alloc(u16, self.vram.pixelCount());
        self.vram.readback(out);
        return out;
    }

    /// The scaled sidecar, owned by the caller.
    pub fn readbackSidecar(self: *Rig, alloc: Allocator) ![]u8 {
        const out = try alloc.alloc(u8, self.vram.pixelCount() * 4);
        self.vram.readbackSidecar(out);
        return out;
    }
};
