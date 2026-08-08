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

    // 2. Clear Force IRQ (0 to bit 15), Set IRQ Enable for Ch 2 (Bit 18), AND Master Enable (Bit 23)
    // We will artificially set the Ch 2 IRQ Flag (Bit 26) by poking the struct directly
    // since writing 1 to it via the bus clears it!
    dma.dicr = (1 << 23) | (1 << 18) | (1 << 26);
    dma.updateDicr31(ctx.bus);

    // Master Flag should be active because Master En(23) AND En(18) AND Flag(26) is true
    try expectEqual(@as(u32, (1 << 23) | (1 << 18) | (1 << 26) | (1 << 31)), dma.read(0x74));

    // 3. Write 1 to Bit 26. This should clear Bit 26 AND drop the Master Flag.
    // We also write back Bit 18 and 23 to keep them enabled!
    dma.write(ctx.bus, 0x74, (1 << 23) | (1 << 18) | (1 << 26));

    // Only the enable bits (18 and 23) should remain
    try expectEqual(@as(u32, (1 << 23) | (1 << 18)), dma.read(0x74));
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
    // Ch6 CHCR (Start=1, Trigger=1)
    bus.write32(0x1F8010E8, (1 << 28) | (1 << 24));

    var dma_active = true;
    var safety: usize = 0;
    while (dma_active and safety < 1000000) : (safety += 1) {
        _ = bus.dma.step(bus);
        dma_active = false;
        for (0..7) |i| {
            if ((bus.dma.channels[i].control & (1 << 24)) != 0) {
                dma_active = true;
            }
        }
    }

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

    // CHCR: SyncMode=0, Dir=1 (RAM to Device), Step=0 (+4), Start=1, Trigger=1
    bus.write32(0x1F8010A8, (1 << 28) | (1 << 24) | (1 << 0));

    var dma_active = true;
    var safety: usize = 0;
    while (dma_active and safety < 1000000) : (safety += 1) {
        _ = bus.dma.step(bus);
        dma_active = false;
        for (0..7) |i| {
            if ((bus.dma.channels[i].control & (1 << 24)) != 0) {
                dma_active = true;
            }
        }
    }

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

    var dma_active = true;
    var safety: usize = 0;
    while (dma_active and safety < 1000000) : (safety += 1) {
        _ = bus.dma.step(bus);
        dma_active = false;
        for (0..7) |i| {
            if ((bus.dma.channels[i].control & (1 << 24)) != 0) {
                dma_active = true;
            }
        }
    }

    _ = bus.gpu.step(10000);

    // Verify the GPU parsed the Linked List and executed the Environment Commands
    try expectEqual(@as(u32, 0xE1000001), bus.gpu.draw_env.draw_mode);
    try expectEqual(@as(u32, 0xE2000002), bus.gpu.draw_env.tex_window);
}

// Runs a 3-word OTC (ch6) transfer to completion. Caller sets up DICR first.
fn runOtcTransfer(bus: *Bus) void {
    bus.write32(0x1F8010F0, 0x08000000); // DPCR: enable ch6
    bus.write32(0x1F8010E0, 0x00100000); // MADR
    bus.write32(0x1F8010E4, 3); // BCR: 3 words
    bus.write32(0x1F8010E8, (1 << 28) | (1 << 24)); // CHCR: start+trigger

    var dma_active = true;
    var safety: usize = 0;
    while (dma_active and safety < 1000000) : (safety += 1) {
        _ = bus.dma.step(bus);
        dma_active = false;
        for (0..7) |i| {
            if ((bus.dma.channels[i].control & (1 << 24)) != 0) {
                dma_active = true;
            }
        }
    }
}

test "DMA DICR sub-word stores latch the full source register (real-HW full-latch)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // Real hardware (JaCzekanski cpu/io-access-bitwidth) latches the whole 32-bit
    // bus value into DMA registers on ANY store width — the latch is full-width,
    // not byte-granular. The capture writes at lane 0 only, so a byte store there
    // deposits the entire source register and zeroes nothing else.
    bus.writeCpuStore(u8, 0x1F8010F4, 0x12345678);
    try expectEqual(@as(u32, 0x340038), bus.dma.dicr); // == the psx.log value

    bus.writeCpuStore(u8, 0x1F801080, 0x12345678);
    try expectEqual(@as(u32, 0x345678), bus.dma.channels[0].base_addr);

    // A sub-word store at a non-zero lane positions the data at that lane and
    // still latches the full width, so the rest of the register is zeroed.
    bus.dma.dicr = 0;
    bus.writeCpuStore(u8, 0x1F8010F6, 0x88);
    try expectEqual(@as(u32, 0x00880000), bus.dma.dicr);

    // Reads stay byte-granular: a byte read returns the addressed lane.
    bus.write32(0x1F8010F4, 0x00340000);
    try expectEqual(@as(u32, 0x34), bus.read8Raw(0x1F8010F6));
}

test "Croc's DICR+2 read-modify-write arms the ch3 completion IRQ" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // Croc's St FMV library arms the "frame ready" signal by read-modify-writing
    // the single DICR byte that holds the channel enables *and* the master enable
    // (bits 16-23), traced live out of the game at 0x8010d88c:
    //
    //     lbu a0,2(v1)      ; v1 = 0x1F8010F4 -> reads DICR bits 16-23
    //     or  a0,a0,0x08    ; 1 << channel(3)
    //     sb  a0,2(v1)      ; writes it back
    //
    // The store data must land on the addressed byte lane, so the ch3 enable ends
    // up at bit 19 and the master enable the game read back at bit 23 survives.
    // Latching the source register unshifted drops both into bits 0-7, the DMA
    // completion IRQ is never enabled, and the FMV frame is never signalled ready.
    bus.dma.dicr = 1 << 23; // master enable already on, as Croc finds it

    const enable_byte = bus.read8Raw(0x1F8010F6);
    try expectEqual(@as(u32, 0x80), enable_byte); // bit 23 lands in byte 2, bit 7

    bus.writeCpuStore(u8, 0x1F8010F6, enable_byte | 0x08);

    try expectEqual(@as(u32, 1 << 19), bus.dma.dicr & (1 << 19)); // ch3 IRQ enabled
    try expectEqual(@as(u32, 1 << 23), bus.dma.dicr & (1 << 23)); // master preserved

    // ...and the matching disable path (mid-frame chunks) clears just that bit.
    bus.writeCpuStore(u8, 0x1F8010F6, bus.read8Raw(0x1F8010F6) & ~@as(u32, 0x08));
    try expectEqual(@as(u32, 0), bus.dma.dicr & (1 << 19));
    try expectEqual(@as(u32, 1 << 23), bus.dma.dicr & (1 << 23));
}

test "DMA DICR flags are write-1-to-clear; enables preserved (full-latch)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    bus.dma.dicr = (1 << 23) | (1 << 19) | (1 << 27); // enabled + ch3 flag set
    bus.dma.updateDicr31(bus);
    try expectEqual(@as(u32, 1 << 31), bus.dma.dicr & (1 << 31));

    // Ack the ch3 flag (bit 27, write-1-to-clear) while keeping master+ch3 enable.
    // A word store carries the whole register: flag bit 27 set to clear it, plus
    // enables 23/19 to keep them.
    bus.writeCpuStore(u32, 0x1F8010F4, (1 << 27) | (1 << 23) | (1 << 19));

    try expectEqual(@as(u32, 0), bus.dma.dicr & (1 << 27)); // flag cleared
    try expectEqual(@as(u32, 1 << 19), bus.dma.dicr & (1 << 19)); // enable kept
    try expectEqual(@as(u32, 0), bus.dma.dicr & (1 << 31)); // master flag dropped
}

test "DMA completion sets DICR flag only when the channel IRQ is enabled" {
    // Disabled channel: completion must not latch the flag nor raise I_STAT.
    {
        var ctx = try TestContext.init();
        defer ctx.deinit();
        const bus = ctx.bus;

        bus.write32(0x1F8010F4, 1 << 23); // master enable, ch6 IRQ disabled
        runOtcTransfer(bus);

        try expectEqual(@as(u32, 0), bus.dma.dicr & (1 << 30)); // no ch6 flag
        try expectEqual(@as(u32, 0), bus.interrupts.stat & (1 << 3)); // no DMA IRQ
    }
    // Enabled channel: completion latches the flag and raises the DMA IRQ.
    {
        var ctx = try TestContext.init();
        defer ctx.deinit();
        const bus = ctx.bus;

        bus.write32(0x1F8010F4, (1 << 23) | (1 << 22)); // master + ch6 enable
        runOtcTransfer(bus);

        try expectEqual(@as(u32, 1 << 30), bus.dma.dicr & (1 << 30));
        try expectEqual(@as(u32, 1 << 31), bus.dma.dicr & (1 << 31));
        try expectEqual(@as(u32, 1 << 3), bus.interrupts.stat & (1 << 3));
    }
}

test "DMA DICR word write does not clear flags when master enable is written 0" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    bus.dma.dicr = (1 << 27) | (1 << 26); // two flags latched
    // Word write with bit23=0 and no W1C bits: flags must survive (Avocado
    // applies W1C unconditionally; there is no flags-wipe on master disable).
    bus.write32(0x1F8010F4, 1 << 19);

    try expectEqual(@as(u32, (1 << 27) | (1 << 26)), bus.dma.dicr & (0x7F << 24));
}

// Sync mode 3 is reserved. Avocado's DMAChannel::step() dispatches only on
// modes 0/1/2, so a reserved-mode channel never transfers. Ours stalls the CPU
// while a channel is active, so starting one is a hard hang: words_remaining is
// only assigned for modes 0/1/2, and after a linked-list transfer it still
// holds the 0xFFFFFFFF marker. dma/otc-test's testOtcSyncModeReserved runs
// straight after testOtcSyncModeLinkedList and wedged the CPU on exactly that.
test "DMA reserved sync mode 3 does not start a transfer" {
    const bus = try ps1_core.memory.Bus.init(std.testing.allocator);
    defer bus.deinit(std.testing.allocator);

    const otc = &bus.dma.channels[6];

    // Run a linked-list transfer first so words_remaining holds the marker.
    otc.write(0x8, (2 << 9) | (1 << 24));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), otc.words_remaining);
    otc.write(0x8, 0);

    // Now a reserved-mode start must leave the channel inert.
    otc.write(0x4, 4);
    otc.write(0x8, (3 << 9) | (1 << 24) | (1 << 28));
    try std.testing.expect(!otc.transfer_active);
    try std.testing.expectEqual(@as(u32, 0), otc.words_remaining);
    try std.testing.expect(!bus.dma.isCpuStalled(bus));
}

// ---------------------------------------------------------------------------
// Sync mode 1 block pacing (jaczekanski spu/memory-transfer)
// ---------------------------------------------------------------------------

/// Programs channel 4 (SPU) for a sync-mode-1 transfer of `bs` words per block
/// and `bc` blocks, RAM->device, and starts it.
fn startSpuBlockTransfer(bus: *Bus, bs: u32, bc: u32) void {
    bus.write32(0x1F8010F0, 0x00080000); // DPCR: enable channel 4
    bus.write32(0x1F8010C0, 0x00001000); // MADR
    bus.write32(0x1F8010C4, (bc << 16) | bs); // BCR: mode-1 block/count
    // CHCR: start(24) | sync mode 1 (9) | direction RAM->device(0)
    bus.write32(0x1F8010C8, (1 << 24) | (1 << 9) | 1);
}

test "SPU DMA in sync mode 1 hands the bus back between blocks" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    const bs: u32 = 16;
    startSpuBlockTransfer(bus, bs, 4);

    // The channel owns the bus for the whole of the first block.
    for (0..bs) |_| {
        try std.testing.expect(bus.dma.isCpuStalled(bus));
        _ = bus.dma.step(bus);
    }

    // Block boundary: the device has not requested the next block yet, so the
    // CPU gets the bus back. Without this the CPU can never observe a mode-1
    // transfer in progress.
    try std.testing.expect(!bus.dma.isCpuStalled(bus));
}

test "the SPU block gap ends and the channel resumes" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    const bs: u32 = 16;
    startSpuBlockTransfer(bus, bs, 4);
    for (0..bs) |_| _ = bus.dma.step(bus);
    try std.testing.expect(!bus.dma.isCpuStalled(bus));

    // Running the CPU for the length of the gap re-arms the channel.
    var guard: usize = 0;
    while (!bus.dma.isCpuStalled(bus) and guard < 10_000) : (guard += 1) {
        bus.dma.tickCpuWindow(1);
    }
    try std.testing.expect(bus.dma.isCpuStalled(bus));
    try std.testing.expect(guard > 0); // the gap was not zero-length
}

test "SPU sync-mode-1 transfer stays inside spu/memory-transfer's timing window" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // The ROM's testDMAWriteTiming: setupDMAWrite(..., 1024 bytes) with BS=0x10
    // gives BC = 1024/(4*16) = 16 blocks of 16 words = 256 words, then asserts
    // 1024*16*0.1 < measuredCycles < 1024*16*1.1.
    //
    // The lower bound was never the problem: RAM wait states already cost ~14
    // cycles a word, so the raw transfer takes ~3584. What the ROM measures is
    // 0 because the CPU is frozen for the whole transfer and its polling loop
    // never runs — so the CPU must get real turns *and* the total must stay in
    // the window once the pacing gaps are added on top.
    const bs: u32 = 16;
    const bc: u32 = 16;
    startSpuBlockTransfer(bus, bs, bc);

    var elapsed: u64 = 0;
    var cpu_turns: u64 = 0;
    var guard: usize = 0;
    while (bus.dma.channels[4].transfer_active and guard < 1_000_000) : (guard += 1) {
        if (bus.dma.isCpuStalled(bus)) {
            elapsed += bus.dma.step(bus);
        } else {
            // CPU's turn: one instruction, one cycle.
            bus.dma.tickCpuWindow(1);
            elapsed += 1;
            cpu_turns += 1;
        }
    }

    try std.testing.expect(!bus.dma.channels[4].transfer_active);

    // `transferFinishedImmediately == false`: the ROM's poll loop body is a
    // handful of instructions, so a gap of one or two cycles would still leave
    // loopCount at 0. Demand enough room for several iterations.
    try std.testing.expect(cpu_turns > 100);

    try std.testing.expect(elapsed > 1024 * 16 / 10); // "DMA transfer was too fast"
    try std.testing.expect(elapsed < 1024 * 16 * 11 / 10); // "DMA transfer was too slow"
}

test "GPU sync-mode-1 blocks are not paced — only the SPU rate is modelled" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    const bs: u32 = 16;
    bus.write32(0x1F8010F0, 0x00000800); // DPCR: enable channel 2
    bus.write32(0x1F8010A0, 0x00001000); // MADR
    bus.write32(0x1F8010A4, (@as(u32, 4) << 16) | bs); // BCR
    bus.write32(0x1F8010A8, (1 << 24) | (1 << 9) | 1); // CHCR: start, mode 1

    // Channel 2 keeps the bus across the block boundary, exactly as before —
    // Croc and Crash push GPU lists through mode 1 and were never smoke-tested
    // against a paced version.
    for (0..bs) |_| _ = bus.dma.step(bus);
    try std.testing.expect(bus.dma.isCpuStalled(bus));
}
