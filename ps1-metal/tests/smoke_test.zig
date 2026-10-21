//! The wrapper's first contact with a real device: a render pass, a blit, a
//! completion block, and the shader library the app ships.

const std = @import("std");
const ps1_metal = @import("ps1_metal");
const harness = @import("harness.zig");

const objc = ps1_metal.objc;
const mtl = ps1_metal.mtl;
const enums = ps1_metal.mtl_enums;

const Completion = struct {
    runs: std.atomic.Value(u32) = .init(0),

    fn completed(self: *Completion, _: objc.Id) void {
        _ = self.runs.fetchAdd(1, .release);
    }
};

test "aTextureClearedByARenderPassReadsBackThroughACompletionBlock" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();

    const side = 4;
    const desc = mtl.TextureDescriptor.new();
    defer desc.release();
    desc.setPixelFormat(.r16Uint);
    desc.setWidth(side);
    desc.setHeight(side);
    desc.setStorageMode(.private);
    desc.setUsage(.{ .shaderRead = true, .renderTarget = true });
    const texture = env.device.newTexture(desc) orelse return error.NoTexture;
    defer texture.release();
    try std.testing.expectEqual(side, texture.width());
    try std.testing.expectEqual(side, texture.height());
    try std.testing.expectEqual(enums.PixelFormat.r16Uint, texture.pixelFormat());

    const bytes = side * side * @sizeOf(u16);
    const buffer = env.device.newBuffer(bytes, enums.resourceOptions(.shared)) orelse return error.NoBuffer;
    defer buffer.release();
    try std.testing.expectEqual(bytes, buffer.length());

    const cb = env.queue.commandBuffer() orelse return error.NoCommandBuffer;

    const pass = mtl.RenderPassDescriptor.renderPassDescriptor();
    const attachment = pass.colorAttachment(0);
    attachment.setTexture(texture);
    attachment.setLoadAction(.clear);
    attachment.setStoreAction(.store);
    attachment.setClearColor(.{ .red = 0x1234, .green = 0, .blue = 0, .alpha = 0 });
    const render = cb.renderCommandEncoder(pass) orelse return error.NoEncoder;
    render.endEncoding();

    const blit = cb.blitCommandEncoder() orelse return error.NoEncoder;
    blit.copyTextureToBuffer(
        texture,
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .width = side, .height = side, .depth = 1 },
        buffer,
        0,
        side * @sizeOf(u16),
        bytes,
    );
    blit.endEncoding();

    var completion: Completion = .{};
    var block = objc.Block(Completion, Completion.completed).init(&completion);
    cb.addCompletedHandler(block.ptr());
    cb.commit();
    cb.waitUntilCompleted();

    // `completion` lives on this stack frame, so the handler must have run
    // before the test returns, not merely by the time the wait does.
    try harness.awaitHandler(&completion.runs, "aTextureClearedByARenderPass");
    try std.testing.expectEqual(1, completion.runs.load(.acquire));
    const words: [*]const u16 = @ptrCast(@alignCast(buffer.contents()));
    for (words[0 .. side * side]) |w| try std.testing.expectEqual(@as(u16, 0x1234), w);
}

// A syntax error in a shader fails the build; what the build does NOT catch
// is the two display function names drifting from what the pipeline asks
// for, and the pipeline is where a vertex/fragment signature mismatch shows.
test "displayShaderCompilesAndExposesBothFunctions" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();

    const vertex = env.lib.newFunction("display_vertex") orelse return error.MissingFunction;
    defer vertex.release();
    const fragment = env.lib.newFunction("display_fragment") orelse return error.MissingFunction;
    defer fragment.release();

    const desc = mtl.RenderPipelineDescriptor.new();
    defer desc.release();
    desc.setVertexFunction(vertex);
    desc.setFragmentFunction(fragment);
    desc.colorAttachment(0).setPixelFormat(.bgra8Unorm);
    const state = try env.device.newRenderPipelineState(desc);
    state.release();
}

test "theRasterizerVertexFunctionAndFillPipelineBuild" {
    const env = try harness.metal();
    defer env.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();

    const vertex = env.lib.newFunction("ps1_vertex") orelse return error.MissingFunction;
    defer vertex.release();
    const fragment = env.lib.newFunction("ps1_fill_fragment") orelse return error.MissingFunction;
    defer fragment.release();
    // The display shader must still be in the SAME library after the merge.
    const display = env.lib.newFunction("display_vertex") orelse return error.MissingFunction;
    display.release();

    const desc = mtl.RenderPipelineDescriptor.new();
    defer desc.release();
    desc.setVertexFunction(vertex);
    desc.setFragmentFunction(fragment);
    desc.colorAttachment(0).setPixelFormat(.r16Uint);
    // ps1_fill_fragment returns Ps1FragOut, so a descriptor with only
    // attachment 0 does not build: the pipeline-side half of the "every
    // fragment writes both" rule.
    desc.colorAttachment(1).setPixelFormat(.rgba8Uint);
    const state = try env.device.newRenderPipelineState(desc);
    state.release();
}
