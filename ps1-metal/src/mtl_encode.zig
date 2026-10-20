//! Typed wrappers over Metal's command encoding: command buffers, render
//! passes and the encoders. Same ownership rules as `mtl.zig`: a command
//! buffer, a pass descriptor from `renderPassDescriptor` and every encoder
//! are autoreleased, so they live inside an `objc.Pool`.

const objc = @import("objc.zig");
const enums = @import("mtl_enums.zig");
const mtl = @import("mtl.zig");

const msg = objc.msg;

fn wrap(comptime T: type, id: ?objc.Id) ?T {
    return .{ .id = id orelse return null };
}

pub const CommandBuffer = struct {
    id: objc.Id,

    /// A command buffer is autoreleased; one kept past its pool is retained
    /// here and released by its keeper.
    pub fn retain(self: CommandBuffer) CommandBuffer {
        return .{ .id = objc.retain(self.id) };
    }

    pub fn release(self: CommandBuffer) void {
        objc.release(self.id);
    }

    /// Borrowed from the command buffer.
    pub fn device(self: CommandBuffer) mtl.Device {
        return .{ .id = msg(objc.Id, self, "device", .{}) };
    }

    pub fn renderCommandEncoder(self: CommandBuffer, pass: RenderPassDescriptor) ?RenderCommandEncoder {
        return wrap(RenderCommandEncoder, msg(?objc.Id, self, "renderCommandEncoderWithDescriptor:", .{pass.id}));
    }

    pub fn blitCommandEncoder(self: CommandBuffer) ?BlitCommandEncoder {
        return wrap(BlitCommandEncoder, msg(?objc.Id, self, "blitCommandEncoder", .{}));
    }

    pub fn computeCommandEncoder(self: CommandBuffer) ?ComputeCommandEncoder {
        return wrap(ComputeCommandEncoder, msg(?objc.Id, self, "computeCommandEncoder", .{}));
    }

    /// `block` is an `objc.Block(Ctx, fn (*Ctx, Id) void)`'s `ptr()`; the
    /// command buffer copies it, and calls it with itself.
    pub fn addCompletedHandler(self: CommandBuffer, block: *anyopaque) void {
        msg(void, self, "addCompletedHandler:", .{block});
    }

    /// The label is copied; an autoreleased `nsString` is fine.
    pub fn setLabel(self: CommandBuffer, label: [:0]const u8) void {
        msg(void, self, "setLabel:", .{objc.nsString(label)});
    }

    pub fn commit(self: CommandBuffer) void {
        msg(void, self, "commit", .{});
    }

    pub fn waitUntilCompleted(self: CommandBuffer) void {
        msg(void, self, "waitUntilCompleted", .{});
    }
};

pub const RenderPassDescriptor = struct {
    id: objc.Id,

    /// Autoreleased.
    pub fn renderPassDescriptor() RenderPassDescriptor {
        return .{ .id = msg(objc.Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{}) };
    }

    /// Borrowed from the descriptor.
    pub fn colorAttachment(self: RenderPassDescriptor, index: usize) RenderPassColorAttachment {
        const array = msg(objc.Id, self, "colorAttachments", .{});
        return .{ .id = msg(objc.Id, array, "objectAtIndexedSubscript:", .{index}) };
    }
};

pub const RenderPassColorAttachment = struct {
    id: objc.Id,

    pub fn setTexture(self: RenderPassColorAttachment, texture: mtl.Texture) void {
        msg(void, self, "setTexture:", .{texture.id});
    }

    pub fn setLoadAction(self: RenderPassColorAttachment, action: enums.LoadAction) void {
        msg(void, self, "setLoadAction:", .{action});
    }

    pub fn setStoreAction(self: RenderPassColorAttachment, action: enums.StoreAction) void {
        msg(void, self, "setStoreAction:", .{action});
    }

    pub fn setClearColor(self: RenderPassColorAttachment, color: mtl.ClearColor) void {
        msg(void, self, "setClearColor:", .{color});
    }
};

pub const RenderCommandEncoder = struct {
    id: objc.Id,

    pub fn setRenderPipelineState(self: RenderCommandEncoder, state: mtl.RenderPipelineState) void {
        msg(void, self, "setRenderPipelineState:", .{state.id});
    }

    pub fn setVertexBuffer(self: RenderCommandEncoder, buffer: mtl.Buffer, offset: usize, index: usize) void {
        msg(void, self, "setVertexBuffer:offset:atIndex:", .{ buffer.id, offset, index });
    }

    pub fn setFragmentBuffer(self: RenderCommandEncoder, buffer: mtl.Buffer, offset: usize, index: usize) void {
        msg(void, self, "setFragmentBuffer:offset:atIndex:", .{ buffer.id, offset, index });
    }

    /// The bytes are copied into the command stream.
    pub fn setVertexBytes(self: RenderCommandEncoder, bytes: []const u8, index: usize) void {
        msg(void, self, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, bytes.ptr), bytes.len, index });
    }

    /// The bytes are copied into the command stream.
    pub fn setFragmentBytes(self: RenderCommandEncoder, bytes: []const u8, index: usize) void {
        msg(void, self, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, bytes.ptr), bytes.len, index });
    }

    pub fn setFragmentTexture(self: RenderCommandEncoder, texture: mtl.Texture, index: usize) void {
        msg(void, self, "setFragmentTexture:atIndex:", .{ texture.id, index });
    }

    pub fn drawPrimitives(
        self: RenderCommandEncoder,
        primitive: enums.PrimitiveType,
        vertex_start: usize,
        vertex_count: usize,
        instance_count: usize,
        base_instance: usize,
    ) void {
        msg(void, self, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{
            primitive, vertex_start, vertex_count, instance_count, base_instance,
        });
    }

    pub fn endEncoding(self: RenderCommandEncoder) void {
        msg(void, self, "endEncoding", .{});
    }
};

pub const BlitCommandEncoder = struct {
    id: objc.Id,

    /// Slice 0, mip level 0.
    pub fn copyTextureToBuffer(
        self: BlitCommandEncoder,
        texture: mtl.Texture,
        origin: mtl.Origin,
        size: mtl.Size,
        buffer: mtl.Buffer,
        offset: usize,
        bytes_per_row: usize,
        bytes_per_image: usize,
    ) void {
        msg(void, self, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
            texture.id, @as(usize, 0), @as(usize, 0), origin, size, buffer.id, offset, bytes_per_row, bytes_per_image,
        });
    }

    /// Slice 0, mip level 0.
    pub fn copyBufferToTexture(
        self: BlitCommandEncoder,
        buffer: mtl.Buffer,
        offset: usize,
        bytes_per_row: usize,
        bytes_per_image: usize,
        size: mtl.Size,
        texture: mtl.Texture,
        origin: mtl.Origin,
    ) void {
        msg(void, self, "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
            buffer.id, offset, bytes_per_row, bytes_per_image, size, texture.id, @as(usize, 0), @as(usize, 0), origin,
        });
    }

    /// Slice 0, mip level 0, on both sides.
    pub fn copyTextureToTexture(
        self: BlitCommandEncoder,
        source: mtl.Texture,
        source_origin: mtl.Origin,
        size: mtl.Size,
        destination: mtl.Texture,
        destination_origin: mtl.Origin,
    ) void {
        msg(void, self, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
            source.id,      @as(usize, 0), @as(usize, 0), source_origin,      size,
            destination.id, @as(usize, 0), @as(usize, 0), destination_origin,
        });
    }

    /// Makes the GPU's writes to a `.managed` texture visible to the CPU
    /// once the command buffer completes.
    pub fn synchronizeResource(self: BlitCommandEncoder, texture: mtl.Texture) void {
        msg(void, self, "synchronizeResource:", .{texture.id});
    }

    pub fn endEncoding(self: BlitCommandEncoder) void {
        msg(void, self, "endEncoding", .{});
    }
};

/// Compute exists for one kernel, the interpolation fuzz; the renderer
/// itself never dispatches.
pub const ComputeCommandEncoder = struct {
    id: objc.Id,

    pub fn setComputePipelineState(self: ComputeCommandEncoder, state: mtl.ComputePipelineState) void {
        msg(void, self, "setComputePipelineState:", .{state.id});
    }

    pub fn setBuffer(self: ComputeCommandEncoder, buffer: mtl.Buffer, offset: usize, index: usize) void {
        msg(void, self, "setBuffer:offset:atIndex:", .{ buffer.id, offset, index });
    }

    /// The bytes are copied into the command stream.
    pub fn setBytes(self: ComputeCommandEncoder, bytes: []const u8, index: usize) void {
        msg(void, self, "setBytes:length:atIndex:", .{ @as(*const anyopaque, bytes.ptr), bytes.len, index });
    }

    pub fn dispatchThreads(self: ComputeCommandEncoder, threads: mtl.Size, per_group: mtl.Size) void {
        msg(void, self, "dispatchThreads:threadsPerThreadgroup:", .{ threads, per_group });
    }

    pub fn endEncoding(self: ComputeCommandEncoder) void {
        msg(void, self, "endEncoding", .{});
    }
};
