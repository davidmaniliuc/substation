const std = @import("std");
const capi = @import("root.zig");
const ps1_core = @import("ps1_core");
const Precise = ps1_core.pgxp.Precise;

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

    const short = [_]u8{0} ** 16;
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

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(
        @as(i32, -3),
        capi.ps1_load_disc(h, &bin, bin.len, multi_file_cue.ptr, multi_file_cue.len, null, 0),
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

    const bin = [_]u8{0} ** (2352 * 150);
    try std.testing.expectEqual(
        @as(i32, 0),
        capi.ps1_load_disc(h, &bin, bin.len, laid_out_multi_file_cue.ptr, laid_out_multi_file_cue.len, null, 0),
    );
    // Track 2 is placed past the first image, not stacked on top of it: its
    // FILE begins at LBA 100 and INDEX 01 sits 150 frames further in.
    try std.testing.expectEqual(@as(u8, 2), h.disc.?.track_count);
    try std.testing.expectEqual(@as(i32, 250), h.disc.?.tracks[1].start_lba);
}

test "load_disc rejects a cue with no FILE directive" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    const junk = "this is not a cue sheet\n";
    try std.testing.expectEqual(
        @as(i32, -2),
        capi.ps1_load_disc(h, &bin, bin.len, junk.ptr, junk.len, null, 0),
    );
}

test "load_disc accepts a single-FILE cue and attaches the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(
        @as(i32, 0),
        capi.ps1_load_disc(h, &bin, bin.len, single_file_cue.ptr, single_file_cue.len, null, 0),
    );
    try std.testing.expect(h.disc != null);
    try std.testing.expectEqual(@as(u8, 1), h.disc.?.track_count);
}

test "load_disc with no cue takes the raw .bin fallback" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0));
    try std.testing.expect(h.disc != null);
    try std.testing.expectEqual(@as(u8, 1), h.disc.?.track_count);
}

test "load_disc rejects an empty image" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const empty = [_]u8{};
    try std.testing.expectEqual(@as(i32, -2), capi.ps1_load_disc(h, &empty, 0, null, 0, null, 0));
}

test "reset re-attaches the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0));
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
    try std.testing.expectEqual(@as(u16, 0xFFFF), h.cpu.bus.sio.buttons);

    capi.ps1_set_buttons(h, 0xFFF7);
    try std.testing.expectEqual(@as(u16, 0xFFF7), h.cpu.bus.sio.buttons);
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
    _ = h.cpu.bus.gpu.writeGp0(0xE1000200, Precise.none);

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

    _ = h.cpu.bus.gpu.writeGp0(0xE1000200, Precise.none);

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
        _ = h.cpu.bus.gpu.writeGp0(0xE1000200, Precise.none);
    }

    var s: capi.Ps1GpuStream = undefined;
    capi.ps1_take_frame_stream(h, &s);

    // The records present are a PREFIX, not a shorter frame. Applying a prefix
    // to a shadow VRAM leaves it permanently out of step with the rasterizer,
    // which is why the flag exists at all.
    try std.testing.expectEqual(@as(usize, cap), s.record_count);
    try std.testing.expectEqual(@as(u8, 0), s.complete);
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
    h.cpu.bus.pgxp_pending = Precise.make(4 << 16, 4 << 16);
    capi.ps1_set_pgxp(h, 0);
    try std.testing.expectEqual(@as(u32, 0), h.cpu.bus.pgxp_pending.valid);
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

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        single_file_cue.ptr,
        single_file_cue.len,
        ff9_sbi.ptr,
        ff9_sbi.len,
    ));
    try std.testing.expect(h.cpu.bus.cdrom.disc.?.isLibCryptSector(ff9LibCryptLba()));
}

test "the sidecar is copied, not borrowed from the caller" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    // Freed before the drive is asked about it: a borrowed sidecar reads
    // freed memory here, which is the whole reason the handle copies it.
    const sbi = try std.testing.allocator.dupe(u8, ff9_sbi);
    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        null,
        0,
        sbi.ptr,
        sbi.len,
    ));
    std.testing.allocator.free(sbi);

    try std.testing.expect(h.cpu.bus.cdrom.disc.?.isLibCryptSector(ff9LibCryptLba()));
}

test "reset re-attaches the sidecar along with the disc" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        null,
        0,
        ff9_sbi.ptr,
        ff9_sbi.len,
    ));
    capi.ps1_reset(h);

    try std.testing.expect(h.cpu.bus.cdrom.disc.?.isLibCryptSector(ff9LibCryptLba()));
}

test "loading a second disc drops the first one's sidecar" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        null,
        0,
        ff9_sbi.ptr,
        ff9_sbi.len,
    ));
    // A sidecar's records are addresses on the disc it shipped with, so one
    // left over from the previous disc flags sectors of this one at random.
    try std.testing.expectEqual(@as(i32, 0), capi.ps1_load_disc(h, &bin, bin.len, null, 0, null, 0));

    try std.testing.expect(!h.cpu.bus.cdrom.disc.?.isLibCryptSector(ff9LibCryptLba()));
}

test "a sidecar without the SBI magic is refused rather than parsed as records" {
    const h = capi.ps1_create() orelse return error.CreateFailed;
    defer capi.ps1_destroy(h);

    const junk = "NOTSBI\x00\x00" ++ "\x03\x08\x05\x01\x41\x01\x01\x07\x06\x05\x00\x23\x08\x05";
    const bin = [_]u8{0} ** 2352;
    try std.testing.expectEqual(@as(i32, -5), capi.ps1_load_disc(
        h,
        &bin,
        bin.len,
        null,
        0,
        junk.ptr,
        junk.len,
    ));
}
