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
        cpu.cop0.writeReg(ps1_core.cpu.Cop0.Reg.sr, 1 << 30); // Enable COP2 (GTE)

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
        self.cpu.icache = [_]Cpu.CacheLine{.{}} ** 256;
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

/// Sets up an identity rotation matrix, zero translation and zero screen offset,
/// so that IR1/IR2/SZ3 come straight out of the input vector.
fn setupIdentityRtps(ctx: *TestContext, h: u32) void {
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
    ctx.setCtrl(26, h); // H
}

// The projection divide must cover the full hardware range of H/SZ3 (up to
// ~2.0), not just up to 1.0. Avocado clamps `H*10000h/SZ3` at 1FFFFh
// (opcodes.cpp:291 divideUNR); clamping a 17-fraction-bit quotient at the same
// value halves the usable range and collapses every vertex nearer than the
// projection plane. Silent Hill's indoor scenes are full of those.
test "GTE RTPS projects vertices closer than H (SZ3 < H)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    setupIdentityRtps(&ctx, 256);

    ctx.setData(0, (0 << 16) | 100); // VX0=100, VY0=0
    ctx.setData(1, 192); // VZ0=192  -> SZ3=192, i.e. H/SZ3 = 1.33

    ctx.execute(0x4A080001); // RTPS, sf=12, lm=0

    try expectEqual(@as(u32, 192), ctx.readData(19)); // SZ3

    // divideUNR(256, 192) == ((256*20000h/192)+1)/2 == 15555h == 87381
    // SX2 = (87381 * 100) >> 16 == 133
    const sxy2 = ctx.readData(14);
    const sx2 = @as(i16, @bitCast(@as(u16, @truncate(sxy2))));
    try expectEqual(@as(i16, 133), sx2);

    // FLAG bit 17 (divide overflow) must NOT be set: 192*2 > 256.
    try expectEqual(@as(u32, 0), ctx.cpu.cop2.readCtrl(31) & (1 << 17));
}

// RTPS must compute the depth-cueing accumulator:
//   MAC0 = (H/SZ3)*DQA + DQB ; IR0 = clamp(MAC0 >> 12, 0..1000h)
// (Avocado opcodes.cpp:360-363). IR0 is the fog/blend factor consumed by
// DPCS/DPCT/INTPL/NCDS/NCCS/GPF/GPL.
test "GTE RTPS computes IR0 from DQA/DQB" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    setupIdentityRtps(&ctx, 256);
    ctx.setCtrl(27, 100); // DQA
    ctx.setCtrl(28, 0); // DQB

    ctx.setData(0, (0 << 16) | 100); // VX0=100, VY0=0
    ctx.setData(1, 192); // VZ0=192

    ctx.execute(0x4A080001); // RTPS, sf=12, lm=0

    // MAC0 = 87381 * 100 + 0 = 8738100 ; IR0 = 8738100 >> 12 = 2133
    try expectEqual(@as(u32, 8738100), ctx.readData(24)); // MAC0
    try expectEqual(@as(u32, 2133), ctx.readData(8)); // IR0
}

// Captured from Silent Hill gameplay and cross-checked against Avocado's GTE.
// DPCS reads its colour from RGBC (data 6), *not* from the RGB0 FIFO, and is a
// two-stage op like INTPL:
//   stage 1: MAC = (FC << 12) - (colour << 12), IR = saturate(MAC), lm=0
//   stage 2: MAC = (colour << 12) + IR0 * IR
// Reading RGB0 (which the game leaves black here) made every depth-cued colour
// come out zero — Silent Hill's fog turned the whole scene into flat garbage.
test "GTE DPCS depth-cues the RGBC colour" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setData(6, 0x3c8a8079); // RGBC: code=3c b=8a g=80 r=79
    ctx.setData(8, 0xfffffe67); // IR0 = -409
    ctx.setData(20, 0x38000000); // RGB0 is black; DPCS must not read it
    ctx.setCtrl(21, 0); // FC r
    ctx.setCtrl(22, 0); // FC g
    ctx.setCtrl(23, 0); // FC b

    ctx.execute(0x4A780010); // DPCS, sf=12, lm=0

    try expectEqual(@as(u32, 0x00000851), ctx.readData(25)); // MAC1
    try expectEqual(@as(u32, 0x000008cc), ctx.readData(26)); // MAC2
    try expectEqual(@as(u32, 0x0000097c), ctx.readData(27)); // MAC3

    try expectEqual(@as(u32, 0x00000851), ctx.readData(9)); // IR1
    try expectEqual(@as(u32, 0x000008cc), ctx.readData(10)); // IR2
    try expectEqual(@as(u32, 0x0000097c), ctx.readData(11)); // IR3

    // Colour FIFO takes MAC >> 4, with the code byte carried from RGBC.
    try expectEqual(@as(u32, 0x3c978c85), ctx.readData(22)); // RGB2
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

// Expected values produced by Avocado's GTE for this exact register setup, not
// by an idealised "50%% blend" model. These two tests previously asserted a
// linear blend towards the far colour that the hardware does not compute; both
// are run at sf=12 (as games do) so the result is not simply saturated.
test "GTE DPCS (Depth Cueing Single) Fog Blending" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(21, 100); // RFC
    ctx.setCtrl(22, 100); // GFC
    ctx.setCtrl(23, 100); // BFC

    ctx.setData(6, 0x300000C8); // RGBC: code=0x30, red 200 — DPCS reads this
    ctx.setData(8, 128); // IR0

    ctx.execute(0x4A080010); // DPCS, sf=12, lm=0

    try expectEqual(@as(u32, 0x00000c1f), ctx.readData(25)); // MAC1
    try expectEqual(@as(u32, 0x00000003), ctx.readData(26)); // MAC2
    try expectEqual(@as(u32, 0x00000003), ctx.readData(27)); // MAC3

    try expectEqual(@as(u32, 0x00000c1f), ctx.readData(9)); // IR1
    try expectEqual(@as(u32, 0x00000003), ctx.readData(10)); // IR2
    try expectEqual(@as(u32, 0x00000003), ctx.readData(11)); // IR3

    try expectEqual(@as(u32, 0x300000c1), ctx.readData(22)); // RGB2
    try expectEqual(@as(u32, 0), ctx.cpu.cop2.readCtrl(31)); // no flags
}

test "GTE DPCT (Depth Cueing Triple) Fog Blending" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(21, 100); // RFC
    ctx.setCtrl(22, 100); // GFC
    ctx.setCtrl(23, 100); // BFC

    ctx.setData(6, 0x30000000); // RGBC (supplies the code byte)
    ctx.setData(20, 0x000000C8); // RGB0 - red
    ctx.setData(21, 0x0000C800); // RGB1 - green
    ctx.setData(22, 0x00C80000); // RGB2 - blue
    ctx.setData(8, 128); // IR0

    ctx.execute(0x4A08002A); // DPCT, sf=12, lm=0

    // Each pass reads RGB0 and pushes, so all three FIFO colours get cued in
    // order and end up back in the FIFO as red, green, blue.
    try expectEqual(@as(u32, 0x300000c1), ctx.readData(20));
    try expectEqual(@as(u32, 0x3000c100), ctx.readData(21));
    try expectEqual(@as(u32, 0x30c10000), ctx.readData(22));
    try expectEqual(@as(u32, 0), ctx.cpu.cop2.readCtrl(31)); // no flags
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

    ctx.execute(0x4A080011); // Execute INTPL, sf=1

    // MAC1..3 hold the halfway point between IR and FC (Avocado `setMac` applies
    // the sf shift *before* storing, so these are the shifted values):
    // R: 128 + (100 - 128) * 0.5 = 114
    // G: 64 + (100 - 64) * 0.5 = 82
    // B: 32 + (100 - 32) * 0.5 = 66
    try expectEqual(@as(u32, 114), ctx.readData(25)); // MAC1
    try expectEqual(@as(u32, 82), ctx.readData(26)); // MAC2
    try expectEqual(@as(u32, 66), ctx.readData(27)); // MAC3

    // IR1..3 mirror the MACs (well within the ±0x7FFF saturation range).
    try expectEqual(@as(u32, 114), ctx.readData(9));
    try expectEqual(@as(u32, 82), ctx.readData(10));
    try expectEqual(@as(u32, 66), ctx.readData(11));

    // The colour FIFO takes MAC >> 4 (Avocado `pushColor`).
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 114 >> 4), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 82 >> 4), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 66 >> 4), @as(u8, @truncate(rgb2 >> 16))); // B
}

// Regression: Spyro the Dragon read MAC3 straight back with `mfc2 $s1, $27`,
// did `sll $s1,$s1,16` and then a *trapping* `add`. INTPL used to leave MAC1..3
// un-shifted (only IR got the `>> sf`), so MAC3 came out 4096x too large, the
// shift-left overflowed into the sign bit and the `add` raised an Arithmetic
// Overflow the kernel could not dispatch — the BIOS parked in its unresolved-
// exception loop and the screen went black while CD-XA audio kept streaming.
test "GTE INTPL writes back sf-shifted MAC1..3 (Spyro overflow trap)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // IR3 = 256, BFC = 512, IR0 = 1.0 in 1.3.12 fixed point.
    ctx.setData(9, 256);
    ctx.setData(10, 256);
    ctx.setData(11, 256);
    ctx.setCtrl(21, 512);
    ctx.setCtrl(22, 512);
    ctx.setCtrl(23, 512);
    ctx.setData(8, 4096);

    ctx.execute(0x4A080011); // INTPL, sf=1

    // Stage 1: MAC = ((512 << 12) - (256 << 12)) >> 12 = 256, saturated into IR.
    // Stage 2: MAC = (256 << 12) + 4096 * 256 >> 12 = 512.
    // With the old un-shifted MAC this read back as 2097152 (= 512 << 12), and
    // `<< 16` then landed exactly on 0x80000000.
    try expectEqual(@as(u32, 512), ctx.readData(27)); // MAC3
    try expectEqual(@as(u32, 512), ctx.readData(25)); // MAC1
    try expectEqual(@as(u32, 512), ctx.readData(26)); // MAC2

    // The value the game actually shifted left by 16 must stay in range.
    const mac3: i32 = @bitCast(ctx.readData(27));
    try std.testing.expect(@as(i64, mac3) << 16 <= std.math.maxInt(i32));
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

    // The colour FIFO takes MAC >> 4, not >> 12, so this saturates.
    // (Verified against Avocado for this exact setup.)
    try expectEqual(@as(u32, 0x3effffff), ctx.readData(22));
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

    // The colour FIFO takes MAC >> 4, not >> 12, so these all saturate.
    // (Verified against Avocado for this exact setup.)
    try expectEqual(@as(u32, 0x44ffffff), ctx.readData(22));
}

// GPF/GPL at sf=12, where the result is not simply saturated. Expected values
// come from Avocado's GTE. GPF starts from zero; GPL accumulates the current
// MAC, rescaled by sf so the shift in setMacAndIr leaves it in place.
test "GTE GPF interpolates from zero at sf=12" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setData(8, 4096); // IR0 = 1.0
    ctx.setData(9, 100);
    ctx.setData(10, 200);
    ctx.setData(11, 300);
    ctx.setData(6, 0x2A000000);

    ctx.execute(0x4A08003D); // GPF, sf=12, lm=0

    try expectEqual(@as(u32, 100), ctx.readData(25)); // MAC1
    try expectEqual(@as(u32, 200), ctx.readData(26)); // MAC2
    try expectEqual(@as(u32, 300), ctx.readData(27)); // MAC3
    try expectEqual(@as(u32, 100), ctx.readData(9)); // IR1
    try expectEqual(@as(u32, 0x2a120c06), ctx.readData(22)); // RGB2 = MAC >> 4
    try expectEqual(@as(u32, 0), ctx.cpu.cop2.readCtrl(31));
}

test "GTE GPL accumulates onto MAC at sf=12" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setData(25, 100); // MAC1
    ctx.setData(26, 200); // MAC2
    ctx.setData(27, 300); // MAC3

    ctx.setData(8, 4096); // IR0 = 1.0
    ctx.setData(9, 10);
    ctx.setData(10, 20);
    ctx.setData(11, 30);
    ctx.setData(6, 0x2A000000);

    ctx.execute(0x4A08003E); // GPL, sf=12, lm=0

    try expectEqual(@as(u32, 110), ctx.readData(25)); // MAC1 = 100 + 10
    try expectEqual(@as(u32, 220), ctx.readData(26));
    try expectEqual(@as(u32, 330), ctx.readData(27));
    try expectEqual(@as(u32, 0x2a140d06), ctx.readData(22)); // RGB2 = MAC >> 4
    try expectEqual(@as(u32, 0), ctx.cpu.cop2.readCtrl(31));
}

// The MVMVA operand selectors live at fixed bit positions in the COP2 command
// (avocado_ref/src/cpu/gte/command.h): bits 17-18 pick the matrix, 15-16 the
// vector, 13-14 the translation vector. Getting the matrix and translation
// fields the wrong way round silently corrupts every libgte matrix composition
// (MulMatrix uses mx=rotation with cv=none), which is what blanked Croc's 3D
// backdrop: TR was folded in on every compose until the matrix saturated.
test "GTE MVMVA selects translation from bits 13-14 (cv=none adds nothing)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Rotation matrix = identity in 1.12 fixed point (1.0 == 4096).
    ctx.setCtrl(0, 0x00001000); // RT11=4096, RT12=0
    ctx.setCtrl(1, 0x00000000); // RT13=0, RT21=0
    ctx.setCtrl(2, 0x00001000); // RT22=4096, RT23=0
    ctx.setCtrl(3, 0x00000000); // RT31=0, RT32=0
    ctx.setCtrl(4, 0x00001000); // RT33=4096
    ctx.setCtrl(5, 1000); // TRX
    ctx.setCtrl(6, 2000); // TRY
    ctx.setCtrl(7, 3000); // TRZ

    ctx.setData(0, 0x0014000A); // V0: X=10, Y=20
    ctx.setData(1, 30); // V0: Z=30

    // MVMVA sf=1(>>12), mx=0 (rotation), v=0 (V0), cv=3 (none), lm=0.
    ctx.execute(0x4A086012);

    // cv=none means the translation vector must NOT be added.
    try expectEqual(@as(u32, 10), ctx.readData(9)); // IR1
    try expectEqual(@as(u32, 20), ctx.readData(10)); // IR2
    try expectEqual(@as(u32, 30), ctx.readData(11)); // IR3
}

test "GTE MVMVA selects matrix from bits 17-18 (mx=color)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Rotation matrix zeroed, colour matrix (ctrl 16..20) = identity in 1.12.
    for (0..5) |i| ctx.setCtrl(@intCast(i), 0);
    ctx.setCtrl(16, 0x00001000); // LR11=4096
    ctx.setCtrl(17, 0x00000000);
    ctx.setCtrl(18, 0x00001000); // LR22=4096
    ctx.setCtrl(19, 0x00000000);
    ctx.setCtrl(20, 0x00001000); // LR33=4096

    ctx.setData(0, 0x0014000A); // V0: X=10, Y=20
    ctx.setData(1, 30); // V0: Z=30

    // MVMVA sf=1(>>12), mx=2 (colour), v=0 (V0), cv=3 (none), lm=0.
    ctx.execute(0x4A0C6012);

    try expectEqual(@as(u32, 10), ctx.readData(9)); // IR1
    try expectEqual(@as(u32, 20), ctx.readData(10)); // IR2
    try expectEqual(@as(u32, 30), ctx.readData(11)); // IR3
}
