const std = @import("std");
const expectEqual = std.testing.expectEqual;

const zzssxx = @import("zzssxx");
const Cpu = zzssxx.cpu.Cpu;
const Bus = zzssxx.memory.Bus;

const TestContext = struct {
    bus: *Bus,
    cpu: Cpu,
    allocator: std.mem.Allocator,

    pub fn init() !TestContext {
        const allocator = std.testing.allocator;
        const bus = try Bus.init(allocator);
        var cpu = Cpu.init(bus);

        cpu.pc = 0x00000000;
        cpu.next_pc = 0x00000004;

        return TestContext{
            .bus = bus,
            .cpu = cpu,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestContext) void {
        self.bus.deinit(self.allocator);
    }

    pub fn execute(self: *TestContext, instruction: u32) void {
        self.bus.write32(self.cpu.pc, instruction);
        self.cpu.step();
    }

    pub fn setCtrl(self: *TestContext, index: u5, value: u32) void {
        self.cpu.cop2.writeCtrl(index, value);
    }

    pub fn setData(self: *TestContext, index: u5, value: u32) void {
        self.cpu.cop2.writeData(index, value);
    }

    pub fn readData(self: *const TestContext, index: u5) u32 {
        return self.cpu.cop2.readData(index);
    }
};

test "GTE MTC2/MFC2 and register quirks" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // MTC2 $a0, DataReg 1 (vz0)
    ctx.cpu.writeReg(.a0, 0x0000ABCD);
    ctx.execute(0x48840800);
    try expectEqual(@as(u32, 0xFFFFABCD), ctx.readData(1));

    // MFC2 $t0, DataReg 1 (vz0)
    ctx.execute(0x48080800);
    try expectEqual(@as(u32, 0xFFFFABCD), ctx.cpu.readReg(.t0));

    // MTC2 $a0, DataReg 30 (lzcs)
    ctx.cpu.writeReg(.a0, 0x000000FF);
    ctx.execute(0x4884F000);
    try expectEqual(@as(u32, 24), ctx.readData(31));

    ctx.cpu.writeReg(.a0, 0xFFFFFF00);
    ctx.execute(0x4884F000);
    try expectEqual(@as(u32, 24), ctx.readData(31));
}

test "GTE MVMVA execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(0, 0x00000001);
    ctx.setCtrl(1, 0x00000000);
    ctx.setCtrl(2, 0x00000001);
    ctx.setCtrl(3, 0x00000000);
    ctx.setCtrl(4, 0x00000001);
    ctx.setCtrl(5, 0);
    ctx.setCtrl(6, 0);
    ctx.setCtrl(7, 0);

    ctx.setData(0, 0x0014000A);
    ctx.setData(1, 30);

    ctx.execute(0x4A000012);

    try expectEqual(@as(u32, 10), ctx.readData(9));
    try expectEqual(@as(u32, 20), ctx.readData(10));
    try expectEqual(@as(u32, 30), ctx.readData(11));
}

test "GTE SXYP FIFO Shift and NCLIP execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Load up the FIFO via SXYP (Reg 15). Note: Y is high word, X is low word.
    ctx.setData(15, (10 << 16) | 10); // Point 0: (10, 10)
    ctx.setData(15, (10 << 16) | 20); // Point 1: (20, 10)
    ctx.setData(15, (20 << 16) | 10); // Point 2: (10, 20)

    // Verify the FIFO shifted correctly
    try expectEqual(@as(u32, (10 << 16) | 10), ctx.readData(12)); // SXY0
    try expectEqual(@as(u32, (10 << 16) | 20), ctx.readData(13)); // SXY1
    try expectEqual(@as(u32, (20 << 16) | 10), ctx.readData(14)); // SXY2

    // Execute NCLIP (Opcode 0x14000006 in standard form, real command is 0x06)
    ctx.execute(0x4A000006);

    // The cross product of these coordinates forms a clockwise triangle.
    // Result should be 100. Check MAC0 (Reg 24).
    try expectEqual(@as(u32, 100), ctx.readData(24));
}

test "GTE RTPS and Divide" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Set RT matrix to Identity (4096 = 1.0)
    ctx.setCtrl(0, 0x00001000); // RT11=4096, RT12=0
    ctx.setCtrl(1, 0x00000000); // RT13=0, RT21=0
    ctx.setCtrl(2, 0x00001000); // RT22=4096, RT23=0
    ctx.setCtrl(3, 0x00000000); // RT31=0, RT32=0
    ctx.setCtrl(4, 0x00001000); // RT33=4096

    // Set TR vector to zero
    ctx.setCtrl(5, 0);
    ctx.setCtrl(6, 0);
    ctx.setCtrl(7, 0);

    // Set OFX, OFY to zero, H to 512
    ctx.setCtrl(24, 0); // OFX
    ctx.setCtrl(25, 0); // OFY
    ctx.setCtrl(26, 512); // H

    // Load V0: (16, 32, 1024)
    ctx.setData(0, (32 << 16) | 16);
    ctx.setData(1, 1024);

    // Execute RTPS (SF=1 => shift by 12)
    ctx.execute(0x4A080001);

    // SZ3 should be 1024
    try expectEqual(@as(u32, 1024), ctx.readData(19));

    // Let's see what SXY2 is.
    const sxy2 = ctx.readData(14);
    const sx2 = @as(i16, @bitCast(@as(u16, @truncate(sxy2))));
    const sy2 = @as(i16, @bitCast(@as(u16, @truncate(sxy2 >> 16))));

    try expectEqual(@as(i16, 8), sx2);
    try expectEqual(@as(i16, 16), sy2);
}

test "GTE SQR (Square) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Load values into IR1, IR2, IR3 (DataRegs 9, 10, 11)
    ctx.setData(9, 10);
    ctx.setData(10, @as(u32, @bitCast(@as(i32, -20)))); // Test negative squaring
    ctx.setData(11, 30);

    // Execute SQR: sf=0 (no shift), lm=0. Command: 0x28
    ctx.execute(0x4A000028);

    // Verify MAC1, MAC2, MAC3 (DataRegs 25, 26, 27)
    try expectEqual(@as(u32, 100), ctx.readData(25));
    try expectEqual(@as(u32, 400), ctx.readData(26));
    try expectEqual(@as(u32, 900), ctx.readData(27));

    // Verify saturation back into IR1, IR2, IR3
    try expectEqual(@as(u32, 100), ctx.readData(9));
    try expectEqual(@as(u32, 400), ctx.readData(10));
    try expectEqual(@as(u32, 900), ctx.readData(11));
}

test "GTE AVSZ3 (Average Z3) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Load Z coordinates into SZ1, SZ2, SZ3 (DataRegs 17, 18, 19)
    ctx.setData(17, 100);
    ctx.setData(18, 200);
    ctx.setData(19, 300); // Sum = 600

    // Set ZSF3 (CtrlReg 29) to 4096 (represents 1.0 in fixed point)
    ctx.setCtrl(29, 4096);

    // Execute AVSZ3 (Command 0x2D)
    ctx.execute(0x4A00002D);

    // MAC0 (DataReg 24) should be Sum * ZSF3 (600 * 4096 = 2457600)
    try expectEqual(@as(u32, 2457600), ctx.readData(24));

    // OTZ (DataReg 7) should be MAC0 >> 12 (2457600 >> 12 = 600)
    try expectEqual(@as(u32, 600), ctx.readData(7));
}

test "GTE AVSZ4 (Average Z4) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Load Z coordinates into SZ0, SZ1, SZ2, SZ3 (DataRegs 16, 17, 18, 19)
    ctx.setData(16, 100);
    ctx.setData(17, 200);
    ctx.setData(18, 300);
    ctx.setData(19, 400); // Sum = 1000

    // Set ZSF4 (CtrlReg 30) to 4096 (1.0)
    ctx.setCtrl(30, 4096);

    // Execute AVSZ4 (Command 0x2E)
    ctx.execute(0x4A00002E);

    // MAC0 should be Sum * ZSF4 (1000 * 4096 = 4096000)
    try expectEqual(@as(u32, 4096000), ctx.readData(24));

    // OTZ should be 1000
    try expectEqual(@as(u32, 1000), ctx.readData(7));
}
