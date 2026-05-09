const std = @import("std");
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;

const TestContext = struct {
    bus: *Bus,
    allocator: std.mem.Allocator,

    pub fn init() !TestContext {
        const allocator = std.testing.allocator;
        const bus = try Bus.init(allocator);
        return TestContext{
            .bus = bus,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestContext) void {
        self.bus.deinit(self.allocator);
    }
};

test "DMA DICR write-1-to-clear and Master Flag logic" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var dma = &ctx.bus.dma;

    // 1. Force IRQ (Bit 15) should instantly trigger the Master Flag (Bit 31)
    dma.write(ctx.bus, 0x74, 1 << 15);
    try expectEqual(@as(u32, (1 << 15) | (1 << 31)), dma.read(0x74));

    // 2. Clear Force IRQ (0 to bit 15), Set IRQ Enable for Ch 2 (Bit 18)
    // We will artificially set the Ch 2 IRQ Flag (Bit 26) by poking the struct directly
    // since writing 1 to it via the bus clears it!
    dma.dicr = (1 << 18) | (1 << 26);
    dma.updateDicr31(ctx.bus);

    // Master Flag should be active because En(18) AND Flag(26) is true
    try expectEqual(@as(u32, (1 << 18) | (1 << 26) | (1 << 31)), dma.read(0x74));

    // 3. Write 1 to Bit 26. This should clear Bit 26 AND drop the Master Flag.
    // We also write back Bit 18 to keep it enabled!
    dma.write(ctx.bus, 0x74, (1 << 18) | (1 << 26));

    // Only the enable bit (18) should remain
    try expectEqual(@as(u32, (1 << 18)), dma.read(0x74));
}

test "DMA Channel 6 (OTC) reverse linked list generation" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // Enable DMA Channel 6 in DPCR
    bus.write32(0x1F8010F0, 0x08000000);

    // Ch6 MADR (Start Address)
    bus.write32(0x1F8010E0, 0x00100000);
    // Ch6 BCR (Block count: 3 words)
    bus.write32(0x1F8010E4, 3);
    // Ch6 CHCR (Start=1)
    bus.write32(0x1F8010E8, (1 << 24));

    bus.dma.step(bus);

    // Expect the memory to contain pointers backwards:
    // 0x100000 -> 0x0FFFFC
    // 0x0FFFFC -> 0x0FFFF8
    // 0x0FFFF8 -> 0x00FFFFFF (End of list marker)
    try expectEqual(@as(u32, 0x000FFFFC), bus.read32(0x00100000));
    try expectEqual(@as(u32, 0x000FFFF8), bus.read32(0x000FFFFC));
    try expectEqual(@as(u32, 0x00FFFFFF), bus.read32(0x000FFFF8));

    // The MADR register should end up pointing to the last written address
    try expectEqual(@as(u32, 0x000FFFF8), bus.read32(0x1F8010E0));
}

test "DMA Channel 2 (GPU) Block Copy to VRAM" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // Manually place a GPU "Fill Rectangle" (0x02) command into Main RAM
    // Command: [Opcode 0x02 | Color 0x0000FF (Red)], [Y:10 | X:5], [H:20 | W:15]
    bus.write32(0x100000, 0x020000FF);
    bus.write32(0x100004, (10 << 16) | 5);
    bus.write32(0x100008, (20 << 16) | 15);

    // Enable DMA Channel 2 in DPCR
    bus.write32(0x1F8010F0, 0x00000800);

    // Setup DMA Channel 2 (GPU)
    bus.write32(0x1F8010A0, 0x00100000); // MADR: Point to our command
    bus.write32(0x1F8010A4, 3); // BCR: Transfer 3 words

    // CHCR: SyncMode=0, Dir=1 (RAM to Device), Step=0 (+4), Start=1
    bus.write32(0x1F8010A8, (1 << 24) | (1 << 0));

    bus.dma.step(bus);

    // Check the GPU's VRAM directly to verify the Fill Rectangle executed!
    // The top-left pixel (5, 10) should be colored 0x001F (5-bit Red)
    try expectEqual(@as(u16, 0x001F), bus.gpu.vram.data[10 * 1024 + 5]);

    // The bottom-right pixel (19, 29) should be colored 0x001F
    try expectEqual(@as(u16, 0x001F), bus.gpu.vram.data[29 * 1024 + 19]);

    // One pixel outside the box (20, 29) should still be 0
    try expectEqual(@as(u16, 0x0000), bus.gpu.vram.data[29 * 1024 + 20]);
}

test "DMA Channel 2 (GPU) Linked List Execution" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // Build a Linked List in RAM

    // Packet 1 at 0x100000: Header = 1 word payload, next addr = 0x100010
    bus.write32(0x100000, (1 << 24) | 0x100010);
    bus.write32(0x100004, 0xE1000001); // Env Register 0 (Draw Mode)

    // Packet 2 at 0x100010: Header = 1 word payload, next addr = END (0xFFFFFF)
    bus.write32(0x100010, (1 << 24) | 0x00FFFFFF);
    bus.write32(0x100014, 0xE2000002); // Env Register 1 (Texture Window)

    // Enable DMA Channel 2 in DPCR
    bus.write32(0x1F8010F0, 0x00000800);

    // Setup DMA Channel 2 for Linked List Mode
    bus.write32(0x1F8010A0, 0x00100000); // MADR: Start at head of list

    // CHCR: SyncMode=2 (Linked List), Dir=1 (RAM to Device), Start=1
    bus.write32(0x1F8010A8, (1 << 24) | (2 << 9) | (1 << 0));

    bus.dma.step(bus);

    // Verify the GPU parsed the Linked List and executed the Environment Commands
    try expectEqual(@as(u32, 0xE1000001), bus.gpu.draw_env.draw_mode);
    try expectEqual(@as(u32, 0xE2000002), bus.gpu.draw_env.tex_window);
}
