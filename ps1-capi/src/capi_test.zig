const std = @import("std");
const capi = @import("root.zig");
const ps1_core = @import("ps1_core");
const Value = ps1_core.pgxp.Value;

test "create returns a handle and destroy frees it" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    capi.ps1_destroy(h);
}

test "destroy of a handle that never got a BIOS is safe" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    capi.ps1_destroy(h);
}

test "destroy tolerates null" {
    capi.ps1_destroy(null);
}

test "load_bios rejects any length that is not 524288" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const short: [16]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, -1), capi.ps1_load_bios(h, &short, short.len));

    const good = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(good);
    @memset(good, 0xAB);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, good.ptr, good.len));
    try std.testing.expectEqual(@as(u8, 0xAB), h.cpu.bus.bios[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), h.cpu.bus.bios[524287]);
}

test "reset keeps the loaded BIOS" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const good = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(good);
    @memset(good, 0x5A);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, good.ptr, good.len));

    // Dirty some RAM, then reset.
    h.cpu.bus.ram[0x1000] = 0xFF;
    capi.ps1_reset(h);

    try std.testing.expectEqual(@as(u8, 0x5A), h.cpu.bus.bios[0]);
    try std.testing.expectEqual(@as(u8, 0), h.cpu.bus.ram[0x1000]);
}

const single_file_cue =
    \\FILE "game.bin" BINARY
    \\  TRACK 01 MODE2/2352
    \\    INDEX 01 00:00:00
    \\
;

const multi_file_cue =
    \\FILE "a.bin" BINARY
    \\  TRACK 01 MODE2/2352
    \\    INDEX 01 00:00:00
    \\FILE "b.bin" BINARY
    \\  TRACK 02 AUDIO
    \\    INDEX 01 00:00:00
    \\
;

test "load_disc rejects a multi-FILE cue that is not laid out" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(
        @as(i32, -3),
        capi.ps1_load_disc(h, &bin, bin.len, multi_file_cue.ptr, multi_file_cue.len, null, 0, null, 0),
    );
    try std.testing.expect(h.disc == null);
}

const laid_out_multi_file_cue =
    \\REM FILESIZE 235200
    \\FILE "a.bin" BINARY
    \\  TRACK 01 MODE2/2352
    \\    INDEX 01 00:00:00
    \\REM FILESIZE 117600
    \\FILE "b.bin" BINARY
    \\  TRACK 02 AUDIO
    \\    INDEX 01 00:02:00
    \\
;

test "load_disc accepts a multi-FILE cue whose images the caller concatenated" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352 * 150]u8 = @splat(0);
    try std.testing.expectEqual(
        @as(i32, 0),
        capi.ps1_load_disc(h, &bin, bin.len, laid_out_multi_file_cue.ptr, laid_out_multi_file_cue.len, null, 0, null, 0),
    );
    // Track 2 is placed past the first image, not stacked on top of it: its
    // FILE begins at LBA 100 and INDEX 01 sits 150 frames further in.
    try std.testing.expectEqual(@as(u8, 2), h.disc.?.track_count);
    try std.testing.expectEqual(@as(i32, 250), h.disc.?.tracks[1].start_lba);
}

test "load_disc rejects a cue with no FILE directive" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    const junk = "this is not a cue sheet\n";
    try std.testing.expectEqual(
        @as(i32, -2),
        capi.ps1_load_disc(h, &bin, bin.len, junk.ptr, junk.len, null, 0, null, 0),
    );
}

test "load_disc accepts a single-FILE cue and attaches the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(
        @as(i32, 0),
        capi.ps1_load_disc(h, &bin, bin.len, single_file_cue.ptr, single_file_cue.len, null, 0, null, 0),
    );
    try std.testing.expect(h.disc != null);
    try std.testing.expectEqual(@as(u8, 1), h.disc.?.track_count);
}

test "load_disc with no cue takes the raw .bin fallback" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0, null, 0));
    try std.testing.expect(h.disc != null);
    try std.testing.expectEqual(@as(u8, 1), h.disc.?.track_count);
}

test "load_disc rejects an empty image" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const empty = [_]u8{};
    try std.testing.expectEqual(@as(i32, -2), capi.ps1_load_disc(h, &empty, 0, null, 0, null, 0, null, 0));
}

test "reset re-attaches the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0, null, 0));
    capi.ps1_reset(h);
    try std.testing.expect(h.disc != null);
    try std.testing.expect(h.cpu.bus.cdrom.disc != null);
}

test "get_display reports the programmed display area, not the nominal mode size" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // GP1(05h): display start in VRAM — x=320, y=8.
    h.cpu.bus.gpu.writeGp1(0x05000000 | (8 << 10) | 320);

    var out: capi.Ps1Display = undefined;
    capi.ps1_get_display(h, &out);

    try std.testing.expectEqual(@as(u32, 320), out.vram_x);
    try std.testing.expectEqual(@as(u32, 8), out.vram_y);
    try std.testing.expectEqual(h.cpu.bus.gpu.getDisplayWidth(), out.width);
    try std.testing.expectEqual(h.cpu.bus.gpu.getDisplayHeight(), out.height);
}

test "get_display reports display-enabled and pal flags" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    var out: capi.Ps1Display = undefined;

    h.cpu.bus.gpu.disp_env.display_disabled = true;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 0), out.enabled);

    h.cpu.bus.gpu.disp_env.display_disabled = false;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 1), out.enabled);

    h.cpu.bus.gpu.is_ntsc = false;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 1), out.pal);
}

test "get_display reports 24bpp from GP1(08h) bit 4" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    var out: capi.Ps1Display = undefined;

    h.cpu.bus.gpu.disp_env.display_mode = 0;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 0), out.depth24);

    h.cpu.bus.gpu.disp_env.display_mode = 1 << 4;
    capi.ps1_get_display(h, &out);
    try std.testing.expectEqual(@as(u8, 1), out.depth24);
}

test "set_buttons passes the mask through unchanged (0 means pressed)" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_buttons(h, 0xFFFF);
    try std.testing.expectEqual(@as(u16, 0xFFFF), h.cpu.bus.sio.pad.buttons);

    capi.ps1_set_buttons(h, 0xFFF7);
    try std.testing.expectEqual(@as(u16, 0xFFF7), h.cpu.bus.sio.pad.buttons);
}

test "set_analog reaches the pad in wire order" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_set_analog(h, 0x10, 0x20, 0x30, 0x40);
    try std.testing.expectEqual([4]u8{ 0x30, 0x40, 0x10, 0x20 }, h.cpu.bus.sio.pad.sticks);
}

test "press_analog_button queues a toggle on the pad" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_press_analog_button(h);
    try std.testing.expect(h.cpu.bus.sio.pad.toggle_queued);
}

test "get_pad_status reports the mode and both motors" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    var s: capi.Ps1PadStatus = undefined;
    capi.ps1_get_pad_status(h, &s);
    try std.testing.expectEqual(capi.Ps1PadStatus{ .analog = 0, .small = 0, .large = 0 }, s);

    h.cpu.bus.sio.pad.analog = true;
    h.cpu.bus.sio.pad.motor_small = 255;
    h.cpu.bus.sio.pad.motor_large = 0x80;
    capi.ps1_get_pad_status(h, &s);
    try std.testing.expectEqual(capi.Ps1PadStatus{ .analog = 1, .small = 255, .large = 0x80 }, s);
}

test "reset powers the pad up digital with both motors stopped" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    h.cpu.bus.sio.pad.analog = true;
    h.cpu.bus.sio.pad.motor_small = 255;
    h.cpu.bus.sio.pad.motor_large = 0xFF;
    capi.ps1_reset(h);
    var s: capi.Ps1PadStatus = undefined;
    capi.ps1_get_pad_status(h, &s);
    try std.testing.expectEqual(capi.Ps1PadStatus{ .analog = 0, .small = 0, .large = 0 }, s);
}

test "copy_vram copies the whole 1024x512 framebuffer" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    h.cpu.bus.gpu.vram.data[0] = 0x7C1F;
    h.cpu.bus.gpu.vram.data[1024 * 512 - 1] = 0x03E0;

    const dst = try std.testing.allocator.alloc(u16, 1024 * 512);
    defer std.testing.allocator.free(dst);
    @memset(dst, 0);

    capi.ps1_copy_vram(h, dst.ptr);

    try std.testing.expectEqual(@as(u16, 0x7C1F), dst[0]);
    try std.testing.expectEqual(@as(u16, 0x03E0), dst[1024 * 512 - 1]);
}

test "run_frame advances the machine and lands on the vblank boundary" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bios = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(bios);
    @memset(bios, 0);
    _ = capi.ps1_load_bios(h, bios.ptr, bios.len);

    const cycles_before = h.cpu.cycles;
    capi.ps1_run_frame(h);

    // A frame ends *inside* vblank, exactly as ps1-wasm's stepFrame does: the
    // caller's next call spins straight back out of it. Landing outside would
    // mean the frame had been cut short of the boundary.
    try std.testing.expect(h.cpu.bus.gpu.is_vblank);
    try std.testing.expect(h.cpu.cycles > cycles_before);
}

test "run_frame is a no-op until a BIOS is loaded, rather than spinning forever" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const cycles_before = h.cpu.cycles;
    capi.ps1_run_frame(h);
    try std.testing.expectEqual(cycles_before, h.cpu.cycles);
}

/// Writes `pairs` stereo pairs into the SPU ring the way the SPU itself does,
/// so the drain tests exercise the real indices rather than a mock.
fn pushAudio(h: *capi.Handle, pairs: usize, first: f32) void {
    const spu = &h.cpu.bus.spu;
    var i: usize = 0;
    while (i < pairs) : (i += 1) {
        const v = first + @as(f32, @floatFromInt(i));
        spu.output_buffer[spu.write_idx] = v;
        spu.output_buffer[(spu.write_idx + 1) % spu.output_buffer.len] = -v;
        spu.write_idx = (spu.write_idx + 2) % spu.output_buffer.len;
    }
}

test "read_audio drains exactly what the SPU wrote, and no more" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    pushAudio(h, 3, 1.0);

    var dst: [16]f32 = undefined;
    const n = capi.ps1_read_audio(h, &dst, dst.len);

    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(f32, 1.0), dst[0]);
    try std.testing.expectEqual(@as(f32, -1.0), dst[1]);
    try std.testing.expectEqual(@as(f32, 3.0), dst[4]);
    try std.testing.expectEqual(@as(f32, -3.0), dst[5]);

    // Nothing left: a second drain must not re-deliver the same samples.
    try std.testing.expectEqual(@as(usize, 0), capi.ps1_read_audio(h, &dst, dst.len));
}

test "read_audio survives the ring wraparound without losing samples" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const spu = &h.cpu.bus.spu;
    const len = spu.output_buffer.len;

    // Park both indices two pairs short of the end so the next write wraps.
    spu.write_idx = len - 4;
    spu.read_idx = len - 4;

    pushAudio(h, 4, 10.0); // 8 floats: 4 before the wrap, 4 after

    var dst: [16]f32 = undefined;
    const n = capi.ps1_read_audio(h, &dst, dst.len);

    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqual(@as(f32, 10.0), dst[0]);
    try std.testing.expectEqual(@as(f32, 11.0), dst[2]);
    try std.testing.expectEqual(@as(f32, 12.0), dst[4]);
    try std.testing.expectEqual(@as(f32, 13.0), dst[6]);
    try std.testing.expectEqual(@as(f32, -13.0), dst[7]);
    try std.testing.expectEqual(@as(usize, 4), spu.read_idx);
}

test "read_audio truncates an odd max_floats down so a stereo pair is never split" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    pushAudio(h, 4, 1.0); // 8 floats available

    var dst: [16]f32 = undefined;
    const n = capi.ps1_read_audio(h, &dst, 5);

    try std.testing.expectEqual(@as(usize, 4), n);
}

test "read_audio returns 0 when the ring is empty" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    var dst: [16]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), capi.ps1_read_audio(h, &dst, dst.len));
}

test "read_audio caps at max_floats and leaves the rest queued" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    pushAudio(h, 5, 1.0); // 10 floats

    var dst: [16]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), capi.ps1_read_audio(h, &dst, 4));
    try std.testing.expectEqual(@as(usize, 6), capi.ps1_read_audio(h, &dst, dst.len));
}

test "the recorder is armed on create, so a stream exists without a setup call" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    try std.testing.expect(h.cpu.bus.gpu.sink.rec.enabled);
}

test "reset re-arms the recorder" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // ps1_reset rebuilds Bus, which memsets the whole struct — including the
    // recorder's `enabled` flag. A reset that left it disarmed would produce a
    // permanently empty stream with nothing to say why.
    capi.ps1_reset(h);
    try std.testing.expect(h.cpu.bus.gpu.sink.rec.enabled);
}

test "take_frame_stream hands out the frame's records and payload" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // GP0(E1) — one `set_draw_env` record, no payload.
    _ = h.cpu.bus.gpu.writeGp0(0xE1000200, Value.none);

    var s: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &s);

    try std.testing.expectEqual(@as(usize, 1), s.record_count);
    try std.testing.expectEqual(@as(usize, 0), s.payload_count);
    try std.testing.expectEqual(@as(u8, 1), s.complete);
    try std.testing.expectEqual(
        ps1_core.gpu.command.Kind.set_draw_env,
        s.records.?[0].kind,
    );
    try std.testing.expectEqual(@as(u32, 0xE1000200), s.records.?[0].value);
}

test "take_frame_stream RESETS the recorder, so a second call in one frame is empty" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    _ = h.cpu.bus.gpu.writeGp0(0xE1000200, Value.none);

    var first: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &first);
    try std.testing.expectEqual(@as(usize, 1), first.record_count);

    // This is the whole reason the header says "once per frame": the call is a
    // DRAIN, not a peek. A caller that takes twice gets nothing the second
    // time; a caller that never takes accumulates until it overruns.
    var second: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &second);
    try std.testing.expectEqual(@as(usize, 0), second.record_count);
    try std.testing.expectEqual(@as(u8, 1), second.complete);
}

test "a frame that overruns max_records reports complete == 0" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const cap = ps1_core.gpu.recorder.max_records;
    var i: usize = 0;
    // Margin is +64, not the brief's +10: writeGp0 only processes a FIFO word
    // once cycle_debt <= 0 or the 16-word FIFO is full, and this unit test
    // never calls Gpu.step() to drain cycle_debt. So the first 16 writes queue
    // in the FIFO without producing a record yet; the margin covers that
    // backpressure so the loop still pushes past `cap` records.
    while (i < cap + 64) : (i += 1) {
        _ = h.cpu.bus.gpu.writeGp0(0xE1000200, Value.none);
    }

    var s: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &s);

    // The records present are a PREFIX, not a shorter frame. Applying a prefix
    // to a shadow VRAM leaves it permanently out of step with the rasterizer,
    // which is why the flag exists at all.
    try std.testing.expectEqual(@as(usize, cap), s.record_count);
    try std.testing.expectEqual(@as(u8, 0), s.complete);
}

fn xy(x: u16, y: u16) u32 {
    return @as(u32, x & 0x7FF) | (@as(u32, y & 0x7FF) << 16);
}

fn half(w: u32) f32 {
    const signed: i16 = @bitCast(@as(u16, @truncate(w)));
    return @floatFromInt(signed);
}

/// A `pgxp.Value` recorded against `word`, staged by hand exactly as
/// `ps1-core/tests/pgxp_value.zig`'s `subPixelDepth` does — that helper lives
/// under `ps1-core/tests/` and is not part of the `ps1_core` module this
/// binary links, so it is reproduced inline rather than imported.
fn subPixelDepth(word: u32, fx: f32, fy: f32, z: f32) Value {
    return .{
        .x = half(word) + fx,
        .y = half(word >> 16) + fy,
        .z = z,
        .word = word,
        .flags = Value.valid_xyz,
    };
}

// `Ps1GpuStream.records` aliases `ps1_core.gpu.command.Command` directly
// rather than a hand-mirrored Zig struct, so a Zig-side rename cannot drift
// from this binary's view of the field. What CAN drift is `ps1.h`'s own
// `flags` field and the `PS1_GPU_FLAG_*` bits, which only a C/Swift compile of
// that header checks (`ps1-macos/test.sh`) — this test instead pins that a
// real textured-triangle draw, taken through the same `ps1_take_frame_stream`
// call the macOS app makes, carries the bit at all.
test "take_frame_stream's textured-triangle records carry the texture-perspective flag" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    _ = h.cpu.bus.gpu.writeGp0(0xE3000000, Value.none);
    _ = h.cpu.bus.gpu.writeGp0(0xE407FFFF, Value.none);
    _ = h.cpu.bus.gpu.writeGp0(0xE5000000, Value.none);

    capi.ps1_set_pgxp(h, 1); // pgxp_texture_correction defaults on

    const w0 = xy(10, 10);
    const w1 = xy(70, 12);
    const w2 = xy(14, 68);
    _ = h.cpu.bus.gpu.writeGp0(0x25000000, Value.none);
    _ = h.cpu.bus.gpu.writeGp0(w0, subPixelDepth(w0, 0.25, 0.25, 4.0));
    _ = h.cpu.bus.gpu.writeGp0(0x00000000, Value.none);
    _ = h.cpu.bus.gpu.writeGp0(w1, subPixelDepth(w1, 0.5, 0.5, 1.0));
    _ = h.cpu.bus.gpu.writeGp0(0x00000000, Value.none);
    _ = h.cpu.bus.gpu.writeGp0(w2, subPixelDepth(w2, 0.5, 0.5, 16.0));
    _ = h.cpu.bus.gpu.writeGp0(0x00000000, Value.none);
    _ = h.cpu.bus.gpu.step(50_000_000); // drain the GP0 FIFO's cycle_debt

    var s: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &s);

    var found = false;
    for (s.records.?[0..s.record_count]) |rec| {
        if (rec.kind != .draw_textured_triangle) continue;
        found = true;
        try std.testing.expect((rec.flags & ps1_core.gpu.command.flag_texture_perspective) != 0);
        try std.testing.expectEqual(@as(u8, 0), rec.flags & ps1_core.gpu.command.flag_color_perspective);
    }
    try std.testing.expect(found);
}

test "ps1_set_pgxp toggles the core flag" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // Off is the shipped default, and this is where that is pinned on the
    // core side of the ABI.
    try std.testing.expect(!h.cpu.bus.pgxp_enabled);
    capi.ps1_set_pgxp(h, 1);
    try std.testing.expect(h.cpu.bus.pgxp_enabled);
    capi.ps1_set_pgxp(h, 0);
    try std.testing.expect(!h.cpu.bus.pgxp_enabled);

    // Turning it off also drops provenance already armed for a store that has
    // not reached GP0 yet — otherwise a mid-game toggle lets one stray vertex
    // resolve while the flag reads false.
    capi.ps1_set_pgxp(h, 1);
    h.cpu.bus.pgxp_pending = .{ .x = 4, .y = 4, .word = (4 << 16) | 4, .flags = Value.valid_xy };
    capi.ps1_set_pgxp(h, 0);
    try std.testing.expectEqual(@as(u32, 0), h.cpu.bus.pgxp_pending.flags);
}

/// The first record of Final Fantasy IX (France) disc 1's `.sbi`: the drive is
/// made to report a position that disagrees with sector 03:08:05's real
/// address, and that disagreement is what the protection measures.
const ff9_sbi =
    "SBI\x00" ++
    "\x03\x08\x05\x01\x41\x01\x01\x07\x06\x05\x00\x23\x08\x05";

fn ff9LibCryptLba() i32 {
    return (ps1_core.disc.MSF{ .m = 0x03, .s = 0x08, .f = 0x05 }).toLba();
}

test "load_disc attaches a .sbi sidecar to the drive's disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        single_file_cue.ptr,
        single_file_cue.len,
        ff9_sbi.ptr,
        ff9_sbi.len,
        null,
        0,
    ));
    try std.testing.expect(h.cpu.bus.cdrom.disc.?.isLibCryptSector(ff9LibCryptLba()));
}

test "the sidecar is copied, not borrowed from the caller" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // Freed before the drive is asked about it: a borrowed sidecar reads
    // freed memory here, which is the whole reason the handle copies it.
    const sbi = try std.testing.allocator.dupe(u8, ff9_sbi);
    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        null,
        0,
        sbi.ptr,
        sbi.len,
        null,
        0,
    ));
    std.testing.allocator.free(sbi);

    try std.testing.expect(h.cpu.bus.cdrom.disc.?.isLibCryptSector(ff9LibCryptLba()));
}

test "reset re-attaches the sidecar along with the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        null,
        0,
        ff9_sbi.ptr,
        ff9_sbi.len,
        null,
        0,
    ));
    capi.ps1_reset(h);

    try std.testing.expect(h.cpu.bus.cdrom.disc.?.isLibCryptSector(ff9LibCryptLba()));
}

test "loading a second disc drops the first one's sidecar" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        null,
        0,
        ff9_sbi.ptr,
        ff9_sbi.len,
        null,
        0,
    ));
    // A sidecar's records are addresses on the disc it shipped with, so one
    // left over from the previous disc flags sectors of this one at random.
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0, null, 0));

    try std.testing.expect(!h.cpu.bus.cdrom.disc.?.isLibCryptSector(ff9LibCryptLba()));
}

test "a sidecar without the SBI magic is refused rather than parsed as records" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const junk = "NOTSBI\x00\x00" ++ "\x03\x08\x05\x01\x41\x01\x01\x07\x06\x05\x00\x23\x08\x05";
    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, -5), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        null,
        0,
        junk.ptr,
        junk.len,
        null,
        0,
    ));
}

test "swap_disc validates exactly as load_disc does" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0, null, 0));

    // A rejection must leave the running machine's disc alone -- this is a
    // LIVE swap, so a half-applied one is a game reading a disc that is not
    // there. Both checks happen before anything is allocated or assigned.
    const swap: [2352]u8 = @splat(0);
    try std.testing.expectEqual(
        @as(i32, -3),
        capi.ps1_swap_disc(h, &swap, swap.len, multi_file_cue.ptr, multi_file_cue.len, null, 0, null, 0),
    );
    try std.testing.expectEqual(
        @as(i32, -5),
        capi.ps1_swap_disc(h, &swap, swap.len, null, 0, "NOTSBI".ptr, 6, null, 0),
    );
    try std.testing.expectEqual(@as(i32, -2), capi.ps1_swap_disc(h, &swap, 0, null, 0, null, 0, null, 0));

    try std.testing.expect(h.disc != null);
    try std.testing.expect(!h.bus.cdrom.drive.shell_open);
}

test "swap_disc opens the tray and installs the new disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    var first: [2352]u8 = @splat(0);
    var second: [2352]u8 = @splat(0);
    first[0] = 0xAA;
    second[0] = 0xBB;

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &first, first.len, null, 0, null, 0, null, 0));
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_swap_disc(h, &second, second.len, null, 0, null, 0, null, 0));

    try std.testing.expect(h.bus.cdrom.drive.shell_open);
    try std.testing.expect(h.bus.cdrom.drive.shell_changed);
    try std.testing.expectEqual(@as(u8, 0xBB), h.bus.cdrom.disc.?.source.flat[0]);
}

test "swap_disc replaces the handle's sidecar rather than keeping the old one" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352]u8 = @splat(0);
    const sbi_a = "SBI\x00" ++ @as([14]u8, @splat(0));
    const sbi_b = "SBI\x00" ++ @as([28]u8, @splat(0));

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, sbi_a.ptr, sbi_a.len, null, 0));
    try std.testing.expectEqual(@as(usize, sbi_a.len), h.sbi.len);

    // Each disc of a multi-disc set carries its own sidecar, naming sectors of
    // its OWN image. Carrying the previous disc's over is worth exactly as
    // much as carrying none.
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_swap_disc(h, &bin, bin.len, null, 0, sbi_b.ptr, sbi_b.len, null, 0));
    try std.testing.expectEqual(@as(usize, sbi_b.len), h.sbi.len);
}

/// A PPF1 writing `data` at byte `offset` of the image.
fn ppf1(comptime offset: u32, comptime data: []const u8) []const u8 {
    return comptime blk: {
        var off: [4]u8 = undefined;
        std.mem.writeInt(u32, &off, offset, .little);
        const desc: [50]u8 = @splat(' ');
        break :blk "PPF10\x00" ++ desc ++ off ++ [_]u8{data.len} ++ data;
    };
}

fn readDiscByte(h: *capi.Handle, offset: usize) !u8 {
    var raw: [2352]u8 = undefined;
    try std.testing.expect(h.bus.cdrom.disc.?.readSector2352(@intCast(offset / 2352), &raw));
    return raw[offset % 2352];
}

test "load_disc applies a .ppf, and the patch bytes need not outlive the call" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352 * 4]u8 = @splat(0x11);
    const patch = try std.testing.allocator.dupe(u8, ppf1(2352 * 2 + 5, "Z"));
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0, patch.ptr, patch.len));
    @memset(patch, 0);
    std.testing.allocator.free(patch);

    try std.testing.expectEqual(@as(u8, 'Z'), try readDiscByte(h, 2352 * 2 + 5));
    try std.testing.expectEqual(@as(u8, 0x11), try readDiscByte(h, 2352 * 2 + 6));
    try std.testing.expect(h.bus.cdrom.disc.?.patch.fingerprint != 0);
}

test "a refused patch leaves the running machine on the disc it had" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352 * 20]u8 = @splat(0x11);
    const good = ppf1(100, "A");
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0, good.ptr, good.len));

    const junk = "PPF90 not a patch at all, though it is long enough to be one...";
    try std.testing.expectEqual(capi.PS1_ERR_BAD_PPF, capi.ps1_swap_disc(h, &bin, bin.len, null, 0, null, 0, junk.ptr, junk.len));

    // A PPF2 whose blockcheck is not this image's.
    const desc: [50]u8 = @splat(' ');
    const block: [1024]u8 = @splat(0x22);
    const other = "PPF20\x01" ++ desc ++ [_]u8{ 0, 0, 0, 0 } ++ block ++ [_]u8{ 0, 0, 0, 0, 1, 'B' };
    try std.testing.expectEqual(capi.PS1_ERR_PPF_MISMATCH, capi.ps1_swap_disc(h, &bin, bin.len, null, 0, null, 0, other.ptr, other.len));

    try std.testing.expect(!h.bus.cdrom.drive.shell_open);
    try std.testing.expectEqual(@as(u8, 'A'), try readDiscByte(h, 100));
}

test "swap_disc replaces the patch, and a disc swapped in without one is unpatched" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin: [2352 * 4]u8 = @splat(0x11);
    const a = ppf1(10, "A");
    const b = ppf1(10, "B");
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0, a.ptr, a.len));
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_swap_disc(h, &bin, bin.len, null, 0, null, 0, b.ptr, b.len));
    try std.testing.expectEqual(@as(u8, 'B'), try readDiscByte(h, 10));
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_swap_disc(h, &bin, bin.len, null, 0, null, 0, null, 0));
    try std.testing.expectEqual(@as(u8, 0x11), try readDiscByte(h, 10));
    try std.testing.expectEqual(@as(u64, 0), h.bus.cdrom.disc.?.patch.fingerprint);
}

const memcard_bytes = ps1_core.sio.Sio.memcard_bytes;

test "load_memcard rejects a wrong length and an out-of-range slot" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const short: [16]u8 = @splat(0);
    try std.testing.expectEqual(@as(i32, -6), capi.ps1_load_memcard(h, 0, &short, short.len));

    const image = try std.testing.allocator.alloc(u8, memcard_bytes);
    defer std.testing.allocator.free(image);
    @memset(image, 0x42);

    try std.testing.expectEqual(@as(i32, -7), capi.ps1_load_memcard(h, 2, image.ptr, image.len));
    try std.testing.expectEqual(@as(i32, -7), capi.ps1_load_memcard(h, -1, image.ptr, image.len));
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_memcard(h, 1, image.ptr, image.len));
    try std.testing.expectEqual(@as(u8, 0x42), h.cpu.bus.sio.getMemoryCardData(1)[0]);
    try std.testing.expectEqual(@as(u8, 0x00), h.cpu.bus.sio.getMemoryCardData(0)[0]);
}

test "take_memcard is a drain: 1 once, 0 after" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const dst = try std.testing.allocator.alloc(u8, memcard_bytes);
    defer std.testing.allocator.free(dst);
    @memset(dst, 0xEE);

    // A card nobody has written is clean, and a clean take must not touch dst.
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_take_memcard(h, 0, dst.ptr));
    try std.testing.expectEqual(@as(u8, 0xEE), dst[0]);

    // Dirty it the way the machine does.
    h.cpu.bus.sio.getMemoryCardData(0)[0] = 0x99;
    h.cpu.bus.sio.memcard_dirty[0] = true;

    try std.testing.expectEqual(@as(i32, 1), capi.ps1_take_memcard(h, 0, dst.ptr));
    try std.testing.expectEqual(@as(u8, 0x99), dst[0]);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_take_memcard(h, 0, dst.ptr));
    try std.testing.expectEqual(@as(i32, -7), capi.ps1_take_memcard(h, 5, dst.ptr));
}

test "reset keeps the card, including writes the frontend never took" {
    // A front-panel reset does not wipe a memory card. Bus.init memsets the
    // struct, so the images have to be snapshotted and reinstalled — and
    // snapshotted at reset rather than at the last take, or a save made
    // between the two would be lost.
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const image = try std.testing.allocator.alloc(u8, memcard_bytes);
    defer std.testing.allocator.free(image);
    @memset(image, 0x11);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_memcard(h, 0, image.ptr, image.len));

    h.cpu.bus.sio.getMemoryCardData(0)[64] = 0x77; // an untaken write

    capi.ps1_reset(h);

    try std.testing.expectEqual(@as(u8, 0x11), h.cpu.bus.sio.getMemoryCardData(0)[0]);
    try std.testing.expectEqual(@as(u8, 0x77), h.cpu.bus.sio.getMemoryCardData(0)[64]);

    // The converse of the test below: this card was never marked dirty (the
    // write above pokes the backing bytes directly, the way a test can but a
    // real transfer can't), so the reset must not manufacture a dirty flag —
    // that would cost the frontend a pointless 128 KB write on every single
    // reset, not just the ones that matter.
    const dst = try std.testing.allocator.alloc(u8, memcard_bytes);
    defer std.testing.allocator.free(dst);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_take_memcard(h, 0, dst.ptr));
}

test "reset keeps the card DIRTY if the frontend had not taken it yet" {
    // The bytes surviving is not enough. A frontend persists in response to
    // ps1_take_memcard returning 1, so a reset that clears the flag while
    // keeping the bytes leaves the save in the emulator and never on disk —
    // the player saves, hits reset inside the write debounce, quits, and the
    // save is gone.
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    h.cpu.bus.sio.getMemoryCardData(0)[64] = 0x77;
    h.cpu.bus.sio.memcard_dirty[0] = true;

    capi.ps1_reset(h);

    const dst = try std.testing.allocator.alloc(u8, memcard_bytes);
    defer std.testing.allocator.free(dst);
    try std.testing.expectEqual(@as(i32, 1), capi.ps1_take_memcard(h, 0, dst.ptr));
    try std.testing.expectEqual(@as(u8, 0x77), dst[64]);
}

// The boundary, not the parser: `discid_test.zig` covers the ISO walk over
// synthetic Mode 1 and Mode 2 discs. What matters here is that the struct
// crosses as C expects it, that the strings are NUL-terminated, and that an
// image too small to be a disc is refused rather than read past.
test "identify_disc reports the licence region of a disc with no filesystem" {
    var image: [2352 * 8]u8 = @splat(0);
    const license = "          Licensed  by          Sony Computer Entertainment Euro pe   ";
    image[4 * 2352 + 15] = 0x02; // Mode 2: user data starts at 018h
    @memcpy(image[4 * 2352 + 24 ..][0..license.len], license);

    var id: capi.Ps1DiscId = undefined;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_identify_disc(&image, image.len, &id));
    try std.testing.expectEqual(@as(u8, 2), id.region); // PS1_REGION_EUROPE
    try std.testing.expectEqual(@as(u8, 0), id.serial[0]);
    try std.testing.expectEqual(@as(u8, 0), id.volume_id[0]);
}

test "identify_disc refuses an image too small to hold a sector" {
    const image: [16]u8 = @splat(0);
    var id: capi.Ps1DiscId = undefined;
    try std.testing.expectEqual(@as(i32, -2), capi.ps1_identify_disc(&image, image.len, &id));
}

test "identify_disc reports no region for a disc that carries no licence" {
    const image: [2352 * 8]u8 = @splat(0);
    var id: capi.Ps1DiscId = undefined;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_identify_disc(&image, image.len, &id));
    try std.testing.expectEqual(@as(u8, 0), id.region); // PS1_REGION_UNKNOWN
}

test "the identify struct matches the layout ps1.h declares" {
    try std.testing.expectEqual(@as(usize, 50), @sizeOf(capi.Ps1DiscId));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(capi.Ps1DiscId));
}

test "lookup_disc_set exposes catalogued multi-disc metadata without changing DiscId" {
    var set: capi.Ps1DiscSet = undefined;
    try std.testing.expectEqual(@as(u8, 1), capi.ps1_lookup_disc_set("SLES-12965", &set));
    try std.testing.expectEqualStrings("Final Fantasy IX (Europe)", std.mem.sliceTo(&set.game_title, 0));
    try std.testing.expectEqual(@as(u8, 2), set.disc_number);
    try std.testing.expectEqual(@as(u8, 0), capi.ps1_lookup_disc_set("SLUS-00530", &set));
    try std.testing.expectEqual(@as(u8, 0), set.disc_number);
}

test "lookup_game_title names a catalogued disc and zeroes an unknown one" {
    var t: capi.Ps1GameTitle = undefined;
    try std.testing.expectEqual(@as(u8, 1), capi.ps1_lookup_game_title("slus-00152", &t));
    try std.testing.expectEqualStrings("Tomb Raider", std.mem.sliceTo(&t.title, 0));
    try std.testing.expectEqual(@as(u8, 0), capi.ps1_lookup_game_title("SLUS-99999", &t));
    try std.testing.expectEqual(@as(u8, 0), t.title[0]);
}

test "lookup_pgxp_preset marks every setting the game does not list as -1" {
    var p: capi.Ps1PgxpPreset = undefined;
    // Tekken 3 (USA): CPU mode on and a 3 px tolerance, nothing else.
    try std.testing.expectEqual(@as(u8, 1), capi.ps1_lookup_pgxp_preset("SLUS-00402", &p));
    try std.testing.expectEqual(@as(i8, 1), p.cpu);
    try std.testing.expectEqual(@as(u8, 1), p.has_tolerance);
    try std.testing.expectEqual(@as(f32, 3), p.tolerance);
    try std.testing.expectEqual(@as(i8, -1), p.enabled);
    try std.testing.expectEqual(@as(i8, -1), p.culling);

    // Doom (USA) turns PGXP off.
    try std.testing.expectEqual(@as(u8, 1), capi.ps1_lookup_pgxp_preset("SLUS-00077", &p));
    try std.testing.expectEqual(@as(i8, 0), p.enabled);
    try std.testing.expectEqual(@as(u8, 0), p.has_tolerance);

    try std.testing.expectEqual(@as(u8, 0), capi.ps1_lookup_pgxp_preset("SLUS-00707", &p));
    try std.testing.expectEqual(@as(i8, -1), p.enabled);
    try std.testing.expectEqual(@as(i8, -1), p.preserve_projection);
}

test "the preset struct matches the layout ps1.h declares" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(capi.Ps1PgxpPreset));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(capi.Ps1PgxpPreset));
    try std.testing.expectEqual(@as(usize, 5), @offsetOf(capi.Ps1PgxpPreset, "enabled"));
}

test "the PGXP sub-settings cross the ABI with their defaults" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // Defaults, pinned on the core side of the ABI. cpu and culling both ship
    // ON; both are gated on the master flag, so neither does anything yet.
    try std.testing.expect(h.cpu.bus.pgxp_cpu);
    try std.testing.expect(h.cpu.bus.pgxp_culling);
    try std.testing.expect(h.cpu.bus.pgxp_vertex_cache == null);
    try std.testing.expect(h.cpu.bus.pgxp_tolerance < 0);

    capi.ps1_set_pgxp_cpu(h, 0);
    try std.testing.expect(!h.cpu.bus.pgxp_cpu);
    capi.ps1_set_pgxp_culling(h, 0);
    try std.testing.expect(!h.cpu.bus.pgxp_culling);
    capi.ps1_set_pgxp_tolerance(h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), h.cpu.bus.pgxp_tolerance, 0.0);
    capi.ps1_set_pgxp_vertex_cache(h, 1);
    try std.testing.expect(h.cpu.bus.pgxp_vertex_cache != null);
    capi.ps1_set_pgxp_vertex_cache(h, 0);
    try std.testing.expect(h.cpu.bus.pgxp_vertex_cache == null);
}

test "a sub-setting does nothing while the master flag is off" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_pgxp_vertex_cache(h, 1);
    // Allocated, but unreachable: there is no state in which a sub-setting
    // acts while geometry correction does not.
    try std.testing.expect(h.cpu.bus.pgxp_vertex_cache != null);
    try std.testing.expect(h.cpu.bus.pgxpConfig().vertex_cache == null);
    try std.testing.expect(!h.cpu.bus.pgxpConfig().culling);

    capi.ps1_set_pgxp(h, 1);
    try std.testing.expect(h.cpu.bus.pgxpConfig().vertex_cache != null);
    try std.testing.expect(h.cpu.bus.pgxpConfig().culling);
}

test "the PGXP settings survive a reset" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_pgxp(h, 1);
    capi.ps1_set_pgxp_cpu(h, 0);
    capi.ps1_set_pgxp_culling(h, 0);
    capi.ps1_set_pgxp_tolerance(h, 0.5);
    capi.ps1_set_pgxp_vertex_cache(h, 1);

    // `ps1_reset` frees the Bus and builds a new one, so every setting on it
    // is back at its default unless it is carried across -- exactly as the
    // BIOS image and the memory cards already are. A player who resets must
    // not silently lose the renderer settings they chose.
    capi.ps1_reset(h);

    try std.testing.expect(h.cpu.bus.pgxp_enabled);
    try std.testing.expect(!h.cpu.bus.pgxp_cpu);
    try std.testing.expect(!h.cpu.bus.pgxp_culling);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), h.cpu.bus.pgxp_tolerance, 0.0);
    try std.testing.expect(h.cpu.bus.pgxp_vertex_cache != null);
}

test "colour correction crosses the ABI and defaults off" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // OFF is the shipped default, matching the reference — it is the one
    // correction with a per-game disable list there.
    try std.testing.expect(!h.cpu.bus.pgxp_color_correction);
    capi.ps1_set_pgxp_color_correction(h, 1);
    try std.testing.expect(h.cpu.bus.pgxp_color_correction);
    // Still inert without the master flag.
    try std.testing.expect(!h.cpu.bus.pgxpColorCorrection());
    capi.ps1_set_pgxp(h, 1);
    try std.testing.expect(h.cpu.bus.pgxpColorCorrection());
    try std.testing.expect(h.cpu.bus.gpu.gp0.pgxp_color_correction);
}

test "a reset keeps the player's correction settings" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_set_pgxp(h, 1);
    capi.ps1_set_pgxp_texture_correction(h, 0);
    capi.ps1_set_pgxp_color_correction(h, 1);
    capi.ps1_reset(h);
    // Renderer settings are the player's choice, not machine state: a reset
    // rebuilds Bus, and Bus.init puts every one of them back at its default —
    // but `ps1_reset` snapshots them beforehand and restores them after, so
    // they are carried across rather than reset to that default.
    try std.testing.expect(!h.cpu.bus.pgxp_texture_correction);
    try std.testing.expect(h.cpu.bus.pgxp_color_correction);
}

test "Phase5: the three depth settings default off and fold in the master flag" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expect(!h.cpu.bus.pgxp_depth_buffer);
    try std.testing.expect(!h.cpu.bus.pgxp_transparent_depth);
    try std.testing.expect(!h.cpu.bus.pgxp_disable_2d);

    capi.ps1_set_pgxp_depth_buffer(h, 1);
    capi.ps1_set_pgxp_transparent_depth(h, 1);
    capi.ps1_set_pgxp_disable_2d(h, 1);
    try std.testing.expect(!h.cpu.bus.pgxpDepthBuffer()); // PGXP itself is off
    try std.testing.expect(!h.cpu.bus.gpu.gp0.pgxp_transparent_depth);

    capi.ps1_set_pgxp(h, 1);
    try std.testing.expect(h.cpu.bus.gpu.gp0.pgxp_depth_buffer);
    try std.testing.expect(h.cpu.bus.gpu.gp0.pgxp_transparent_depth);
    try std.testing.expect(h.cpu.bus.gpu.gp0.pgxp_disable_2d);

    // transparent_depth is a SUB-flag: meaningless without the buffer.
    capi.ps1_set_pgxp_depth_buffer(h, 0);
    try std.testing.expect(!h.cpu.bus.gpu.gp0.pgxp_transparent_depth);
}

test "Phase5: ps1_reset keeps the three depth settings" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_set_pgxp_depth_buffer(h, 1);
    capi.ps1_set_pgxp_transparent_depth(h, 1);
    capi.ps1_set_pgxp_disable_2d(h, 1);
    capi.ps1_reset(h);
    try std.testing.expect(h.cpu.bus.pgxp_depth_buffer);
    try std.testing.expect(h.cpu.bus.pgxp_transparent_depth);
    try std.testing.expect(h.cpu.bus.pgxp_disable_2d);
}

test "Phase6: preserve projection crosses the ABI, defaults off and folds in the master flag" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    try std.testing.expect(!h.cpu.bus.pgxp_preserve_projection);
    capi.ps1_set_pgxp_preserve_projection(h, 1);
    try std.testing.expect(h.cpu.bus.pgxp_preserve_projection);
    try std.testing.expect(!h.cpu.bus.pgxpConfig().preserve_projection); // PGXP itself is off

    capi.ps1_set_pgxp(h, 1);
    try std.testing.expect(h.cpu.bus.pgxpConfig().preserve_projection);
}

test "Phase6: ps1_reset keeps preserve projection" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    capi.ps1_set_pgxp(h, 1);
    capi.ps1_set_pgxp_preserve_projection(h, 1);
    capi.ps1_reset(h);
    try std.testing.expect(h.cpu.bus.pgxp_preserve_projection);
    try std.testing.expect(h.cpu.bus.pgxpConfig().preserve_projection);
}

fn bootHandle(fill: u8) !*capi.Handle {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    errdefer capi.ps1_destroy(h);
    const bios = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(bios);
    @memset(bios, fill);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, bios.ptr, bios.len));
    return h;
}

fn saveState(h: *capi.Handle) ![]u8 {
    const cap = capi.ps1_save_state_size(h);
    const buf = try std.testing.allocator.alloc(u8, cap);
    errdefer std.testing.allocator.free(buf);
    var len: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_save_state(h, buf.ptr, buf.len, &len));
    try std.testing.expectEqual(cap, len);
    return buf;
}

test "save then load restores the machine" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    h.cpu.bus.ram[0x2000] = 0x77;
    h.cpu.regs[8] = 0xBEEF;
    const state = try saveState(h);
    defer std.testing.allocator.free(state);

    h.cpu.bus.ram[0x2000] = 0;
    h.cpu.regs[8] = 0;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_state(h, state.ptr, state.len));
    try std.testing.expectEqual(@as(u8, 0x77), h.cpu.bus.ram[0x2000]);
    try std.testing.expectEqual(@as(u32, 0xBEEF), h.cpu.regs[8]);
    try std.testing.expect(h.cpu.bus == h.bus);
}

test "a refused load leaves the running machine untouched" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    const state = try saveState(h);
    defer std.testing.allocator.free(state);
    state[100] ^= 0xFF;

    const bus_before = h.bus;
    h.cpu.bus.ram[0x3000] = 0x42;
    try std.testing.expectEqual(capi.PS1_ERR_STATE_CORRUPT, capi.ps1_load_state(h, state.ptr, state.len));
    try std.testing.expect(h.bus == bus_before);
    try std.testing.expectEqual(@as(u8, 0x42), h.cpu.bus.ram[0x3000]);
}

test "a state from a different BIOS is refused" {
    const a = try bootHandle(0x11);
    defer capi.ps1_destroy(a);
    const state = try saveState(a);
    defer std.testing.allocator.free(state);

    const b = try bootHandle(0x22);
    defer capi.ps1_destroy(b);
    try std.testing.expectEqual(capi.PS1_ERR_STATE_BIOS, capi.ps1_load_state(b, state.ptr, state.len));
}

test "save into a short buffer is NO_SPACE" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    var tiny: [16]u8 = undefined;
    var len: usize = 0;
    try std.testing.expectEqual(capi.PS1_ERR_STATE_NO_SPACE, capi.ps1_save_state(h, &tiny, tiny.len, &len));
}

test "peek reads the identity without a machine" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    const state = try saveState(h);
    defer std.testing.allocator.free(state);
    var info: capi.Ps1StateInfo = undefined;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_peek_state(state.ptr, state.len, &info));
    try std.testing.expectEqual(@as(u8, 0), info.serial[0]); // no disc
    try std.testing.expectEqual(capi.PS1_ERR_STATE_BAD_MAGIC, capi.ps1_peek_state(state.ptr, 3, &info));
}

test "a load keeps the player's settings and an undrained card write" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    const state = try saveState(h);
    defer std.testing.allocator.free(state);

    capi.ps1_set_pgxp(h, 1);
    capi.ps1_set_pgxp_texture_correction(h, 0);
    h.cpu.bus.sio.memcard_dirty[0] = true;

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_state(h, state.ptr, state.len));
    try std.testing.expect(h.bus.pgxp_enabled);
    try std.testing.expect(!h.bus.pgxp_texture_correction);
    try std.testing.expect(h.bus.sio.memcard_dirty[0]);
}

test "snapshot_return without a mark is NO_SNAPSHOT" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(capi.PS1_ERR_NO_SNAPSHOT, capi.ps1_snapshot_return(h));
}

test "snapshot mark and return restore the machine in place" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    h.cpu.bus.ram[0x2000] = 0x77;
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_mark(h));
    h.cpu.bus.ram[0x2000] = 0;
    const bus_before = h.bus;
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_return(h));
    try std.testing.expectEqual(@as(u8, 0x77), h.cpu.bus.ram[0x2000]);
    try std.testing.expect(h.bus == bus_before);
    try std.testing.expect(h.cpu.bus == h.bus);
}

test "a card write between mark and return is rolled back, dirty flag included" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_mark(h));
    h.cpu.bus.sio.memcard_data[0][9] = 0x5A;
    h.cpu.bus.sio.memcard_dirty[0] = true;
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_return(h));
    try std.testing.expectEqual(@as(u8, 0), h.cpu.bus.sio.memcard_data[0][9]);
    try std.testing.expect(!h.cpu.bus.sio.memcard_dirty[0]);
}

test "audio produced between mark and return is gone after the return" {
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    pushAudio(h, 4, 1.0);
    var out: [64]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 8), capi.ps1_read_audio(h, &out, out.len));
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_mark(h));
    pushAudio(h, 4, 100.0);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_return(h));
    try std.testing.expectEqual(@as(usize, 0), capi.ps1_read_audio(h, &out, out.len));
}

test "reset, load_state, load_disc, swap_disc, load_bios and load_memcard each forget the mark" {
    const bin: [2352]u8 = @splat(0);
    const bios: [524288]u8 = @splat(0x11);
    const card: [131072]u8 = @splat(0);
    for (0..6) |which| {
        const h = try bootHandle(0x11);
        defer capi.ps1_destroy(h);
        const state = try saveState(h);
        defer std.testing.allocator.free(state);
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_mark(h));
        switch (which) {
            0 => capi.ps1_reset(h),
            1 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_state(h, state.ptr, state.len)),
            2 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0, null, 0)),
            3 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_swap_disc(h, &bin, bin.len, null, 0, null, 0, null, 0)),
            4 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_bios(h, &bios, bios.len)),
            // A card the host installs would be rolled back by a return.
            else => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_memcard(h, 0, &card, card.len)),
        }
        try std.testing.expectEqual(capi.PS1_ERR_NO_SNAPSHOT, capi.ps1_snapshot_return(h));
    }
}

/// A BIOS that branches to itself forever (`b .`, then its delay-slot nop),
/// so every engine runs the same two-instruction block frame after frame.
fn loadSpinBios(h: *capi.Handle) !void {
    const bios = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(bios);
    @memset(bios, 0);
    std.mem.writeInt(u32, bios[0..4], 0x1000_FFFF, .little);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_bios(h, bios.ptr, bios.len));
}

test "a new handle runs on the interpreter" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(@as(c_int, 0), capi.ps1_get_cpu_engine(h));
}

test "set_cpu_engine refuses a number that names no engine and keeps the current one" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, 1));
    try std.testing.expectEqual(capi.PS1_ERR_ENGINE_UNAVAILABLE, capi.ps1_set_cpu_engine(h, 3));
    try std.testing.expectEqual(capi.PS1_ERR_ENGINE_UNAVAILABLE, capi.ps1_set_cpu_engine(h, -1));
    try std.testing.expectEqual(@as(c_int, 1), capi.ps1_get_cpu_engine(h));
    try std.testing.expectEqual(@as(c_int, 0), capi.ps1_cpu_engine_available(3));
}

test "set_cpu_engine selects the JIT exactly where this build has one" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(@as(c_int, 1), capi.ps1_cpu_engine_available(0));
    try std.testing.expectEqual(@as(c_int, 1), capi.ps1_cpu_engine_available(1));
    if (ps1_core.recompiler.jit.available) {
        try std.testing.expectEqual(@as(c_int, 1), capi.ps1_cpu_engine_available(2));
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, 2));
        try std.testing.expectEqual(@as(c_int, 2), capi.ps1_get_cpu_engine(h));
    } else {
        try std.testing.expectEqual(@as(c_int, 0), capi.ps1_cpu_engine_available(2));
        try std.testing.expectEqual(capi.PS1_ERR_ENGINE_UNAVAILABLE, capi.ps1_set_cpu_engine(h, 2));
        try std.testing.expectEqual(@as(c_int, 0), capi.ps1_get_cpu_engine(h));
    }
}

/// Every engine number this build can run, in `buf`.
fn availableEngines(buf: *[3]c_int) []const c_int {
    var n: usize = 0;
    for ([_]c_int{ 0, 1, 2 }) |e| {
        if (capi.ps1_cpu_engine_available(e) == 0) continue;
        buf[n] = e;
        n += 1;
    }
    return buf[0..n];
}

test "every engine survives a reset, which rebuilds Bus" {
    var engine_buf: [3]c_int = undefined;
    for (availableEngines(&engine_buf)) |e| {
        const h = capi.ps1_create() orelse return error.CreateFailed;
        defer capi.ps1_destroy(h);
        try loadSpinBios(h);
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, e));
        capi.ps1_run_frame(h);
        capi.ps1_reset(h);
        try std.testing.expectEqual(e, capi.ps1_get_cpu_engine(h));
        capi.ps1_run_frame(h);
        try std.testing.expect(h.cpu.bus.gpu.is_vblank);
    }
}

test "a state saved under any engine loads under the engine the loading handle chose" {
    var engine_buf: [3]c_int = undefined;
    const engines = availableEngines(&engine_buf);
    for (engines) |saver| {
        for (engines) |loader| {
            const a = capi.ps1_create() orelse return error.CreateFailed;
            defer capi.ps1_destroy(a);
            try loadSpinBios(a);
            try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(a, saver));
            capi.ps1_run_frame(a);
            capi.ps1_run_frame(a);

            const size = capi.ps1_save_state_size(a);
            const buf = try std.testing.allocator.alloc(u8, size);
            defer std.testing.allocator.free(buf);
            var len: usize = 0;
            try std.testing.expectEqual(capi.PS1_OK, capi.ps1_save_state(a, buf.ptr, buf.len, &len));

            const b = capi.ps1_create() orelse return error.CreateFailed;
            defer capi.ps1_destroy(b);
            try loadSpinBios(b);
            try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(b, loader));
            try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_state(b, buf.ptr, len));
            try std.testing.expectEqual(loader, capi.ps1_get_cpu_engine(b));
            try std.testing.expectEqual(a.cpu.cycles, b.cpu.cycles);
            capi.ps1_run_frame(b);
            try std.testing.expect(b.cpu.bus.gpu.is_vblank);
        }
    }
}

test "a refused state load leaves the machine and its engine running" {
    var engine_buf: [3]c_int = undefined;
    for (availableEngines(&engine_buf)) |e| {
        const h = capi.ps1_create() orelse return error.CreateFailed;
        defer capi.ps1_destroy(h);
        try loadSpinBios(h);
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, e));
        capi.ps1_run_frame(h);
        const cycles = h.cpu.cycles;
        const junk: [64]u8 = @splat(0);
        try std.testing.expect(capi.ps1_load_state(h, &junk, junk.len) != capi.PS1_OK);
        try std.testing.expectEqual(e, capi.ps1_get_cpu_engine(h));
        try std.testing.expectEqual(cycles, h.cpu.cycles);
        capi.ps1_run_frame(h);
        try std.testing.expect(h.cpu.cycles > cycles);
    }
}

test "switching engines between frames keeps the machine running" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try loadSpinBios(h);
    const order = [_]c_int{ 1, 2, 0, 1, 0 };
    for (order) |e| {
        if (capi.ps1_cpu_engine_available(e) == 0) continue;
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, e));
        const before = h.cpu.cycles;
        capi.ps1_run_frame(h);
        try std.testing.expect(h.cpu.bus.gpu.is_vblank);
        try std.testing.expect(h.cpu.cycles > before);
    }
}

test "run_frame under the JIT ends where the cached interpreter does" {
    if (!ps1_core.recompiler.jit.available) return error.SkipZigTest;
    var ends: [2]u64 = undefined;
    for ([_]c_int{ 1, 2 }, 0..) |e, i| {
        const h = capi.ps1_create() orelse return error.CreateFailed;
        defer capi.ps1_destroy(h);
        try loadSpinBios(h);
        try std.testing.expectEqual(capi.PS1_OK, capi.ps1_set_cpu_engine(h, e));
        for (0..3) |_| capi.ps1_run_frame(h);
        ends[i] = h.cpu.cycles;
    }
    try std.testing.expectEqual(ends[0], ends[1]);
}

/// Swaps the handle's worker for a `.deferred` one: a draw then stays
/// queued until something syncs, so a missing sync reads stale pixels on
/// every run.
fn deferWorker(h: *capi.Handle) !void {
    h.cpu.bus.gpu.detachRasterWorker();
    try h.cpu.bus.gpu.attachRasterWorker(std.testing.allocator, std.testing.io, .deferred);
}

fn gp0(h: *capi.Handle, words: []const u32) void {
    for (words) |w| {
        h.cpu.bus.gpu.cycle_debt = 0;
        _ = h.cpu.bus.gpu.writeGp0(w, Value.none);
    }
}

/// Full drawing area, then a red 16x16 fill at the origin.
fn queueRedFill(h: *capi.Handle) void {
    gp0(h, &.{ 0xE3000000, 0xE407FFFF, 0xE5000000, 0x020000FF, 0, 0x0010_0010 });
}

test "a new handle rasterizes on a worker thread" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    const w = h.cpu.bus.gpu.sink.worker orelse return error.NoWorker;
    try std.testing.expect(w.thread != null);
}

test "copy_vram waits for a draw still queued on the worker" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try deferWorker(h);
    queueRedFill(h);
    try std.testing.expectEqual(@as(u16, 0), h.cpu.bus.gpu.vram.data[0]);

    const dst = try std.testing.allocator.alloc(u16, 1024 * 512);
    defer std.testing.allocator.free(dst);
    capi.ps1_copy_vram(h, dst.ptr);
    try std.testing.expectEqual(@as(u16, 0x001F), dst[0]);
}

test "copy_depth waits for the worker" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try deferWorker(h);
    h.cpu.bus.gpu.vram.depth[0] = 5; // the worker is idle: nothing queued
    queueRedFill(h); // a fill resets depth where it writes colour

    const dst = try std.testing.allocator.alloc(u32, 1024 * 512);
    defer std.testing.allocator.free(dst);
    capi.ps1_copy_depth(h, dst.ptr);
    try std.testing.expectEqual(@as(u32, 0), dst[0]);
}

test "a state saved with draws queued equals one saved inline" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const threaded = try bootHandle(0x11);
    defer capi.ps1_destroy(threaded);
    const inline_h = try bootHandle(0x11);
    defer capi.ps1_destroy(inline_h);
    try deferWorker(threaded);
    inline_h.cpu.bus.gpu.detachRasterWorker();

    queueRedFill(threaded);
    queueRedFill(inline_h);
    const a = try saveState(threaded);
    defer std.testing.allocator.free(a);
    const b = try saveState(inline_h);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, b, a);
}

test "a state saved mid-upload resumes the upload on the loading handle's worker" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const src = try bootHandle(0x11);
    defer capi.ps1_destroy(src);
    gp0(src, &.{ 0xA0000000, 8, 0x0001_0004, 0x2222_1111 }); // 2 words, 1 sent
    const state = try saveState(src);
    defer std.testing.allocator.free(state);

    const dst = try bootHandle(0x11);
    defer capi.ps1_destroy(dst);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_state(dst, state.ptr, state.len));
    const w = dst.cpu.bus.gpu.sink.worker orelse return error.NoWorker;
    try std.testing.expect(w.vram == &dst.cpu.bus.gpu.vram);

    gp0(dst, &.{0x4444_3333});
    const vram = try std.testing.allocator.alloc(u16, 1024 * 512);
    defer std.testing.allocator.free(vram);
    capi.ps1_copy_vram(dst, vram.ptr);
    try std.testing.expectEqual(@as(u16, 0x3333), vram[10]);
    try std.testing.expectEqual(@as(u16, 0x4444), vram[11]);
}

test "a state with a non-default draw env loads into a worker that carries the same env" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const src = try bootHandle(0x11);
    defer capi.ps1_destroy(src);
    gp0(src, &.{ 0xE3000000 | (5 << 10) | 7, 0xE4000000 | (300 << 10) | 200, 0xE5000000 | (3 << 11) | 4 });
    const state = try saveState(src);
    defer std.testing.allocator.free(state);

    const dst = try bootHandle(0x11);
    defer capi.ps1_destroy(dst);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_state(dst, state.ptr, state.len));
    const gpu = &dst.cpu.bus.gpu;
    const w = gpu.sink.worker orelse return error.NoWorker;
    try std.testing.expect(!std.meta.eql(gpu.draw_env, @TypeOf(gpu.draw_env){}));
    try std.testing.expect(std.meta.eql(gpu.draw_env, w.env));
}

test "a refused load keeps the running machine's worker" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    const state = try saveState(h);
    defer std.testing.allocator.free(state);
    state[100] ^= 0xFF;

    const before = h.cpu.bus.gpu.sink.worker;
    try std.testing.expectEqual(capi.PS1_ERR_STATE_CORRUPT, capi.ps1_load_state(h, state.ptr, state.len));
    try std.testing.expect(h.cpu.bus.gpu.sink.worker == before);
    queueRedFill(h);
    const vram = try std.testing.allocator.alloc(u16, 1024 * 512);
    defer std.testing.allocator.free(vram);
    capi.ps1_copy_vram(h, vram.ptr);
    try std.testing.expectEqual(@as(u16, 0x001F), vram[0]);
}

test "a reset with draws queued comes back on a fresh worker thread" {
    if (!ps1_core.gpu.raster_worker_available) return error.SkipZigTest;
    const h = try bootHandle(0x11);
    defer capi.ps1_destroy(h);
    try deferWorker(h);
    for (0..100) |_| queueRedFill(h);
    capi.ps1_reset(h);
    const w = h.cpu.bus.gpu.sink.worker orelse return error.NoWorker;
    try std.testing.expect(w.thread != null);
    try std.testing.expect(w.vram == &h.cpu.bus.gpu.vram);
}

/// SCPH-1001 if the repo has it (gitignored), else null and the test skips.
fn repoBios() ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, "SCPH-1001_BIOS_1995_US.bin", std.testing.allocator, .limited(1 << 20)) catch null;
}

/// Eight sectors with nothing but the licence string at LBA 4: the least a
/// disc can carry and still be a PlayStation disc to fast boot.
var licensed_disc: [8 * 2352]u8 = blk: {
    var image: [8 * 2352]u8 = @splat(0);
    const license = "          Licensed  by          Sony Computer Entertainment Amer  ica ";
    image[4 * 2352 + 15] = 0x02; // Mode 2: user data starts at 018h
    @memcpy(image[4 * 2352 + 24 ..][0..license.len], license);
    break :blk image;
};

/// The same eight sectors with no licence: an audio CD as far as the BIOS is
/// concerned, so the shell (and its CD player) is what it should boot to.
var unlicensed_disc: [8 * 2352]u8 = @splat(0);

test "fast boot patches only once a disc is in, whichever was loaded first" {
    const image = repoBios() orelse return error.SkipZigTest;
    defer std.testing.allocator.free(image);
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_fast_boot(h, 1);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h, image.ptr, image.len));
    try std.testing.expect(h.bus.bios_patch == null); // no disc: the shell is all there is

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &licensed_disc, licensed_disc.len, null, 0, null, 0, null, 0));
    try std.testing.expectEqual(@as(u32, 0x6ff0), (h.bus.bios_patch orelse return error.NotPatched).offset);

    // The reverse order: disc first, then the BIOS.
    const h2 = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h2);
    capi.ps1_set_fast_boot(h2, 1);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h2, &licensed_disc, licensed_disc.len, null, 0, null, 0, null, 0));
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_bios(h2, image.ptr, image.len));
    try std.testing.expect(h2.bus.bios_patch != null);
}

test "fast boot survives a reset, and turning it off restores the image on the next one" {
    const image = repoBios() orelse return error.SkipZigTest;
    defer std.testing.allocator.free(image);
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_fast_boot(h, 1);
    _ = capi.ps1_load_bios(h, image.ptr, image.len);
    _ = capi.ps1_load_disc(h, &licensed_disc, licensed_disc.len, null, 0, null, 0, null, 0);
    capi.ps1_reset(h);
    try std.testing.expect(h.bus.bios_patch != null);

    capi.ps1_set_fast_boot(h, 0);
    try std.testing.expect(h.bus.bios_patch != null); // not until the next boot
    capi.ps1_reset(h);
    try std.testing.expect(h.bus.bios_patch == null);
    try std.testing.expectEqualSlices(u8, image, &h.bus.bios);
}

test "an unrecognised BIOS with fast boot on boots in full" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    var image: [512 * 1024]u8 = @splat(0x5a);

    capi.ps1_set_fast_boot(h, 1);
    _ = capi.ps1_load_bios(h, &image, image.len);
    _ = capi.ps1_load_disc(h, &licensed_disc, licensed_disc.len, null, 0, null, 0, null, 0);
    try std.testing.expect(h.bus.bios_patch == null);
    try std.testing.expectEqualSlices(u8, &image, &h.bus.bios);
}

test "a state saved with fast boot on loads with it off" {
    const image = repoBios() orelse return error.SkipZigTest;
    defer std.testing.allocator.free(image);
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_fast_boot(h, 1);
    _ = capi.ps1_load_bios(h, image.ptr, image.len);
    _ = capi.ps1_load_disc(h, &licensed_disc, licensed_disc.len, null, 0, null, 0, null, 0);
    capi.ps1_run_frame(h);

    const size = capi.ps1_save_state_size(h);
    const state = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(state);
    var written: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_save_state(h, state.ptr, state.len, &written));

    capi.ps1_set_fast_boot(h, 0);
    capi.ps1_reset(h);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_state(h, state.ptr, written));
}

test "ps1_identify_bios zeroes out and returns 0 for a buffer of the wrong size" {
    var out: capi.Ps1BiosId = .{ .region = 9, .description = @splat('x'), .version = @splat('x'), .models = @splat('x') };
    var short: [1024]u8 = @splat(0);
    try std.testing.expectEqual(@as(u8, 0), capi.ps1_identify_bios(&short, short.len, &out));
    try std.testing.expectEqual(@as(u8, 0), out.region);
    try std.testing.expectEqual(@as(u8, 0), out.description[0]);
    try std.testing.expectEqual(@as(u8, 0), out.models[0]);
}

test "ps1_identify_bios names SCPH-1001" {
    const image = repoBios() orelse return error.SkipZigTest;
    defer std.testing.allocator.free(image);
    var out: capi.Ps1BiosId = undefined;
    try std.testing.expectEqual(@as(u8, 1), capi.ps1_identify_bios(image.ptr, image.len, &out));
    try std.testing.expectEqual(@as(u8, 1), out.region); // PS1_REGION_AMERICA
    try std.testing.expectEqualStrings("SCPH-1001, 5003, DTL-H1201, H3001 (v2.2 12-04-95 A)", std.mem.sliceTo(&out.description, 0));
    try std.testing.expectEqualStrings("2.2", std.mem.sliceTo(&out.version, 0));
    try std.testing.expectEqualStrings("SCPH-1001,SCPH-5003,DTL-H1201,DTL-H3001", std.mem.sliceTo(&out.models, 0));
}

test "fast boot leaves the shell alone for a disc that is not a PlayStation disc" {
    const image = repoBios() orelse return error.SkipZigTest;
    defer std.testing.allocator.free(image);
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    capi.ps1_set_fast_boot(h, 1);
    _ = capi.ps1_load_bios(h, image.ptr, image.len);
    _ = capi.ps1_load_disc(h, &unlicensed_disc, unlicensed_disc.len, null, 0, null, 0, null, 0);
    try std.testing.expect(h.bus.bios_patch == null);
    try std.testing.expectEqualSlices(u8, image, &h.bus.bios);
}

const chd_dir = "ps1-core/tests/chd/";

fn fixture(name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(std.testing.allocator, chd_dir ++ "{s}", .{name});
    defer std.testing.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
}

fn expectSectorsOf(h: *capi.Handle, bin: []const u8) !void {
    const d = h.cpu.bus.cdrom.disc orelse return error.NoDisc;
    var got: [2352]u8 = undefined;
    var lba: i32 = 0;
    while (lba < bin.len / 2352) : (lba += 1) {
        try std.testing.expect(d.readSector2352(lba, &got));
        try std.testing.expectEqualSlices(u8, bin[@as(usize, @intCast(lba)) * 2352 ..][0..2352], &got);
    }
}

test "load_disc opens a CHD passed as bin, and swap replaces its reader" {
    const a = std.testing.allocator;
    const bin = try fixture("disc.bin");
    defer a.free(bin);
    const zl = try fixture("disc-cdzl.chd");
    defer a.free(zl);
    const fl = try fixture("disc-cdfl.chd");
    defer a.free(fl);

    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, zl.ptr, zl.len, null, 0, null, 0, null, 0));
    try std.testing.expect(h.chd != null);
    try expectSectorsOf(h, bin);

    try std.testing.expectEqual(@as(i32, 0), capi.ps1_swap_disc(h, fl.ptr, fl.len, null, 0, null, 0, null, 0));
    try expectSectorsOf(h, bin);

    // A flat image after a CHD leaves no reader behind.
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, bin.ptr, bin.len, null, 0, null, 0, null, 0));
    try std.testing.expect(h.chd == null);
}

test "a CHD the core refuses leaves the machine as it was" {
    const a = std.testing.allocator;
    const zl = try fixture("disc-cdzl.chd");
    defer a.free(zl);
    const v4 = try a.dupe(u8, zl);
    defer a.free(v4);
    v4[15] = 4; // version 5 -> 4

    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, zl.ptr, zl.len, null, 0, null, 0, null, 0));
    const before = h.chd;
    try std.testing.expectEqual(@as(i32, -15), capi.ps1_load_disc(h, v4.ptr, v4.len, null, 0, null, 0, null, 0));
    try std.testing.expectEqual(before, h.chd);
    // A cue never travels with CHD bytes.
    const cue = "FILE \"x.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n";
    try std.testing.expectEqual(@as(i32, -15), capi.ps1_load_disc(h, zl.ptr, zl.len, cue.ptr, cue.len, null, 0, null, 0));
}

test "identify answers the same for a CHD as for its bin, and refuses a bad CHD" {
    const a = std.testing.allocator;
    const bin = try fixture("disc.bin");
    defer a.free(bin);
    const def = try fixture("disc-default.chd");
    defer a.free(def);
    var flat: capi.Ps1DiscId = undefined;
    var packed_id: capi.Ps1DiscId = undefined;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_identify_disc(bin.ptr, bin.len, &flat));
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_identify_disc(def.ptr, def.len, &packed_id));
    try std.testing.expectEqual(flat, packed_id);

    def[15] = 4;
    try std.testing.expectEqual(@as(i32, -15), capi.ps1_identify_disc(def.ptr, def.len, &packed_id));
}

fn rewindHandle() !*capi.Handle {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    errdefer capi.ps1_destroy(h);
    try loadSpinBios(h);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_rewind_configure(h, 64 << 20));
    return h;
}

fn rewindInfo(h: *capi.Handle) capi.Ps1RewindInfo {
    var info: capi.Ps1RewindInfo = undefined;
    capi.ps1_rewind_info(h, &info);
    return info;
}

fn drainAudio(h: *capi.Handle) void {
    var out: [8192]f32 = undefined;
    while (capi.ps1_read_audio(h, &out, out.len) > 0) {}
}

test "rewind captures every two frames, and a step returns to the older capture" {
    const h = try rewindHandle();
    defer capi.ps1_destroy(h);

    var at_seven: []u8 = &.{};
    defer std.testing.allocator.free(at_seven);
    for (1..11) |frame| {
        capi.ps1_run_frame(h);
        if (frame == 7) {
            drainAudio(h);
            at_seven = try saveState(h);
        }
    }
    const info = rewindInfo(h);
    try std.testing.expectEqual(@as(u32, 4), info.entries);
    try std.testing.expectEqual(@as(u32, 8), info.frames_covered);

    // Back to the capture at frame 8, then the one at frame 6, and the frame
    // the host runs from there is frame 7 again, capturing nothing.
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_rewind_step(h));
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_rewind_step(h));
    capi.ps1_run_frame(h);
    drainAudio(h);
    const now = try saveState(h);
    defer std.testing.allocator.free(now);
    try std.testing.expectEqualSlices(u8, at_seven, now);
    try std.testing.expectEqual(@as(u32, 2), rewindInfo(h).entries);
}

test "a rewind step with no history is NO_HISTORY and changes nothing" {
    const h = try rewindHandle();
    defer capi.ps1_destroy(h);
    capi.ps1_run_frame(h);
    const before = try saveState(h);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(capi.PS1_ERR_NO_HISTORY, capi.ps1_rewind_step(h));
    const after = try saveState(h);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "reset, load_state, load_disc, swap_disc and load_bios each clear the rewind history" {
    const bin: [2352]u8 = @splat(0);
    for (0..5) |which| {
        const h = try rewindHandle();
        defer capi.ps1_destroy(h);
        const state = try saveState(h);
        defer std.testing.allocator.free(state);
        for (0..6) |_| capi.ps1_run_frame(h);
        try std.testing.expect(rewindInfo(h).entries > 0);
        switch (which) {
            0 => capi.ps1_reset(h),
            1 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_state(h, state.ptr, state.len)),
            2 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0, null, 0)),
            3 => try std.testing.expectEqual(capi.PS1_OK, capi.ps1_swap_disc(h, &bin, bin.len, null, 0, null, 0, null, 0)),
            else => try loadSpinBios(h),
        }
        try std.testing.expectEqual(@as(u32, 0), rewindInfo(h).entries);
        try std.testing.expectEqual(capi.PS1_ERR_NO_HISTORY, capi.ps1_rewind_step(h));
    }
}

test "frames run between mark and return capture no rewind history" {
    const h = try rewindHandle();
    defer capi.ps1_destroy(h);
    for (0..2) |_| capi.ps1_run_frame(h);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_mark(h));
    for (0..6) |_| capi.ps1_run_frame(h);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_snapshot_return(h));
    try std.testing.expectEqual(@as(u32, 0), rewindInfo(h).entries);
    // And capture resumes on the real timeline.
    for (0..2) |_| capi.ps1_run_frame(h);
    try std.testing.expectEqual(@as(u32, 1), rewindInfo(h).entries);
}

test "rewind configured to 0 frees everything and captures nothing" {
    const h = try rewindHandle();
    defer capi.ps1_destroy(h);
    for (0..4) |_| capi.ps1_run_frame(h);
    try std.testing.expectEqual(capi.PS1_OK, capi.ps1_rewind_configure(h, 0));
    try std.testing.expectEqual(@as(usize, 0), rewindInfo(h).bytes_used);
    for (0..4) |_| capi.ps1_run_frame(h);
    try std.testing.expectEqual(@as(u32, 0), rewindInfo(h).entries);
}
