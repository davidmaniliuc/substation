//! Typed wrappers over the Metal objects the renderer creates: the device,
//! its resources, the library and pipeline state.
//!
//! Each wrapper is `struct { id: objc.Id }`. A `new…`/`create…` result is
//! owned by the caller and released with `.release()`; anything else (a
//! command buffer, a descriptor's attachment) is autoreleased or borrowed
//! and needs an enclosing `objc.Pool`. Methods are added as the renderer
//! needs them, nothing speculatively. The command-encoding half is in
//! `mtl_encode.zig`.

const std = @import("std");
const objc = @import("objc.zig");
const enums = @import("mtl_enums.zig");
const encode = @import("mtl_encode.zig");

const msg = objc.msg;

pub const Origin = extern struct { x: usize, y: usize, z: usize };
pub const Size = extern struct { width: usize, height: usize, depth: usize };
pub const Region = extern struct { origin: Origin, size: Size };
pub const ClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };

pub const CommandBuffer = encode.CommandBuffer;
pub const RenderPassDescriptor = encode.RenderPassDescriptor;
pub const RenderPassColorAttachment = encode.RenderPassColorAttachment;
pub const RenderCommandEncoder = encode.RenderCommandEncoder;
pub const BlitCommandEncoder = encode.BlitCommandEncoder;

extern "c" fn MTLCreateSystemDefaultDevice() ?objc.Id;

/// A `new…`/`create…` result wrapped, or null where Metal returned nil.
fn owned(comptime T: type, id: ?objc.Id) ?T {
    return .{ .id = id orelse return null };
}

/// A `…:error:` call's nil result, logged with Metal's own description.
fn failed(what: []const u8, err: ?objc.Id) void {
    const description: [*:0]const u8 = if (err) |e| objc.describe(e) else "no NSError";
    std.log.err("{s}: {s}", .{ what, description });
}

pub const Device = struct {
    id: objc.Id,

    pub fn createSystemDefault() ?Device {
        return owned(Device, MTLCreateSystemDefaultDevice());
    }

    pub fn release(self: Device) void {
        objc.release(self.id);
    }

    pub fn newCommandQueue(self: Device) ?CommandQueue {
        return owned(CommandQueue, msg(?objc.Id, self, "newCommandQueue", .{}));
    }

    pub fn newTexture(self: Device, desc: TextureDescriptor) ?Texture {
        return owned(Texture, msg(?objc.Id, self, "newTextureWithDescriptor:", .{desc.id}));
    }

    pub fn newBuffer(self: Device, length: usize, options: usize) ?Buffer {
        return owned(Buffer, msg(?objc.Id, self, "newBufferWithLength:options:", .{ length, options }));
    }

    /// `data` is a `dispatch_data_t`.
    pub fn newLibraryWithData(self: Device, data: *anyopaque) !Library {
        var err: ?objc.Id = null;
        return owned(Library, msg(?objc.Id, self, "newLibraryWithData:error:", .{ data, &err })) orelse {
            failed("newLibraryWithData", err);
            return error.MetalLibrary;
        };
    }

    pub fn newRenderPipelineState(self: Device, desc: RenderPipelineDescriptor) !RenderPipelineState {
        var err: ?objc.Id = null;
        return owned(RenderPipelineState, msg(?objc.Id, self, "newRenderPipelineStateWithDescriptor:error:", .{ desc.id, &err })) orelse {
            failed("newRenderPipelineState", err);
            return error.MetalPipeline;
        };
    }
};

pub const CommandQueue = struct {
    id: objc.Id,

    pub fn release(self: CommandQueue) void {
        objc.release(self.id);
    }

    /// Autoreleased.
    pub fn commandBuffer(self: CommandQueue) ?encode.CommandBuffer {
        return owned(encode.CommandBuffer, msg(?objc.Id, self, "commandBuffer", .{}));
    }
};

pub const Buffer = struct {
    id: objc.Id,

    pub fn release(self: Buffer) void {
        objc.release(self.id);
    }

    pub fn contents(self: Buffer) *anyopaque {
        return msg(*anyopaque, self, "contents", .{});
    }

    pub fn length(self: Buffer) usize {
        return msg(usize, self, "length", .{});
    }
};

pub const Texture = struct {
    id: objc.Id,

    pub fn release(self: Texture) void {
        objc.release(self.id);
    }

    pub fn width(self: Texture) usize {
        return msg(usize, self, "width", .{});
    }

    pub fn height(self: Texture) usize {
        return msg(usize, self, "height", .{});
    }

    pub fn pixelFormat(self: Texture) enums.PixelFormat {
        return msg(enums.PixelFormat, self, "pixelFormat", .{});
    }
};

/// A 2D texture unless told otherwise, as `[MTLTextureDescriptor new]` is.
pub const TextureDescriptor = struct {
    id: objc.Id,

    pub fn new() TextureDescriptor {
        return .{ .id = msg(objc.Id, objc.class("MTLTextureDescriptor"), "new", .{}) };
    }

    pub fn release(self: TextureDescriptor) void {
        objc.release(self.id);
    }

    pub fn setPixelFormat(self: TextureDescriptor, format: enums.PixelFormat) void {
        msg(void, self, "setPixelFormat:", .{format});
    }

    pub fn setWidth(self: TextureDescriptor, w: usize) void {
        msg(void, self, "setWidth:", .{w});
    }

    pub fn setHeight(self: TextureDescriptor, h: usize) void {
        msg(void, self, "setHeight:", .{h});
    }

    pub fn setStorageMode(self: TextureDescriptor, mode: enums.StorageMode) void {
        msg(void, self, "setStorageMode:", .{mode});
    }

    pub fn setUsage(self: TextureDescriptor, usage: enums.TextureUsage) void {
        msg(void, self, "setUsage:", .{usage});
    }
};

pub const Library = struct {
    id: objc.Id,

    pub fn release(self: Library) void {
        objc.release(self.id);
    }

    /// Null for a name the library does not hold.
    pub fn newFunction(self: Library, name: [:0]const u8) ?Function {
        return owned(Function, msg(?objc.Id, self, "newFunctionWithName:", .{objc.nsString(name)}));
    }
};

pub const Function = struct {
    id: objc.Id,

    pub fn release(self: Function) void {
        objc.release(self.id);
    }
};

pub const RenderPipelineDescriptor = struct {
    id: objc.Id,

    pub fn new() RenderPipelineDescriptor {
        return .{ .id = msg(objc.Id, objc.class("MTLRenderPipelineDescriptor"), "new", .{}) };
    }

    pub fn release(self: RenderPipelineDescriptor) void {
        objc.release(self.id);
    }

    pub fn setVertexFunction(self: RenderPipelineDescriptor, f: Function) void {
        msg(void, self, "setVertexFunction:", .{f.id});
    }

    pub fn setFragmentFunction(self: RenderPipelineDescriptor, f: Function) void {
        msg(void, self, "setFragmentFunction:", .{f.id});
    }

    /// Borrowed from the descriptor.
    pub fn colorAttachment(self: RenderPipelineDescriptor, index: usize) RenderPipelineColorAttachment {
        const array = msg(objc.Id, self, "colorAttachments", .{});
        return .{ .id = msg(objc.Id, array, "objectAtIndexedSubscript:", .{index}) };
    }
};

pub const RenderPipelineColorAttachment = struct {
    id: objc.Id,

    pub fn setPixelFormat(self: RenderPipelineColorAttachment, format: enums.PixelFormat) void {
        msg(void, self, "setPixelFormat:", .{format});
    }
};

pub const RenderPipelineState = struct {
    id: objc.Id,

    pub fn release(self: RenderPipelineState) void {
        objc.release(self.id);
    }
};
