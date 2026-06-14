const std = @import("std");
const ps1_core = @import("ps1_core");

const CdRom = ps1_core.cdrom.CdRom;
const Spu = ps1_core.spu.Spu;

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
