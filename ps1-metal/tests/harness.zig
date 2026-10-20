//! What every Metal test shares: a device, its queue and the shader library,
//! or a skip where there is no GPU to run on.

const std = @import("std");
const ps1_metal = @import("ps1_metal");

const mtl = ps1_metal.mtl;

pub const Metal = struct {
    device: mtl.Device,
    queue: mtl.CommandQueue,
    lib: mtl.Library,

    pub fn deinit(self: Metal) void {
        self.lib.release();
        self.queue.release();
        self.device.release();
    }
};

/// A headless runner has no device, and a red suite there would be noise,
/// not a signal: the test skips and says why.
pub fn metal() !Metal {
    const device = mtl.Device.createSystemDefault() orelse {
        std.debug.print("no Metal device\n", .{});
        return error.SkipZigTest;
    };
    errdefer device.release();
    const queue = device.newCommandQueue() orelse return error.NoCommandQueue;
    errdefer queue.release();
    const lib = try ps1_metal.shaders.makeLibrary(device);
    return .{ .device = device, .queue = queue, .lib = lib };
}
