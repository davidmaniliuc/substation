//! The Metal enum values the renderer uses.
//!
//! Every value is copied from the SDK header named beside it
//! (`$(xcrun --show-sdk-path)/System/Library/Frameworks/Metal.framework/Headers/`),
//! with the line it was read from. translate-c cannot read those headers
//! (they `#import` Foundation and declare through NS_ENUM), so the comments
//! are the check, and `test-metal-validate` is the net for a wrong one.
//! Each enum is NSUInteger-backed, as the header declares it.

pub const PixelFormat = enum(usize) {
    r16Uint = 23, // MTLPixelFormat.h:30: MTLPixelFormatR16Uint = 23
    r32Uint = 53, // MTLPixelFormat.h:87: MTLPixelFormatR32Uint = 53
    rgba8Uint = 73, // MTLPixelFormat.h:100: MTLPixelFormatRGBA8Uint = 73
    bgra8Unorm = 80, // MTLPixelFormat.h:103: MTLPixelFormatBGRA8Unorm = 80
    _,
};

pub const StorageMode = enum(usize) {
    shared = 0, // MTLResource.h:84: MTLStorageModeShared = 0
    managed = 1, // MTLResource.h:85: MTLStorageModeManaged = 1
    private = 2, // MTLResource.h:86: MTLStorageModePrivate = 2
    memoryless = 3, // MTLResource.h:87: MTLStorageModeMemoryless = 3
};

/// MTLTextureUsage, an NS_OPTIONS bit set.
pub const TextureUsage = packed struct(usize) {
    shaderRead: bool = false, // MTLTexture.h:100: MTLTextureUsageShaderRead = 0x0001
    shaderWrite: bool = false, // MTLTexture.h:101: MTLTextureUsageShaderWrite = 0x0002
    renderTarget: bool = false, // MTLTexture.h:102: MTLTextureUsageRenderTarget = 0x0004
    _: u61 = 0,
};

pub const LoadAction = enum(usize) {
    dontCare = 0, // MTLRenderPass.h:33: MTLLoadActionDontCare = 0
    load = 1, // MTLRenderPass.h:34: MTLLoadActionLoad = 1
    clear = 2, // MTLRenderPass.h:35: MTLLoadActionClear = 2
};

pub const StoreAction = enum(usize) {
    dontCare = 0, // MTLRenderPass.h:39: MTLStoreActionDontCare = 0
    store = 1, // MTLRenderPass.h:40: MTLStoreActionStore = 1
};

pub const PrimitiveType = enum(usize) {
    triangle = 3, // MTLRenderCommandEncoder.h:34: MTLPrimitiveTypeTriangle = 3
    triangleStrip = 4, // MTLRenderCommandEncoder.h:35: MTLPrimitiveTypeTriangleStrip = 4
};

pub const CommandBufferStatus = enum(usize) {
    notEnqueued = 0, // MTLCommandBuffer.h:57: MTLCommandBufferStatusNotEnqueued = 0
    enqueued = 1, // MTLCommandBuffer.h:58: MTLCommandBufferStatusEnqueued = 1
    committed = 2, // MTLCommandBuffer.h:59: MTLCommandBufferStatusCommitted = 2
    scheduled = 3, // MTLCommandBuffer.h:60: MTLCommandBufferStatusScheduled = 3
    completed = 4, // MTLCommandBuffer.h:61: MTLCommandBufferStatusCompleted = 4
    @"error" = 5, // MTLCommandBuffer.h:62: MTLCommandBufferStatusError = 5
    _,
};

pub const DataType = enum(usize) {
    int = 29, // MTLDataType.h:87: MTLDataTypeInt = 29
    bool = 53, // MTLDataType.h:141: MTLDataTypeBool = 53
};

// MTLResource.h:165: #define MTLResourceStorageModeShift 4
const resource_storage_mode_shift = 4;

/// MTLResourceOptions for a storage mode, with the default CPU cache mode
/// (MTLResource.h:53: MTLCPUCacheModeDefaultCache = 0).
pub fn resourceOptions(mode: StorageMode) usize {
    return @backingInt(mode) << resource_storage_mode_shift;
}
