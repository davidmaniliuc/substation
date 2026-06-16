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

test "ACK does not leave a partially read response interrupt blocking the FIFO" {
    var cdrom = CdRom.init();
    var spu = Spu.init();

    var response: [8]u8 = undefined;
    _ = try runCommand(&cdrom, &spu, 0x11, 7, response[0..7]);

    cdrom.write(0, 1);
    try std.testing.expectEqual(@as(u8, 0x39), cdrom.read(0));
    cdrom.write(3, 0x1F);

    try std.testing.expectEqual(@as(u8, 0x19), cdrom.read(0));
    try std.testing.expectEqual(@as(u8, 0xE0), cdrom.read(3));
}
