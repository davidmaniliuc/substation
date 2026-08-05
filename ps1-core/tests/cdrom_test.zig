const std = @import("std");
const ps1_core = @import("ps1_core");

const CdRom = ps1_core.cdrom.CdRom;
const Spu = ps1_core.spu.Spu;
const Bus = ps1_core.memory.Bus;

test "CDROM interrupt flag auto-clears when response is drained" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    cdrom.write(0, 0);
    cdrom.write(1, 0x10); // GetlocL without a valid sector posts INT5.
    cdrom.step(50000, &spu);

    cdrom.write(0, 1);
    try std.testing.expectEqual(@as(u8, 0xE5), cdrom.read(3));

    cdrom.write(3, 0x5F);
    _ = cdrom.read(1);
    _ = cdrom.read(1);

    // Flag should auto-clear after reading the last response byte
    try std.testing.expectEqual(@as(u8, 0xE0), cdrom.read(3));
}

fn runCommand(cdrom: *CdRom, spu: *Spu, cmd: u8, response_len: usize, response: []u8) !u8 {
    cdrom.write(0, 0);
    cdrom.write(1, cmd);
    cdrom.step(50_000, spu);

    cdrom.write(0, 1);
    const irq = cdrom.read(3) & 7;
    cdrom.write(3, 0x5F);
    cdrom.write(3, 0x40);

    var i: usize = 0;
    while (i < response_len) : (i += 1) {
        response[i] = cdrom.read(1);
    }

    return irq;
}

test "GetlocP returns all 8 subchannel Q bytes after reset" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    var response: [8]u8 = undefined;
    const irq = try runCommand(&cdrom, &spu, 0x11, response.len, &response);

    try std.testing.expectEqual(@as(u8, 3), irq);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x01, 0x68 }, &response);
}

test "synthetic seek keeps GetlocP absolute MSF in BCD" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    cdrom.write(0, 0);
    cdrom.write(2, 0x00);
    cdrom.write(2, 0x02);
    cdrom.write(2, 0x16);
    var response: [8]u8 = undefined;
    _ = try runCommand(&cdrom, &spu, 0x02, 1, response[0..1]);

    _ = try runCommand(&cdrom, &spu, 0x15, 1, response[0..1]);
    cdrom.step(2_000_000, &spu);
    cdrom.write(0, 1);
    cdrom.write(3, 0x5F);
    cdrom.write(3, 0x40);
    _ = cdrom.read(1);

    const irq = try runCommand(&cdrom, &spu, 0x11, response.len, &response);

    try std.testing.expectEqual(@as(u8, 3), irq);
    try std.testing.expectEqual(@as(u8, 0x00), response[5]);
    try std.testing.expectEqual(@as(u8, 0x02), response[6]);
    try std.testing.expectEqual(@as(u8, 0x11), response[7]);
}

test "ReadN reports reading state after first response" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    var response: [1]u8 = undefined;
    const irq = try runCommand(&cdrom, &spu, 0x06, response.len, &response);

    try std.testing.expectEqual(@as(u8, 3), irq);
    try std.testing.expectEqual(@as(u8, 0x42), response[0]);
    try std.testing.expectEqual(@as(u8, 0x42), cdrom.read(1));
}

test "ReadN seek->read transition survives GetStat polling (root cause #2)" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    // ReadN: first response reports Seeking synchronously.
    var resp: [1]u8 = undefined;
    const irq = try runCommand(&cdrom, &spu, 0x06, 1, &resp);
    try std.testing.expectEqual(@as(u8, 3), irq);
    try std.testing.expectEqual(@as(u8, 0x42), resp[0]); // Seeking | motor

    // The getloc "waiting for read" poll loop issues repeated GetStat. Each
    // command clears irq_queue, so the Seeking->Reading transition must NOT be
    // encoded as a queued action — it has to be driven independently. Poll until
    // the drive reports Reading. Each runCommand advances 50_000 cycles.
    var last: u8 = resp[0];
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        _ = try runCommand(&cdrom, &spu, 0x01, 1, &resp); // GetStat
        last = resp[0];
        if ((last & 0x20) != 0) break; // Reading bit set
    }
    try std.testing.expectEqual(@as(u8, 0x22), last); // Reading | motor
}

test "wide CDROM status reads mirror the selected register without consuming responses" {
    const bus = try Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);
    var spu = Spu.init();

    bus.cdrom.write(0, 0);
    bus.cdrom.write(1, 0x11);
    bus.cdrom.step(50_000, &spu);

    bus.cdrom.write(0, 1);
    try std.testing.expectEqual(@as(u32, 0x39393939), bus.read32(0x1F801800));
    try std.testing.expectEqual(@as(u16, 0x3939), bus.read16(0x1F801800));

    var response: [8]u8 = undefined;
    bus.cdrom.write(3, 0x5F);
    bus.cdrom.write(3, 0x40);
    for (&response) |*byte| {
        byte.* = bus.cdrom.read(1);
    }

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x01, 0x68 }, &response);
}

test "ACK with unread response bytes keeps them readable (Avocado behavior)" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    var response: [8]u8 = undefined;
    _ = try runCommand(&cdrom, &spu, 0x11, 7, response[0..7]);

    // After reading 7 of 8 bytes, RSLRRDY should still be set (byte 7 unread)
    cdrom.write(0, 1);
    try std.testing.expectEqual(@as(u8, 0x39), cdrom.read(0)); // RSLRRDY set

    // ACK the interrupt — on real hardware/Avocado, this does NOT discard unread bytes
    cdrom.write(3, 0x1F);

    // RSLRRDY should still be set because byte 7 is still readable
    try std.testing.expectEqual(@as(u8, 0x39), cdrom.read(0));

    // Read the final byte — should be the 8th subchannel Q value (abs_f = 0x68)
    try std.testing.expectEqual(@as(u8, 0x68), cdrom.read(1));

    // NOW the response is fully consumed AND ACK'd, so interrupt is popped
    // RSLRRDY should be cleared and IRQ flags should be 0
    try std.testing.expectEqual(@as(u8, 0x19), cdrom.read(0));
    try std.testing.expectEqual(@as(u8, 0xE0), cdrom.read(3));
}

const InterruptController = ps1_core.interrupt.InterruptController;

test "updateInterrupts is level-triggered: re-asserts CPU IRQ while ready front item is unread" {
    var cdrom = CdRom.init();
    var ic = InterruptController{};

    cdrom.irq_enable = 0x1F;
    // A ready INT3 response with two bytes; the handler will read one, ack, and
    // expect the IRQ to be re-asserted so it can drain the remaining byte.
    cdrom.irq_queue.push(3, 0, &[_]u8{ 0x02, 0x68 });

    // First update asserts the CPU IRQ line.
    cdrom.updateInterrupts(&ic);
    try std.testing.expect((ic.stat & 4) != 0);

    // Software acks the CPU-side line and the front item but leaves a response
    // byte unread, so the item stays at the head of the queue.
    ic.stat = 0;
    if (cdrom.irq_queue.peekMut()) |item| {
        item.ack = true;
    }

    // Level-triggered: the IRQ must be re-asserted while the front item is still
    // ready and its IFR bit is enabled.
    cdrom.updateInterrupts(&ic);
    try std.testing.expect((ic.stat & 4) != 0);
}

/// Builds a minimal but structurally valid Mode-2 Form-2 XA sector.
/// Sound-unit headers live at group offset 4..11 and the 28 data words at
/// 0x10..0x7F, with block `b` occupying bit `b*4` of each little-endian word.
fn buildXaSector(submode: u8, coding: u8) [2352]u8 {
    var s = [_]u8{0} ** 2352;

    s[0] = 0x00;
    for (1..11) |i| s[i] = 0xFF;
    s[11] = 0x00;

    s[0x0C] = 0x00;
    s[0x0D] = 0x02;
    s[0x0E] = 0x00;
    s[0x0F] = 0x02; // mode 2

    // Subheader + its mandatory copy.
    s[0x10] = 1; // file
    s[0x11] = 1; // channel
    s[0x12] = submode;
    s[0x13] = coding;
    s[0x14] = 1;
    s[0x15] = 1;
    s[0x16] = submode;
    s[0x17] = coding;

    var g: usize = 0;
    while (g < 18) : (g += 1) {
        const base = 0x18 + g * 128;
        // shift=8, filter=0 for all 8 sound units
        for (0..8) |b| s[base + 4 + b] = 0x08;
        for (0..28) |n| {
            for (0..4) |byte| {
                // Distinct nibbles per block so the two channels cannot alias.
                const lo: u8 = @truncate((byte * 2 + n) & 0x0F);
                const hi: u8 = @truncate((byte * 2 + 1 + n * 3) & 0x0F);
                s[base + 0x10 + n * 4 + byte] = lo | (hi << 4);
            }
        }
    }
    return s;
}

test "XA audio sectors are detected from submode audio|form2|realtime bits" {
    const cdrom = CdRom.init();
    // Croc's XA sectors carry submode 0x64: audio(0x04)|form2(0x20)|realtime(0x40).
    const sector = buildXaSector(0x64, 0x01);
    try std.testing.expect(cdrom.isXaAudioSector(&sector));

    // A plain data sector (data bit only) must not be mistaken for audio.
    const data_sector = buildXaSector(0x08, 0x01);
    try std.testing.expect(!cdrom.isXaAudioSector(&data_sector));
}

test "stereo XA sector decodes into both FIFO channels resampled to 44100Hz" {
    var cdrom = CdRom.init();
    const sector = buildXaSector(0x64, 0x01); // stereo, 37800Hz, 4-bit

    cdrom.playXaAudioSector(&sector);

    // 18 groups * 4 blocks/channel * 28 samples = 2016 samples/channel at
    // 37800Hz; the 6->7 zigzag resampler turns that into 2352 at 44100Hz.
    try std.testing.expectEqual(@as(usize, 2352), cdrom.audio_fifo_write);

    var left_nonzero: usize = 0;
    var channels_differ: usize = 0;
    for (0..2352) |i| {
        if (cdrom.audio_fifo_l[i] != 0) left_nonzero += 1;
        if (cdrom.audio_fifo_l[i] != cdrom.audio_fifo_r[i]) channels_differ += 1;
    }
    // Both channels must carry real, independently decoded audio.
    try std.testing.expect(left_nonzero > 2000);
    try std.testing.expect(channels_differ > 2000);
}

test "XA decode matches the Avocado reference sample-for-sample" {
    var cdrom = CdRom.init();
    const sector = buildXaSector(0x64, 0x01);

    cdrom.playXaAudioSector(&sector);

    // Golden values produced by an independent transcription of Avocado's
    // ADPCM::decodePacket + interpolate + doZigzag over the same input.
    const want_l_head = [_]i16{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, -1 };
    const want_r_head = [_]i16{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, -5, 14 };
    for (want_l_head, 0..) |want, i| {
        try std.testing.expectEqual(want, cdrom.audio_fifo_l[i]);
    }
    for (want_r_head, 0..) |want, i| {
        try std.testing.expectEqual(want, cdrom.audio_fifo_r[i]);
    }

    const want_l_mid = [_]i16{ -63, -55, -42, -29, -16, -4 };
    for (want_l_mid, 0..) |want, i| {
        try std.testing.expectEqual(want, cdrom.audio_fifo_l[1000 + i]);
    }

    const want_r_tail = [_]i16{ -14, 12, 88, -38, -128, -42 };
    for (want_r_tail, 0..) |want, i| {
        try std.testing.expectEqual(want, cdrom.audio_fifo_r[2340 + i]);
    }
}
