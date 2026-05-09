const std = @import("std");
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const Cpu = ps1_core.cpu.Cpu;
const Bus = ps1_core.memory.Bus;

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

    // Write to DataReg 1 (vz0) via MTC2
    ctx.cpu.writeReg(.a0, 0x0000ABCD);
    ctx.execute(0x48840800);
    try expectEqual(@as(u32, 0xFFFFABCD), ctx.readData(1)); // Should sign-extend

    // Read from DataReg 1 (vz0) via MFC2
    ctx.execute(0x48080800);
    try expectEqual(@as(u32, 0xFFFFABCD), ctx.cpu.readReg(.t0));

    // Write to DataReg 30 (lzcs) to trigger leading-zero count
    ctx.cpu.writeReg(.a0, 0x000000FF);
    ctx.execute(0x4884F000);
    try expectEqual(@as(u32, 24), ctx.readData(31)); // lzcr should hold 24

    ctx.cpu.writeReg(.a0, 0xFFFFFF00);
    ctx.execute(0x4884F000);
    try expectEqual(@as(u32, 24), ctx.readData(31));
}

test "GTE MVMVA execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Control Registers (Rotation Matrix and Translation Vector)
    ctx.setCtrl(0, 0x00000001); // RT11=1, RT12=0
    ctx.setCtrl(1, 0x00000000); // RT13=0, RT21=0
    ctx.setCtrl(2, 0x00000001); // RT22=1, RT23=0
    ctx.setCtrl(3, 0x00000000); // RT31=0, RT32=0
    ctx.setCtrl(4, 0x00000001); // RT33=1
    ctx.setCtrl(5, 0); // TRX=0
    ctx.setCtrl(6, 0); // TRY=0
    ctx.setCtrl(7, 0); // TRZ=0

    // Setup Data Registers (Vector 0)
    ctx.setData(0, 0x0014000A); // X=10, Y=20
    ctx.setData(1, 30); // Z=30

    // Execute MVMVA (Command 0x12, sf=0, lm=0)
    ctx.execute(0x4A000012);

    // Verify Results (IR1, IR2, IR3)
    try expectEqual(@as(u32, 10), ctx.readData(9));
    try expectEqual(@as(u32, 20), ctx.readData(10));
    try expectEqual(@as(u32, 30), ctx.readData(11));
}

test "GTE SXYP FIFO Shift and NCLIP execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Data Registers (SXYP FIFO)
    ctx.setData(15, (10 << 16) | 10); // Point 0: X=10, Y=10
    ctx.setData(15, (10 << 16) | 20); // Point 1: X=20, Y=10
    ctx.setData(15, (20 << 16) | 10); // Point 2: X=10, Y=20

    // Verify FIFO Shift
    try expectEqual(@as(u32, (10 << 16) | 10), ctx.readData(12)); // SXY0
    try expectEqual(@as(u32, (10 << 16) | 20), ctx.readData(13)); // SXY1
    try expectEqual(@as(u32, (20 << 16) | 10), ctx.readData(14)); // SXY2

    // Execute NCLIP (Command 0x06)
    ctx.execute(0x4A000006);

    // Verify Results (MAC0 holds cross product of clockwise triangle)
    try expectEqual(@as(u32, 100), ctx.readData(24));
}

test "GTE RTPS and Divide" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Control Registers (RT Matrix, TR Vector, OFX/OFY, H)
    ctx.setCtrl(0, 0x00001000); // RT11=4096 (1.0), RT12=0
    ctx.setCtrl(1, 0x00000000); // RT13=0, RT21=0
    ctx.setCtrl(2, 0x00001000); // RT22=4096 (1.0), RT23=0
    ctx.setCtrl(3, 0x00000000); // RT31=0, RT32=0
    ctx.setCtrl(4, 0x00001000); // RT33=4096 (1.0)
    ctx.setCtrl(5, 0); // TRX=0
    ctx.setCtrl(6, 0); // TRY=0
    ctx.setCtrl(7, 0); // TRZ=0
    ctx.setCtrl(24, 0); // OFX=0
    ctx.setCtrl(25, 0); // OFY=0
    ctx.setCtrl(26, 512); // H=512

    // Setup Data Registers (Vector 0)
    ctx.setData(0, (32 << 16) | 16); // X=16, Y=32
    ctx.setData(1, 1024); // Z=1024

    // Execute RTPS (Command 0x01, sf=1, lm=0)
    ctx.execute(0x4A080001);

    // Verify Results (SZ3, SXY2)
    try expectEqual(@as(u32, 1024), ctx.readData(19)); // SZ3

    const sxy2 = ctx.readData(14);
    const sx2 = @as(i16, @bitCast(@as(u16, @truncate(sxy2))));
    const sy2 = @as(i16, @bitCast(@as(u16, @truncate(sxy2 >> 16))));

    // Div = 4096 * (512 / 1024) = 2048
    // X = (16 * 2048) >> 12 = 8
    // Y = (32 * 2048) >> 12 = 16
    try expectEqual(@as(i16, 8), sx2);
    try expectEqual(@as(i16, 16), sy2);
}

test "GTE SQR (Square) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Data Registers (IR1, IR2, IR3)
    ctx.setData(9, 10);
    ctx.setData(10, @as(u32, @bitCast(@as(i32, -20))));
    ctx.setData(11, 30);

    // Execute SQR (Command 0x28, sf=0, lm=0)
    ctx.execute(0x4A000028);

    // Verify Results (MAC1-3 and saturated IR1-3)
    try expectEqual(@as(u32, 100), ctx.readData(25));
    try expectEqual(@as(u32, 400), ctx.readData(26));
    try expectEqual(@as(u32, 900), ctx.readData(27));

    try expectEqual(@as(u32, 100), ctx.readData(9));
    try expectEqual(@as(u32, 400), ctx.readData(10));
    try expectEqual(@as(u32, 900), ctx.readData(11));
}

test "GTE AVSZ3 (Average Z3) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Control Registers (ZSF3)
    ctx.setCtrl(29, 4096); // ZSF3=4096 (1.0)

    // Setup Data Registers (SZ FIFO)
    ctx.setData(17, 100); // SZ1
    ctx.setData(18, 200); // SZ2
    ctx.setData(19, 300); // SZ3 (Sum = 600)

    // Execute AVSZ3 (Command 0x2D)
    ctx.execute(0x4A00002D);

    // Verify Results (MAC0 and OTZ)
    try expectEqual(@as(u32, 2457600), ctx.readData(24)); // MAC0 = 600 * 4096
    try expectEqual(@as(u32, 600), ctx.readData(7)); // OTZ = MAC0 >> 12
}

test "GTE AVSZ4 (Average Z4) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Control Registers (ZSF4)
    ctx.setCtrl(30, 4096); // ZSF4=4096 (1.0)

    // Setup Data Registers (SZ FIFO)
    ctx.setData(16, 100); // SZ0
    ctx.setData(17, 200); // SZ1
    ctx.setData(18, 300); // SZ2
    ctx.setData(19, 400); // SZ3 (Sum = 1000)

    // Execute AVSZ4 (Command 0x2E)
    ctx.execute(0x4A00002E);

    // Verify Results (MAC0 and OTZ)
    try expectEqual(@as(u32, 4096000), ctx.readData(24)); // MAC0 = 1000 * 4096
    try expectEqual(@as(u32, 1000), ctx.readData(7)); // OTZ = MAC0 >> 12
}

test "GTE NCS (Normal Color Single) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Control Registers (Light Matrix, Light Color Matrix, Background)
    ctx.setCtrl(8, 0x00001000);
    ctx.setCtrl(9, 0x00000000);
    ctx.setCtrl(10, 0x00001000);
    ctx.setCtrl(11, 0x00000000);
    ctx.setCtrl(12, 0x00001000); // Light Matrix (Identity)

    ctx.setCtrl(16, 0x00001000);
    ctx.setCtrl(17, 0x00000000);
    ctx.setCtrl(18, 0x00001000);
    ctx.setCtrl(19, 0x00000000);
    ctx.setCtrl(20, 0x00001000); // Light Color Matrix (Identity)

    ctx.setCtrl(13, 0);
    ctx.setCtrl(14, 0);
    ctx.setCtrl(15, 100); // Background Color (Slight Blue)

    // Setup Data Registers (Command Code, Vector 0)
    ctx.setData(6, 0x30000000); // RGBC
    ctx.setData(0, (0 << 16) | 4096); // V0 (X=4096, Y=0)
    ctx.setData(1, 0); // V0 (Z=0)

    // Execute NCS (Command 0x1E, sf=0, lm=0)
    ctx.execute(0x4A00001E);

    // Verify Results (RGB2 out)
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 255), @as(u8, @truncate(rgb2))); // R (Saturated by X normal)
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 100), @as(u8, @truncate(rgb2 >> 16))); // B (From Background)
    try expectEqual(@as(u8, 0x30), @as(u8, @truncate(rgb2 >> 24))); // Code
}

test "GTE NCT (Normal Color Triple) execution and FIFO shift" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Control Registers (Light Matrix, Light Color Matrix, Background)
    ctx.setCtrl(8, 0x00001000);
    ctx.setCtrl(9, 0);
    ctx.setCtrl(10, 0x00001000);
    ctx.setCtrl(11, 0);
    ctx.setCtrl(12, 0x00001000); // Light Matrix (Identity)

    ctx.setCtrl(16, 0x00001000);
    ctx.setCtrl(17, 0);
    ctx.setCtrl(18, 0x00001000);
    ctx.setCtrl(19, 0);
    ctx.setCtrl(20, 0x00001000); // Light Color Matrix (Identity)

    ctx.setCtrl(13, 0);
    ctx.setCtrl(14, 0);
    ctx.setCtrl(15, 0); // Background Color (Zero)

    // Setup Data Registers (Command Code, Vectors 0-2)
    ctx.setData(6, 0x38000000);
    ctx.setData(0, (0 << 16) | 4096);
    ctx.setData(1, 0); // V0: Points X
    ctx.setData(2, (4096 << 16) | 0);
    ctx.setData(3, 0); // V1: Points Y
    ctx.setData(4, (0 << 16) | 0);
    ctx.setData(5, 4096); // V2: Points Z

    // Execute NCT (Command 0x20, sf=0, lm=0)
    ctx.execute(0x4A000020);

    // Verify Results (RGB0, RGB1, RGB2 out)
    const rgb0 = ctx.readData(20);
    const rgb1 = ctx.readData(21);
    const rgb2 = ctx.readData(22);

    try expectEqual(@as(u32, 0x380000FF), rgb0); // V0 -> Pure Red
    try expectEqual(@as(u32, 0x3800FF00), rgb1); // V1 -> Pure Green
    try expectEqual(@as(u32, 0x38FF0000), rgb2); // V2 -> Pure Blue
}

test "GTE DPCS (Depth Cueing Single) Fog Blending" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Control Registers (Far Color)
    ctx.setCtrl(21, 100); // RFC
    ctx.setCtrl(22, 100); // GFC
    ctx.setCtrl(23, 100); // BFC

    // Setup Data Registers (Command Code, Input Color, Fog Factor)
    ctx.setData(6, 0x30000000); // RGBC
    ctx.setData(20, 0x000000C8); // RGB0 (Original Color: Red 200)
    ctx.setData(8, 128); // IR0 (Fog Factor: 128/256 = 50%)

    // Execute DPCS (Command 0x10, sf=0, lm=0)
    ctx.execute(0x4A000010);

    // Verify Results (RGB2 out)
    const rgb2 = ctx.readData(22);

    // Expected: 50% blend between Red (200,0,0) and Fog (100,100,100)
    try expectEqual(@as(u8, 150), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb2 >> 16))); // B
    try expectEqual(@as(u8, 0x30), @as(u8, @truncate(rgb2 >> 24))); // Code
}

test "GTE DPCT (Depth Cueing Triple) Fog Blending" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Control Registers (Far Color)
    ctx.setCtrl(21, 100); // RFC
    ctx.setCtrl(22, 100); // GFC
    ctx.setCtrl(23, 100); // BFC

    // Setup Data Registers (Command Code, Input Colors, Fog Factor)
    ctx.setData(6, 0x30000000); // RGBC
    ctx.setData(20, 0x000000C8); // RGB0 (Pure Red)
    ctx.setData(21, 0x0000C800); // RGB1 (Pure Green)
    ctx.setData(22, 0x00C80000); // RGB2 (Pure Blue)
    ctx.setData(8, 128); // IR0 (Fog Factor: 128/256 = 50%)

    // Execute DPCT (Command 0x11, sf=0, lm=0)
    ctx.execute(0x4A000011);

    // Verify Results (RGB0, RGB1, RGB2 out)
    const rgb0 = ctx.readData(20);
    const rgb1 = ctx.readData(21);
    const rgb2 = ctx.readData(22);

    // RGB0 Expected: 50% blend between Red (200,0,0) and Fog (100,100,100)
    try expectEqual(@as(u8, 150), @as(u8, @truncate(rgb0)));
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb0 >> 8)));
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb0 >> 16)));
    try expectEqual(@as(u8, 0x30), @as(u8, @truncate(rgb0 >> 24)));

    // RGB1 Expected: 50% blend between Green (0,200,0) and Fog (100,100,100)
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb1)));
    try expectEqual(@as(u8, 150), @as(u8, @truncate(rgb1 >> 8)));
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb1 >> 16)));
    try expectEqual(@as(u8, 0x30), @as(u8, @truncate(rgb1 >> 24)));

    // RGB2 Expected: 50% blend between Blue (0,0,200) and Fog (100,100,100)
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb2)));
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb2 >> 8)));
    try expectEqual(@as(u8, 150), @as(u8, @truncate(rgb2 >> 16)));
    try expectEqual(@as(u8, 0x30), @as(u8, @truncate(rgb2 >> 24)));
}

test "GTE DCPL (Depth Cue Color Light) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Control Registers (Light Color Matrix, Background, Far Color)
    ctx.setCtrl(16, 0x00001000);
    ctx.setCtrl(17, 0x00000000);
    ctx.setCtrl(18, 0x00001000);
    ctx.setCtrl(19, 0x00000000);
    ctx.setCtrl(20, 0x00001000); // Light Color Matrix (Identity)

    ctx.setCtrl(13, 0);
    ctx.setCtrl(14, 0);
    ctx.setCtrl(15, 0); // Background Color (Black)
    ctx.setCtrl(21, 0);
    ctx.setCtrl(22, 0);
    ctx.setCtrl(23, 100); // Far Color (Fog Color: Blue 100)

    // Setup Data Registers (Command Code, Light Intensity, Fog Factor)
    ctx.setData(6, 0x30000000); // RGBC
    ctx.setData(9, 200); // IR1 (Red Intensity)
    ctx.setData(10, 0); // IR2
    ctx.setData(11, 0); // IR3
    ctx.setData(8, 2048); // IR0 (Fog Factor: 2048/4096 = 50%)

    // Execute DCPL (Command 0x29, sf=1, lm=0)
    ctx.execute(0x4A080029);

    // Verify Results (RGB2 out)
    const rgb2 = ctx.readData(22);

    // Expected: 50% blend between Light output (200,0,0) and Fog output (0,0,100)
    try expectEqual(@as(u8, 100), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb2 >> 16))); // B
    try expectEqual(@as(u8, 0x30), @as(u8, @truncate(rgb2 >> 24))); // Code
}

test "GTE NCDS (Normal Color Depth Cue Single) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Identity Matrices for Light and Light Color
    ctx.setCtrl(8, 0x00001000);
    ctx.setCtrl(10, 0x00001000);
    ctx.setCtrl(12, 0x00001000);
    ctx.setCtrl(16, 0x00001000);
    ctx.setCtrl(18, 0x00001000);
    ctx.setCtrl(20, 0x00001000);

    // Setup Far Color (Fog) to a distinct value
    ctx.setCtrl(21, 10); // RFC
    ctx.setCtrl(22, 20); // GFC
    ctx.setCtrl(23, 30); // BFC

    // Set Fog Factor to 0 (100% Fog) to completely replace the calculated color
    ctx.setData(8, 0); // IR0 = 0

    // Setup Input Vector (Points at X)
    ctx.setData(6, 0x13000000); // Command Code
    ctx.setData(0, (0 << 16) | 4096); // V0 (X=4096, Y=0)
    ctx.setData(1, 0); // V0 (Z=0)

    ctx.execute(0x4A000013); // Execute NCDS

    // Because IR0 is 0 (100% fog), the output should be exactly the Far Color
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 10), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 20), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 30), @as(u8, @truncate(rgb2 >> 16))); // B
}

test "GTE NCCS (Normal Color Color Single) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Identity Matrices
    ctx.setCtrl(8, 0x00001000);
    ctx.setCtrl(10, 0x00001000);
    ctx.setCtrl(12, 0x00001000);
    ctx.setCtrl(16, 0x00001000);
    ctx.setCtrl(18, 0x00001000);
    ctx.setCtrl(20, 0x00001000);

    // Setup Input Vector (Lighting calculates Pure Red: 255, 0, 0)
    ctx.setData(0, (0 << 16) | 4096);
    ctx.setData(1, 0);

    // Setup Vertex Color in RGBC (Modulation color: 128, 64, 32)
    ctx.setData(6, 0x1B204080);

    ctx.execute(0x4A00001B); // Execute NCCS

    // Expected: (255 * 128)/255 = 128 for R. Others remain 0.
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 128), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 16))); // B
}

test "GTE CDP (Color Depth Cue) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup existing color in IR registers (Scaled by 16 as per hardware specs)
    ctx.setData(9, 128 * 16); // IR1
    ctx.setData(10, 64 * 16); // IR2
    ctx.setData(11, 32 * 16); // IR3

    // Setup Far Color and 100% Fog
    ctx.setCtrl(21, 10);
    ctx.setCtrl(22, 10);
    ctx.setCtrl(23, 10); // FC = (10, 10, 10)
    ctx.setData(8, 0); // IR0 = 0 (Full fog)
    ctx.setData(6, 0x14000000); // Command code

    ctx.execute(0x4A000014); // Execute CDP

    // Output should be entirely the Far Color due to full fog
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 10), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 10), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 10), @as(u8, @truncate(rgb2 >> 16))); // B
}

test "GTE CC (Color Color) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup Identity Light Color Matrix
    ctx.setCtrl(16, 0x00001000);
    ctx.setCtrl(18, 0x00001000);
    ctx.setCtrl(20, 0x00001000);

    // Setup RGBC input color (10, 10, 10)
    ctx.setData(6, 0x1C0A0A0A);

    ctx.execute(0x4A00001C); // Execute CC

    // Math: Color * 16 * 4096 (Identity) >> 12 = Color * 16
    // Output R: 10 * 16 = 160
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 160), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 160), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 160), @as(u8, @truncate(rgb2 >> 16))); // B
}

test "GTE INTPL (Color Interpolation) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup base color in IR (128, 64, 32)
    ctx.setData(9, 128);
    ctx.setData(10, 64);
    ctx.setData(11, 32);

    // Setup target color in FC (100, 100, 100)
    ctx.setCtrl(21, 100);
    ctx.setCtrl(22, 100);
    ctx.setCtrl(23, 100);

    // 50% Interpolation factor (2048 / 4096)
    ctx.setData(8, 2048);
    ctx.setData(6, 0x22000000);

    ctx.execute(0x4A000022); // Execute INTPL

    // Expect halfway between IR and FC
    // R: 128 + (100 - 128) * 0.5 = 114
    // G: 64 + (100 - 64) * 0.5 = 82
    // B: 32 + (100 - 32) * 0.5 = 66
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 114), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 82), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 66), @as(u8, @truncate(rgb2 >> 16))); // B
}

test "GTE GPL (General Purpose Interpolate with Accumulation)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Pre-load MACs with baseline values
    ctx.setData(25, 100000); // MAC1
    ctx.setData(26, 200000); // MAC2
    ctx.setData(27, 300000); // MAC3

    // 2. Setup IR values
    ctx.setData(8, 2048); // IR0
    ctx.setData(9, 100); // IR1
    ctx.setData(10, 200); // IR2
    ctx.setData(11, 300); // IR3
    ctx.setData(6, 0x3E000000);

    ctx.execute(0x4A00003E); // Execute GPL (Accumulates)

    // MAC1 += 2048 * 100  (100000 + 204800 = 304800)
    // MAC2 += 2048 * 200  (200000 + 409600 = 609600)
    // MAC3 += 2048 * 300  (300000 + 614400 = 914400)
    try expectEqual(@as(u32, 304800), ctx.readData(25));
    try expectEqual(@as(u32, 609600), ctx.readData(26));
    try expectEqual(@as(u32, 914400), ctx.readData(27));

    // R = 304800 >> 12 = 74
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 74), @as(u8, @truncate(rgb2)));
}

test "GTE OP (Outer Product) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup RT Matrix (specifically column 3: RT13, RT23, RT33)
    ctx.setCtrl(1, 0x00000000); // RT13 = 0 (Low word)
    ctx.setCtrl(2, 0x10000000); // RT23 = 4096 (High word)
    ctx.setCtrl(4, 0x00000000); // RT33 = 0 (Low word)

    // Setup IR Vectors
    ctx.setData(9, 4096); // IR1 = 4096
    ctx.setData(10, 0); // IR2 = 0
    ctx.setData(11, 0); // IR3 = 0

    // Execute OP (Command 0x0C, sf=1, lm=0) -> sf=1 shifts by 12
    ctx.execute(0x4A08000C);

    // Cross product:
    // MAC1 = (IR2*RT33 - IR3*RT23) = 0
    // MAC2 = (IR3*RT13 - IR1*RT33) = 0
    // MAC3 = (IR1*RT23 - IR2*RT13) = 4096 * 4096 = 16777216

    try expectEqual(@as(u32, 0), ctx.readData(25)); // MAC1
    try expectEqual(@as(u32, 0), ctx.readData(26)); // MAC2
    try expectEqual(@as(u32, 16777216), ctx.readData(27)); // MAC3

    // Shifted by 12 and saturated to IR
    try expectEqual(@as(u32, 0), ctx.readData(9)); // IR1
    try expectEqual(@as(u32, 0), ctx.readData(10)); // IR2
    try expectEqual(@as(u32, 4096), ctx.readData(11)); // IR3
}

test "GTE GPF (General Purpose Interpolate) execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Setup IR Registers
    ctx.setData(8, 2048); // IR0 (Interpolation factor: 0.5)
    ctx.setData(9, 100); // IR1
    ctx.setData(10, 200); // IR2
    ctx.setData(11, 300); // IR3
    ctx.setData(6, 0x44000000); // Set RGBC command code to observe push

    // Execute GPF (Command 0x3D, sf=0, lm=0)
    ctx.execute(0x4A00003D);

    // MAC = IR0 * IR
    try expectEqual(@as(u32, 204800), ctx.readData(25)); // MAC1
    try expectEqual(@as(u32, 409600), ctx.readData(26)); // MAC2
    try expectEqual(@as(u32, 614400), ctx.readData(27)); // MAC3

    // Pushed to RGB (MAC >> 12)
    const rgb = ctx.readData(22);
    try expectEqual(@as(u8, 50), @as(u8, @truncate(rgb))); // R (204800 >> 12)
    try expectEqual(@as(u8, 100), @as(u8, @truncate(rgb >> 8))); // G
    try expectEqual(@as(u8, 150), @as(u8, @truncate(rgb >> 16))); // B
    try expectEqual(@as(u8, 0x44), @as(u8, @truncate(rgb >> 24))); // Code
}
