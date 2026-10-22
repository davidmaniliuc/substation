//! TEMPORARY (Plan C Task 8 deletes it): `ps1-capi/include/ps1_lockstep.h`.
//! Replays a `.p1fx` through ps1-metal so the Swift suite can require it
//! byte-identical to the Swift renderer before that renderer is deleted.

const std = @import("std");
const capi = @import("ps1_capi");
const metal = @import("ps1_metal");

const fixture = metal.fixture;
const objc = metal.objc;
const pi = metal.prim_instance;
const Metal = metal.metal_context.Metal;
const Rig = metal.metal_context.Rig;

/// Not the testing allocator: the Swift test host links the shipped library.
const allocator = std.heap.c_allocator;

pub const Ps1LockstepConfig = extern struct {
    scale: i32,
    dither: i32,
    texture_filter: i32,
    sprite_filter: i32,
    depth_buffer: u8,
};

const Settings = struct {
    scale: u32,
    dither: pi.DitherMode,
    texture_filter: pi.TextureFilter,
    sprite_filter: pi.TextureFilter,
    depth_buffer: bool,

    fn of(cfg: *const Ps1LockstepConfig) ?Settings {
        if (cfg.scale < 1 or cfg.scale > 8) return null;
        return .{
            .scale = @intCast(cfg.scale),
            .dither = std.enums.fromInt(pi.DitherMode, cfg.dither) orelse return null,
            .texture_filter = std.enums.fromInt(pi.TextureFilter, cfg.texture_filter) orelse return null,
            .sprite_filter = std.enums.fromInt(pi.TextureFilter, cfg.sprite_filter) orelse return null,
            .depth_buffer = cfg.depth_buffer != 0,
        };
    }
};

fn metalCode(err: anyerror) i32 {
    return if (err == error.OutOfMemory) capi.PS1_ERR_OOM else capi.PS1_ERR_NO_METAL;
}

pub export fn ps1_lockstep_replay(
    bytes: [*]const u8,
    len: usize,
    cfg: *const Ps1LockstepConfig,
    up_to: u32,
    vram_hashes: [*]u64,
    sidecar_hashes: [*]u64,
    vram_out: ?[*]u16,
    sidecar_out: ?[*]u8,
) i32 {
    const s = Settings.of(cfg) orelse return capi.PS1_ERR_BAD_SLOT;
    const parsed = fixture.parse(allocator, bytes[0..len]) catch |err|
        return if (err == error.OutOfMemory) capi.PS1_ERR_OOM else capi.PS1_ERR_BAD_CUE;
    defer parsed.deinit(allocator);

    const m = Metal.open() catch |err| return metalCode(err);
    defer m.deinit();
    const rig = Rig.create(allocator, m, .{ .scale = s.scale, .depth_buffer = s.depth_buffer }) catch |err|
        return metalCode(err);
    defer rig.destroy();
    rig.r.dither_mode = s.dither;
    rig.r.texture_filter = s.texture_filter;
    rig.r.sprite_filter = s.sprite_filter;

    const pixels = rig.vram.pixelCount();
    const vram = allocator.alloc(u16, pixels) catch return capi.PS1_ERR_OOM;
    defer allocator.free(vram);
    const sidecar = allocator.alloc(u8, pixels * 4) catch return capi.PS1_ERR_OOM;
    defer allocator.free(sidecar);

    const count = @min(up_to, parsed.frames.len);
    for (0..count) |i| {
        const pool = objc.Pool.push();
        defer pool.pop();
        const stream = parsed.frameStream(i);
        rig.frame(stream.payload, stream.records);
        rig.vram.readback(vram);
        rig.vram.readbackSidecar(sidecar);
        vram_hashes[i] = fixture.fnv1a(std.mem.sliceAsBytes(vram));
        sidecar_hashes[i] = fixture.fnv1a(sidecar);
    }
    if (count == 0) {
        rig.vram.readback(vram);
        rig.vram.readbackSidecar(sidecar);
    }
    if (vram_out) |out| @memcpy(out[0..pixels], vram);
    if (sidecar_out) |out| @memcpy(out[0 .. pixels * 4], sidecar);
    return @intCast(count);
}
