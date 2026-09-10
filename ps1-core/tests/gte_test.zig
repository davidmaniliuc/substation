const std = @import("std");
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const Cpu = ps1_core.cpu.Cpu;
const Bus = ps1_core.memory.Bus;
const subPixel = @import("pgxp_value.zig").subPixel;

const TestContext = struct {
    bus: *Bus,
    cpu: Cpu,
    allocator: std.mem.Allocator,

    pub fn init() !TestContext {
        const allocator = std.testing.allocator;
        const bus = try Bus.init(allocator);
        var cpu = Cpu.init(bus);

        cpu.pipeline.pc = 0x00000000;
        cpu.pipeline.next_pc = 0x00000004;
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
        self.bus.write32(self.cpu.pipeline.pc, instruction);
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

    // Verify Results (RGB2 out). Expected values re-derived from Avocado
    // (`gte_golden.cpp`, scenario OLD_NCS): with sf=0 nothing is shifted down by
    // 12, so MAC1/MAC3 run away and R and B both saturate to 255.
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 255), @as(u8, @truncate(rgb2))); // R (saturated)
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 255), @as(u8, @truncate(rgb2 >> 16))); // B (saturated)
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

// DCPL does no matrix multiply at all — it interpolates the *current* IR
// towards the far colour, weighted by RGBC, in two stages (Avocado
// opcodes.cpp:224-235). It is the same body as NCDS's depth-cue tail.
test "GTE DCPL depth-cues the current IR towards the far colour" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(21, 100); // RFC
    ctx.setCtrl(22, 200); // GFC
    ctx.setCtrl(23, 300); // BFC

    ctx.setData(6, 0x30302010); // RGBC: R=0x10, G=0x20, B=0x30, code=0x30
    ctx.setData(8, 2048); // IR0
    ctx.setData(9, 200); // IR1
    ctx.setData(10, 100); // IR2
    ctx.setData(11, 50); // IR3

    ctx.execute(0x4A080029); // DCPL, sf=1, lm=0

    // Stage 1 (lm forced off): MACn = (FCn << 12) - RGBCn*IRn, shifted >>12,
    //   -> 87, 187, 290
    // Stage 2: MACn = RGBCn*IRn + IR0*IRn', shifted >>12
    //   -> (51200 + 178176) >> 12 = 56, (51200 + 382976) >> 12 = 106,
    //      (38400 + 593920) >> 12 = 154
    try expectEqual(@as(u32, 56), ctx.readData(25));
    try expectEqual(@as(u32, 106), ctx.readData(26));
    try expectEqual(@as(u32, 154), ctx.readData(27));
    try expectEqual(@as(u32, 56), ctx.readData(9));
    try expectEqual(@as(u32, 106), ctx.readData(10));
    try expectEqual(@as(u32, 154), ctx.readData(11));

    // The colour FIFO takes MAC >> 4, and keeps RGBC's code byte.
    try expectEqual(@as(u32, 0x30090603), ctx.readData(22));
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

    // Expected values from Avocado (`gte_golden.cpp`, scenario OLD_NCDS).
    // RGBC is 0 here, so the colour weighting zeroes every channel; with IR0 = 0
    // the far colour cannot come through either. The far-colour path is covered
    // by "GTE NCDS interpolates towards the far colour via IR0" below.
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 16))); // B
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

    // Expected values from Avocado (`gte_golden.cpp`, scenario OLD_NCCS): with
    // sf=0 the red channel saturates rather than landing on a scaled 128.
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 255), @as(u8, @truncate(rgb2))); // R (saturated)
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

    // Expected values from Avocado (`gte_golden.cpp`, scenario OLD_CDP). RGBC is
    // 0, so every channel is weighted to zero; the far colour only reaches the
    // output through the RGBC-weighted term.
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 16))); // B
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

    // Expected values from Avocado (`gte_golden.cpp`, scenario OLD_CC). CC reads
    // its input from IR1..3, which are 0 here -- the RGBC value alone does not
    // seed the multiply -- so the result is black. The meaningful CC case is
    // covered by "GTE CC modulates IR by RGBC ..." below.
    const rgb2 = ctx.readData(22);
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2))); // R
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 8))); // G
    try expectEqual(@as(u8, 0), @as(u8, @truncate(rgb2 >> 16))); // B
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

// OP crosses IR with the rotation matrix's *diagonal* (RT11, RT22, RT33), not
// its third column (Avocado opcodes.cpp:475-483, PSX-SPX "op"). Every
// off-diagonal RT entry below is poisoned with 0x7FFF so reading the wrong one
// cannot produce these results by accident.
test "GTE OP (Outer Product) crosses IR with the RT diagonal" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(0, 0x7FFF0800); // RT11 = 2048, RT12 poisoned
    ctx.setCtrl(1, 0x7FFF7FFF); // RT13, RT21 poisoned
    ctx.setCtrl(2, 0x7FFF1000); // RT22 = 4096, RT23 poisoned
    ctx.setCtrl(3, 0x7FFF7FFF); // RT31, RT32 poisoned
    ctx.setCtrl(4, 0x00000000); // RT33 = 0

    ctx.setData(9, 4096); // IR1
    ctx.setData(10, 1000); // IR2
    ctx.setData(11, 100); // IR3

    ctx.execute(0x4A08000C); // OP, sf=1, lm=0

    // MAC1 = RT22*IR3 - RT33*IR2 =    409600 >> 12 =   100
    // MAC2 = RT33*IR1 - RT11*IR3 =   -204800 >> 12 =   -50
    // MAC3 = RT11*IR2 - RT22*IR1 = -14729216 >> 12 = -3596
    // All three MACs are computed before any IR is written back: MAC2 reads
    // IR3 and MAC3 reads IR2, both of which OP overwrites.
    try expectEqual(@as(u32, 100), ctx.readData(25));
    try expectEqual(@as(u32, 0xFFFFFFCE), ctx.readData(26));
    try expectEqual(@as(u32, 0xFFFFF1F4), ctx.readData(27));

    // MAC1..3 hold the sf-shifted value, so IR is just the saturated MAC.
    try expectEqual(@as(u32, 100), ctx.readData(9));
    try expectEqual(@as(u32, 0xFFFFFFCE), ctx.readData(10));
    try expectEqual(@as(u32, 0xFFFFF1F4), ctx.readData(11));
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

// ---------------------------------------------------------------------------
// Avocado-golden colour-op tests.
//
// Expected values were produced by running the same register setup through
// Avocado's GTE (`avocado_ref/src/platform/headless/gte_golden.cpp`), not by
// recording this implementation's own output. The shared scenario uses identity
// light and light-colour matrices, V0 = (1.0, 1.0, 1.0) and a strongly coloured
// RGBC (R=0x40 G=0x80 B=0xC0); with BK = FC = IR0 = 0 the depth-cue term drops
// out, so a correct NCDS/NCCS/CC/CDP reproduces the RGBC colour exactly. An
// implementation that ignores RGBC returns grey — which is what made the BIOS
// boot logo render in greyscale instead of red/yellow/green/blue.
// ---------------------------------------------------------------------------

/// Identity light + light-colour matrices, V0 = (1.0, 1.0, 1.0), coloured RGBC.
fn setupColourScenario(ctx: *TestContext, code: u8) void {
    ctx.setCtrl(8, 0x00001000); // L11 = 1.0
    ctx.setCtrl(10, 0x00001000); // L22 = 1.0
    ctx.setCtrl(12, 0x00001000); // L33 = 1.0
    ctx.setCtrl(16, 0x00001000); // LR1 = 1.0
    ctx.setCtrl(18, 0x00001000); // LG2 = 1.0
    ctx.setCtrl(20, 0x00001000); // LB3 = 1.0
    ctx.setData(0, (4096 << 16) | 4096); // V0.x = V0.y = 1.0
    ctx.setData(1, 4096); // V0.z = 1.0
    ctx.setData(6, (@as(u32, code) << 24) | 0x00C08040); // RGBC
}

fn expectRgb2(ctx: *const TestContext, expected: u32) !void {
    try expectEqual(expected, ctx.readData(22));
}

test "GTE NCDS modulates the lighting result by RGBC (Avocado golden)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    setupColourScenario(&ctx, 0x13);
    ctx.execute(0x4A080013); // NCDS, sf=1, lm=0

    // Avocado: RGB2=13c08040 IR=1024/2048/3072 MAC=1024/2048/3072
    try expectRgb2(&ctx, 0x13C08040);
    try expectEqual(@as(u32, 1024), ctx.readData(9)); // IR1
    try expectEqual(@as(u32, 2048), ctx.readData(10)); // IR2
    try expectEqual(@as(u32, 3072), ctx.readData(11)); // IR3
    try expectEqual(@as(u32, 1024), ctx.readData(25)); // MAC1
    try expectEqual(@as(u32, 2048), ctx.readData(26)); // MAC2
    try expectEqual(@as(u32, 3072), ctx.readData(27)); // MAC3
}

test "GTE NCDS interpolates towards the far colour via IR0 (Avocado golden)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    setupColourScenario(&ctx, 0x13);
    ctx.setCtrl(21, 0x40); // RFC
    ctx.setCtrl(22, 0x40); // GFC
    ctx.setCtrl(23, 0x40); // BFC
    ctx.setData(8, 4096); // IR0 = 1.0
    ctx.execute(0x4A080013);

    // Avocado: RGB2=13040404 IR=64/64/64 MAC=64/64/64
    try expectRgb2(&ctx, 0x13040404);
    try expectEqual(@as(u32, 64), ctx.readData(9));
    try expectEqual(@as(u32, 64), ctx.readData(10));
    try expectEqual(@as(u32, 64), ctx.readData(11));
}

test "GTE NCS applies lighting without RGBC modulation (Avocado golden)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    setupColourScenario(&ctx, 0x13);
    ctx.execute(0x4A08001E); // NCS, sf=1, lm=0

    // Avocado: RGB2=13ffffff (4096 >> 4 = 256, saturated to 255) IR=4096 each
    try expectRgb2(&ctx, 0x13FFFFFF);
    try expectEqual(@as(u32, 4096), ctx.readData(9));
    try expectEqual(@as(u32, 4096), ctx.readData(10));
    try expectEqual(@as(u32, 4096), ctx.readData(11));
}

test "GTE NCCS modulates the lighting result by RGBC (Avocado golden)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    setupColourScenario(&ctx, 0x13);
    ctx.execute(0x4A08001B); // NCCS, sf=1, lm=0

    // Avocado: RGB2=13c08040 IR=1024/2048/3072
    try expectRgb2(&ctx, 0x13C08040);
    try expectEqual(@as(u32, 1024), ctx.readData(9));
    try expectEqual(@as(u32, 2048), ctx.readData(10));
    try expectEqual(@as(u32, 3072), ctx.readData(11));
}

test "GTE CC modulates IR by RGBC through the light-colour matrix (Avocado golden)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(16, 0x00001000);
    ctx.setCtrl(18, 0x00001000);
    ctx.setCtrl(20, 0x00001000);
    ctx.setData(6, 0x1CC08040);
    ctx.setData(9, 4096); // IR1
    ctx.setData(10, 4096); // IR2
    ctx.setData(11, 4096); // IR3
    ctx.execute(0x4A08001C); // CC, sf=1, lm=0

    // Avocado: RGB2=1cc08040 IR=1024/2048/3072
    try expectRgb2(&ctx, 0x1CC08040);
    try expectEqual(@as(u32, 1024), ctx.readData(9));
    try expectEqual(@as(u32, 2048), ctx.readData(10));
    try expectEqual(@as(u32, 3072), ctx.readData(11));
}

test "GTE CDP depth-cues the IR colour using RGBC (Avocado golden)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(16, 0x00001000);
    ctx.setCtrl(18, 0x00001000);
    ctx.setCtrl(20, 0x00001000);
    ctx.setData(6, 0x14C08040);
    ctx.setData(9, 4096);
    ctx.setData(10, 4096);
    ctx.setData(11, 4096);
    ctx.execute(0x4A080014); // CDP, sf=1, lm=0

    // Avocado: RGB2=14c08040 IR=1024/2048/3072
    try expectRgb2(&ctx, 0x14C08040);
    try expectEqual(@as(u32, 1024), ctx.readData(9));
    try expectEqual(@as(u32, 2048), ctx.readData(10));
    try expectEqual(@as(u32, 3072), ctx.readData(11));
}

// GTE data registers are not a flat 32-bit file: several are narrower than a
// word, two are computed on read, and two ignore writes entirely. Our storage
// is a plain [32]u32, so every one of these has to be enforced by hand where
// Avocado gets it for free from the field types (gte.cpp:30-190).
// Reproduces the whole of gte/test-all's very first assertion.
test "GTE data register widths and read-only registers" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // OTZ and the SZ FIFO are 16-bit unsigned; the upper half is dropped.
    ctx.setData(7, 0x80000000);
    try expectEqual(@as(u32, 0x00000000), ctx.readData(7));
    ctx.setData(16, 0xAA9D7FBE);
    try expectEqual(@as(u32, 0x00007FBE), ctx.readData(16));
    ctx.setData(17, 0xFBA3072D);
    try expectEqual(@as(u32, 0x0000072D), ctx.readData(17));
    ctx.setData(19, 0x80008000);
    try expectEqual(@as(u32, 0x00008000), ctx.readData(19));

    // Writing IRGB unpacks three 5-bit channels into IR1..IR3, scaled by 0x80.
    ctx.setData(28, 0x115E);
    try expectEqual(@as(u32, 0x0F00), ctx.readData(9)); // 0x1E * 0x80
    try expectEqual(@as(u32, 0x0500), ctx.readData(10)); // 0x0A * 0x80
    try expectEqual(@as(u32, 0x0200), ctx.readData(11)); // 0x04 * 0x80

    // IRGB and ORGB are both computed back from IR1..IR3 on read.
    try expectEqual(@as(u32, 0x115E), ctx.readData(28));
    try expectEqual(@as(u32, 0x115E), ctx.readData(29));

    // ORGB is read-only: the write must not disturb the computed value.
    ctx.setData(29, 0x80008000);
    try expectEqual(@as(u32, 0x115E), ctx.readData(29));

    // Each channel saturates to 5 bits rather than wrapping.
    ctx.setData(9, 0xFFFF); // -1 -> clamps to 0
    ctx.setData(10, 0x7FFF); // huge -> clamps to 0x1F
    ctx.setData(11, 0);
    try expectEqual(@as(u32, 0x1F << 5), ctx.readData(28));

    // LZCR is read-only and always reflects the last LZCS write.
    ctx.setData(30, 0x00000FFF);
    try expectEqual(@as(u32, 20), ctx.readData(31));
    ctx.setData(31, 0x7487EDDB);
    try expectEqual(@as(u32, 20), ctx.readData(31));

    // Reading SXYP returns SXY2 rather than a separate latch.
    ctx.setData(14, 0x11112222);
    try expectEqual(@as(u32, 0x11112222), ctx.readData(15));
}

// The control registers backed by a single 16-bit field (RT33, LL33, LC33, H,
// DQA, ZSF3, ZSF4 — GTE 36/44/52/58/59/61/62) are stored truncated and read
// back sign-extended. H is included even though the divide consumes it as
// unsigned; sign-extending it on read is a GTE bug Avocado reproduces
// (gte.cpp:88). Reproduces gte/test-all's second wave of diffs.
test "GTE 16-bit control registers sign-extend on read" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // ctrl_regs is indexed 0..31, i.e. GTE register 32 + n.
    const i16_ctrl = [_]u5{ 4, 12, 20, 26, 27, 29, 30 };
    for (i16_ctrl) |reg| {
        ctx.setCtrl(reg, 0xAAAAAAAA);
        try expectEqual(@as(u32, 0xFFFFAAAA), ctx.cpu.cop2.readCtrl(reg));
        ctx.setCtrl(reg, 0x00005555);
        try expectEqual(@as(u32, 0x00005555), ctx.cpu.cop2.readCtrl(reg));
    }

    // Packed 16-bit pairs and full-word registers keep all 32 bits.
    ctx.setCtrl(0, 0xAAAAAAAA); // RT11/RT12
    try expectEqual(@as(u32, 0xAAAAAAAA), ctx.cpu.cop2.readCtrl(0));
    ctx.setCtrl(5, 0xAAAAAAAA); // TRX
    try expectEqual(@as(u32, 0xAAAAAAAA), ctx.cpu.cop2.readCtrl(5));
    ctx.setCtrl(28, 0xAAAAAAAA); // DQB
    try expectEqual(@as(u32, 0xAAAAAAAA), ctx.cpu.cop2.readCtrl(28));
}

// An IR register that saturates *downwards* raises the same FLAG bit as one
// that saturates upwards — Avocado's `clip()` takes a single `flags` mask and
// ors it in on either branch (opcodes.cpp:7-17), and `setIr<i>` passes
// IR{1,2,3}_SATURATED (bits 24/23/22) for both. Setting bits 21/20/19 on the
// negative branch instead corrupts the colour-FIFO saturation flags with
// results from ops that never touch the colour FIFO at all.
test "GTE negative IR saturation raises the IR flag, not the colour-FIFO flag" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    setupIdentityRtps(&ctx, 512);

    // V0 = (0, -32, 0). With sf=0 the accumulator keeps its 20.12 scale, so
    // MAC2 = RT22 * -32 = -131072, far below IR2's lm=1 floor of 0.
    ctx.setData(0, (0xFFE0 << 16) | 0);
    ctx.setData(1, 0);

    ctx.execute(0x4A000401); // RTPS, sf=0, lm=1

    const flag = ctx.cpu.cop2.readCtrl(31);
    try expectEqual(@as(u32, 0), ctx.readData(10)); // IR2 floored at 0
    try std.testing.expect(flag & (1 << 23) != 0); // IR2 saturated
    try expectEqual(@as(u32, 0), flag & 0x00380000); // colour FIFO R/G/B untouched
}

// Avocado's `setIr` takes an `int32_t`, so the 44-bit MAC handed to it by
// `setMacAndIr` is narrowed to 32 bits *before* being clipped (opcodes.cpp:68-86).
// Clipping the full 64-bit accumulator instead flips the result whenever the
// low 32 bits disagree in sign with the whole — which is routine at sf=0, where
// no >>12 shrinks the accumulator first.
test "GTE saturates IR from the low 32 bits of MAC, not the full 44" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    setupIdentityRtps(&ctx, 512);
    ctx.setCtrl(6, 0xFFF00000); // TRY = -0x100000, so TRY<<12 = -0x1_0000_0000

    // V0 = (0, 16, 0): MAC2 = -0x1_0000_0000 + 4096*16 = -0xFFFF0000, whose low
    // 32 bits are +0x00010000. Hardware saturates that to 0x7FFF; clipping the
    // negative 44-bit value would floor it instead.
    ctx.setData(0, (16 << 16) | 0);
    ctx.setData(1, 0);

    ctx.execute(0x4A000001); // RTPS, sf=0, lm=0

    try expectEqual(@as(u32, 0x00010000), ctx.readData(26)); // MAC2 keeps its low word
    try expectEqual(@as(u32, 0x7FFF), ctx.readData(10)); // IR2 saturated upwards
    try std.testing.expect(ctx.cpu.cop2.readCtrl(31) & (1 << 23) != 0);
}

// RTP writes IR3 through its own clip rather than `setMacAndIr` (it has to, to
// derive the saturation flag from the unshifted Z), so it needs the same 32-bit
// narrowing: Avocado's `ir[3] = clip(mac[3], ...)` passes an int64_t MAC into an
// int32_t parameter (opcodes.cpp:131).
test "GTE RTPS saturates IR3 from the low 32 bits of MAC3" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    setupIdentityRtps(&ctx, 512);
    ctx.setCtrl(7, 0x00100000); // TRZ = 0x100000, so TRZ<<12 = +0x1_0000_0000

    // V0 = (0, 0, -16): MAC3 = 0x1_0000_0000 - 4096*16 = +0xFFFF0000, whose low
    // 32 bits are -0x10000. Hardware floors IR3 at -0x8000; clipping the
    // positive 44-bit value would cap it at +0x7FFF instead.
    ctx.setData(0, 0);
    ctx.setData(1, 0xFFF0);

    ctx.execute(0x4A000001); // RTPS, sf=0, lm=0

    try expectEqual(@as(u32, 0xFFFF0000), ctx.readData(27)); // MAC3 keeps its low word
    try expectEqual(@as(u32, 0xFFFF8000), ctx.readData(11)); // IR3 floored, not capped
}

// MAC1..3 are 44-bit accumulators, so their overflow flags trip at ±2^43 —
// Avocado's `setMac<1..3>` calls `checkOverflow<44>` (opcodes.cpp:49-65).
// Checking a 32-bit range instead raises MAC_OVERFLOW on values the hardware
// carries happily, which is routine at sf=0 where nothing is shifted down.
test "GTE MAC overflow flags trip at 44 bits, not 32" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(21, 0x00100000); // RFC: (RFC << 12) = +2^32, well inside 44 bits
    ctx.setCtrl(22, 0);
    ctx.setCtrl(23, 0);
    ctx.setData(6, 0); // RGBC = 0
    ctx.setData(8, 0); // IR0 = 0

    ctx.execute(0x4A000010); // DPCS, sf=0, lm=0

    try expectEqual(@as(u32, 0), ctx.cpu.cop2.readCtrl(31)); // no flags at all
}

// MVMVA's general path is Avocado's `multiplyMatrixByVector` (opcodes.cpp:444):
// the translation enters the accumulator already scaled to 20.12, *before* the
// sf shift. Shifting the product first and then adding an unscaled translation
// (the old behaviour) is off by a factor of 4096 whenever sf=0.
test "GTE MVMVA adds the translation at 20.12, before the sf shift" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(0, 0x00001000); // RT11=4096, RT12=0
    ctx.setCtrl(1, 0x00000000);
    ctx.setCtrl(2, 0x00001000); // RT22=4096
    ctx.setCtrl(3, 0x00000000);
    ctx.setCtrl(4, 0x00001000); // RT33=4096
    ctx.setCtrl(5, 1000); // TRX
    ctx.setCtrl(6, 2000); // TRY
    ctx.setCtrl(7, 3000); // TRZ

    ctx.setData(0, (20 << 16) | 10); // V0: X=10, Y=20
    ctx.setData(1, 30); // V0: Z=30

    ctx.execute(0x4A000012); // MVMVA sf=0, mx=0, v=0, cv=0 (TR), lm=0

    // MACn = (TRn << 12) + 4096*Vn
    try expectEqual(@as(u32, (1000 << 12) + 40960), ctx.readData(25));
    try expectEqual(@as(u32, (2000 << 12) + 81920), ctx.readData(26));
    try expectEqual(@as(u32, (3000 << 12) + 122880), ctx.readData(27));
}

// cv=2 (far colour) selects a documented hardware bug, not an ordinary
// translation (Avocado opcodes.cpp:420-438): the translation is applied only
// while computing a throwaway first column whose sole lasting effect is the
// FLAG bits, and the MAC/IR actually returned come from the 2nd and 3rd
// components alone — with no translation at all.
test "GTE MVMVA cv=2 takes the buggy far-colour path" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(0, 0x00001000); // RT11=4096, RT12=0
    ctx.setCtrl(1, 0x00000000);
    ctx.setCtrl(2, 0x00001000); // RT22=4096
    ctx.setCtrl(3, 0x00000000);
    ctx.setCtrl(4, 0x00001000); // RT33=4096
    ctx.setCtrl(21, 0x00010000); // RFC, large enough to saturate the throwaway IR1
    ctx.setCtrl(22, 2000); // GFC
    ctx.setCtrl(23, 3000); // BFC

    ctx.setData(0, (20 << 16) | 10); // V0: X=10, Y=20
    ctx.setData(1, 30); // V0: Z=30

    ctx.execute(0x4A084012); // MVMVA sf=1, mx=0, v=0, cv=2 (FC), lm=0

    // MAC1 = (RT12*VY + RT13*VZ) >> 12 = 0
    // MAC2 = (RT22*VY + RT23*VZ) >> 12 = 20
    // MAC3 = (RT32*VY + RT33*VZ) >> 12 = 30
    try expectEqual(@as(u32, 0), ctx.readData(25));
    try expectEqual(@as(u32, 20), ctx.readData(26));
    try expectEqual(@as(u32, 30), ctx.readData(27));
    try expectEqual(@as(u32, 0), ctx.readData(9));
    try expectEqual(@as(u32, 20), ctx.readData(10));
    try expectEqual(@as(u32, 30), ctx.readData(11));

    // ((RFC << 12) + RT11*VX) >> 12 == 65546 saturated the throwaway IR1, and
    // that flag survives even though the IR1 it came from was overwritten.
    try std.testing.expect(ctx.cpu.cop2.readCtrl(31) & (1 << 24) != 0);
}

// mx=3 is not "rotation again" — it selects a garbage matrix assembled from the
// RGBC red channel, IR0 and two stray rotation entries (Avocado
// opcodes.cpp:394-400).
test "GTE MVMVA mx=3 selects the buggy matrix, not RT" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    ctx.setCtrl(0, 0); // RT11, RT12
    ctx.setCtrl(1, 0x00000007); // RT13 = 7, RT21 = 0
    ctx.setCtrl(2, 0x0000000B); // RT22 = 11, RT23 = 0
    ctx.setCtrl(3, 0);
    ctx.setCtrl(4, 0);

    ctx.setData(6, 0x00000020); // RGBC: R = 0x20, so the GTE's R = 0x20<<4 = 512
    ctx.setData(8, 3); // IR0
    ctx.setData(0, (2 << 16) | 1); // V0: X=1, Y=2
    ctx.setData(1, 4); // V0: Z=4

    ctx.execute(0x4A066012); // MVMVA sf=0, mx=3, v=0, cv=3 (none), lm=0

    // Row 0 = {-R, R, IR0}; rows 1 and 2 are RT13 and RT22 splatted across.
    try expectEqual(@as(u32, 524), ctx.readData(25)); // -512*1 + 512*2 + 3*4
    try expectEqual(@as(u32, 49), ctx.readData(26)); // 7*(1+2+4)
    try expectEqual(@as(u32, 77), ctx.readData(27)); // 11*(1+2+4)
}

// Avocado's colour FIFO push narrows to 32 bits before clipping — `pushColor()`
// hands `mac[i] >> 4` (an int64_t) to `pushColor(uint32_t, uint32_t, uint32_t)`
// and from there to `clip(int32_t, ...)` (opcodes.cpp:329-338). Clipping the
// full 44-bit MAC instead flips components whose low word disagrees in sign.
test "GTE colour FIFO clips from the low 32 bits of MAC" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Light and light-colour matrices zeroed, so NCS reduces to MACn = BKn << 12.
    for (8..21) |i| ctx.setCtrl(@intCast(i), 0);
    ctx.setCtrl(13, 0); // RBK
    ctx.setCtrl(14, 0); // GBK
    ctx.setCtrl(15, 0xFF000001); // BBK = -16777215

    ctx.setData(0, 0);
    ctx.setData(1, 0);
    ctx.setData(6, 0); // RGBC

    ctx.execute(0x4A00001E); // NCS, sf=0, lm=0

    // MAC3 = -16777215 << 12, so MAC3 >> 4 is -4294967040 — negative over 64
    // bits, but +256 over the low 32, which the colour FIFO clamps to 0xFF.
    try expectEqual(@as(u32, 0x00FF0000), ctx.readData(22)); // RGB2: R=0, G=0, B=255
}

test "PGXP: RTPS keeps the sub-pixel screen position MAC0 carries" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const cop2 = &ctx.cpu.cop2;

    // Not an identity matrix. `matrixFromCtrl` packs RT22/RT23 into ctrl_regs[2]'s
    // low/high halves respectively (see the RT22=... comment in the identity-matrix
    // tests around gte_test.zig:830), so `writeCtrl(2, 0x1000_0000)` sets RT22=0 and
    // RT23=4096 — it routes VZ into MAC2 as well as MAC3, rather than leaving Y
    // alone. That is fine here: this test only needs SZ3 to equal VZ0 (via RT33,
    // below) and IR1/IR2 to come out nonzero, which it does (IR1=5, IR2=7 for the
    // vertex written below). No translation (ctrl 5-7 are zero).
    cop2.writeCtrl(0, 0x0000_1000); // RT11=4096, RT12=0
    cop2.writeCtrl(1, 0x0000_0000);
    cop2.writeCtrl(2, 0x1000_0000); // RT22=0 (low half), RT23=4096 (high half)
    cop2.writeCtrl(3, 0x0000_0000);
    cop2.writeCtrl(4, 0x0000_1000); // RT33=4096
    cop2.writeCtrl(5, 0);
    cop2.writeCtrl(6, 0);
    cop2.writeCtrl(7, 0);
    cop2.writeCtrl(24, 0); // OFX
    cop2.writeCtrl(25, 0); // OFY
    cop2.writeCtrl(26, 300); // H
    cop2.writeCtrl(27, 0); // DQA
    cop2.writeCtrl(28, 0); // DQB

    // A vertex whose projection does NOT land on a whole pixel. This is not an
    // ordinary 300/7 division: `divideUNR`'s saturation guard is `2*SZ3 > H`,
    // and 2*7=14 is not > 300, so it takes the overflow branch and returns the
    // clamp constant 0x1FFFF outright (setting flag bit 17) rather than
    // computing H/SZ3. That saturated h_s3z multiplied by IR1/IR2 below is
    // where the fraction the test checks for actually comes from.
    cop2.writeData(0, 0x0000_0005); // VXY0: VX0 = 5, VY0 = 0
    cop2.writeData(1, 7); // VZ0 = 7

    cop2.executeCommand(0x4A18_0001); // RTPS, sf=1, lm=0

    const p = cop2.readPreciseData(14); // sxy2

    try std.testing.expect(p.flags != 0);
    // The entry must be recorded against the register it describes...
    try expectEqual(cop2.readData(14), p.word);
    // ...and the floor of its sub-pixel position must be the WIRE's own
    // integer coordinate, not merely equal to itself: SX2=9, SY2=13
    // (0x1FFFF * IR1(5) = 655355 >> 16 = 9; 0x1FFFF * IR2(7) = 917497 >> 16
    // = 13). `expectEqual(cop2.readData(14), p.word)` alone is a tautology —
    // both are `@bitCast(sxy2)` at the production site — so this is the
    // assertion that actually pins the precise value to the register it
    // claims to refine.
    try expectEqual(@as(f32, 9.0), @floor(p.x));
    try expectEqual(@as(f32, 13.0), @floor(p.y));
    // ...and there must be a fraction, or the test is not exercising anything.
    try std.testing.expect(p.x != @trunc(p.x));
}

test "PGXP: sxyp mirrors sxy2, and mtc2 to the FIFO invalidates" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const cop2 = &ctx.cpu.cop2;

    cop2.precise_sxy[2] = subPixel(0x0020_0010, 0.5, 0.25); // (16.5, 32.25)
    try std.testing.expect(cop2.readPreciseData(15).flags != 0);
    try expectEqual(@as(f32, 16.5), cop2.readPreciseData(15).x);

    // A game writing its own screen coordinate has no sub-pixel to recover.
    cop2.writeData(14, 0x0002_0003);
    try expectEqual(@as(u32, 0), cop2.readPreciseData(14).flags);
}

test "PGXP: a write to sxyp shifts the precise FIFO with the register FIFO" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const cop2 = &ctx.cpu.cop2;
    cop2.precise_sxy[1] = subPixel(0x0022_0011, 0, 0); // (17, 34)
    cop2.precise_sxy[2] = subPixel(0x0044_0033, 0, 0); // (51, 68)

    cop2.writeData(15, 0x0005_0006); // sxyp: shifts, then writes sxy2

    try expectEqual(@as(f32, 51), cop2.readPreciseData(13).x); // sxy1
    try expectEqual(@as(u32, 0), cop2.readPreciseData(14).flags); // sxy2 replaced
}
