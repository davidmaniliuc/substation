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

    pub fn renderCommandEncoder(self: CommandBuffer, pass: RenderPassDescriptor) ?RenderCommandEncoder {
        return wrap(RenderCommandEncoder, msg(?objc.Id, self, "renderCommandEncoderWithDescriptor:", .{pass.id}));
    }

    pub fn blitCommandEncoder(self: CommandBuffer) ?BlitCommandEncoder {
        return wrap(BlitCommandEncoder, msg(?objc.Id, self, "blitCommandEncoder", .{}));
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

    pub fn endEncoding(self: BlitCommandEncoder) void {
        msg(void, self, "endEncoding", .{});
    }
};
