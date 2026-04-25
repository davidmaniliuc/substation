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

test "GTE NCS (Normal Color Single) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Light Matrix (Identity Matrix: 4096 = 1.0)
    ctx.setCtrl(8, 0x00001000); // L11=4096, L12=0
    ctx.setCtrl(9, 0x00000000); // L13=0, L21=0
    ctx.setCtrl(10, 0x00001000); // L22=4096, L23=0
    ctx.setCtrl(11, 0x00000000); // L31=0, L32=0
    ctx.setCtrl(12, 0x00001000); // L33=4096

    // Light Color Matrix (Identity Matrix)
    ctx.setCtrl(16, 0x00001000); // LR1=4096, LR2=0
    ctx.setCtrl(17, 0x00000000); // LR3=0, LG1=0
    ctx.setCtrl(18, 0x00001000); // LG2=4096, LG3=0
    ctx.setCtrl(19, 0x00000000); // LB1=0, LB2=0
    ctx.setCtrl(20, 0x00001000); // LB3=4096

    // Background Color (Ambient Light) -> Slight Blue
    ctx.setCtrl(13, 0); // R
    ctx.setCtrl(14, 0); // G
    ctx.setCtrl(15, 100); // B

    // Set RGBC command byte to 0x30 (Polygon Draw Command)
    ctx.setData(6, 0x30000000);

    // Setup Vertex Normal V0 (Face pointing directly down the X axis)
    ctx.setData(0, (0 << 16) | 4096); // X=4096, Y=0
    ctx.setData(1, 0); // Z=0

    // Execute NCS (Command 0x1E, sf=0, lm=0)
    ctx.execute(0x4A00001E);

    // Read the resulting color from RGB2 (DataReg 22)
    const rgb2 = ctx.readData(22);

    // Red: Fully saturated by the X-axis normal (255)
    // Green: 0
    // Blue: 100 from Ambient Background Color
    // Code: 0x30 (Copied from RGBC)
    try expectEqual(@as(u8, 255), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 100), @as(u8, @truncate(rgb2 >> 16))); // B
    try expectEqual(@as(u8, 0x30), @as(u8, @truncate(rgb2 >> 24))); // CODE
}

test "GTE NCT (Normal Color Triple) execution and FIFO shift" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Matrices (Identity) and Background (Zero)
    ctx.setCtrl(8, 0x00001000);
    ctx.setCtrl(9, 0);
    ctx.setCtrl(10, 0x00001000);
    ctx.setCtrl(11, 0);
    ctx.setCtrl(12, 0x00001000); // Light Matrix

    ctx.setCtrl(16, 0x00001000);
    ctx.setCtrl(17, 0);
    ctx.setCtrl(18, 0x00001000);
    ctx.setCtrl(19, 0);
    ctx.setCtrl(20, 0x00001000); // Light Color Matrix

    ctx.setCtrl(13, 0);
    ctx.setCtrl(14, 0);
    ctx.setCtrl(15, 0); // Background Color

    ctx.setData(6, 0x38000000); // Command Code

    // 3 Vertex Normals pointing in different axes
    // V0: Points X -> Should become pure Red
    ctx.setData(0, (0 << 16) | 4096);
    ctx.setData(1, 0);
    // V1: Points Y -> Should become pure Green
    ctx.setData(2, (4096 << 16) | 0);
    ctx.setData(3, 0);
    // V2: Points Z -> Should become pure Blue
    ctx.setData(4, (0 << 16) | 0);
    ctx.setData(5, 4096);

    // Execute NCT (Command 0x20, sf=0, lm=0)
    ctx.execute(0x4A000020);

    // Because NCT processes V0, then V1, then V2, they get pushed into the FIFO in that order.
    // Therefore: RGB0 holds V0, RGB1 holds V1, RGB2 holds V2.
    const rgb0 = ctx.readData(20);
    const rgb1 = ctx.readData(21);
    const rgb2 = ctx.readData(22);

    // Check V0 (RGB0) -> Red
    try expectEqual(@as(u32, 0x380000FF), rgb0);

    // Check V1 (RGB1) -> Green
    try expectEqual(@as(u32, 0x3800FF00), rgb1);

    // Check V2 (RGB2) -> Blue
    try expectEqual(@as(u32, 0x38FF0000), rgb2);
}
