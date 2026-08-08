const std = @import("std");
const expectEqual = std.testing.expectEqual;

const ps1_core = @import("ps1_core");
const Bus = ps1_core.memory.Bus;

const reverb_preset = @import("goldens/reverb_preset.zig");
const reverb_impulse_golden = @embedFile("goldens/reverb_impulse.bin");
const reverb_noise_golden = @embedFile("goldens/reverb_noise.bin");

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

test "SPU Register R/W and Status Mirroring" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // Write to SPUCNT (1F801DAAh)
    const spu_cnt_val: u16 = 0x1234;
    bus.write16(0x1F801DAA, spu_cnt_val);

    // Read back SPUCNT
    try expectEqual(spu_cnt_val, bus.read16(0x1F801DAA));

    // Read SPUSTAT (1F801DAAh). Bits 0-5 should mirror SPUCNT bits 0-5.
    const expected_stat = spu_cnt_val & 0x3F;
    try expectEqual(expected_stat, bus.read16(0x1F801DAA) & 0x3F);
}

test "SPU SRAM DMA Transfer (RAM to SPU)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // 1. Prepare data in Main RAM
    bus.write32(0x100000, 0x11223344);
    bus.write32(0x100004, 0x55667788);

    // 2. Setup SPU SRAM Address (1F801DA6h)
    // SPU address is in units of 8 bytes.
    bus.write16(0x1F801DA6, 0x0100);

    // 3. Enable DMA Channel 4 in DPCR
    // Bit 19 is enable for Channel 4
    bus.write32(0x1F8010F0, 1 << 19);

    // 4. Setup DMA Channel 4 (SPU)
    bus.write32(0x1F8010C0, 0x00100000); // MADR: Point to our data
    bus.write32(0x1F8010C4, 2); // BCR: Transfer 2 words (32-bit words)

    // CHCR: SyncMode=0, Dir=1 (RAM to Device), Step=0 (+4), Start=1, Trigger=1
    bus.write32(0x1F8010C8, (1 << 28) | (1 << 24) | (1 << 0));

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

    // 5. Verify data in SPU SRAM
    // 0x11223344 -> bytes 0x800, 0x801 (0x3344) and 0x802, 0x803 (0x1122)
    // 0x55667788 -> bytes 0x804, 0x805 (0x7788) and 0x806, 0x807 (0x5566)
    try expectEqual(@as(u16, 0x3344), std.mem.readInt(u16, bus.spu.sram[0x800..][0..2], .little));
    try expectEqual(@as(u16, 0x1122), std.mem.readInt(u16, bus.spu.sram[0x802..][0..2], .little));
    try expectEqual(@as(u16, 0x7788), std.mem.readInt(u16, bus.spu.sram[0x804..][0..2], .little));
    try expectEqual(@as(u16, 0x5566), std.mem.readInt(u16, bus.spu.sram[0x806..][0..2], .little));

    // Verify sram_addr register.
    // It should be (0x800 + 8) >> 3 = 0x808 >> 3 = 0x101.
    try expectEqual(@as(u16, 0x0101), bus.read16(0x1F801DA6));
}

test "SPU SRAM DMA Transfer (SPU to RAM)" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // 1. Prepare data in SPU SRAM (contiguously)
    std.mem.writeInt(u16, bus.spu.sram[0x1000..][0..2], 0xAAAA, .little);
    std.mem.writeInt(u16, bus.spu.sram[0x1002..][0..2], 0xBBBB, .little);

    // 2. Setup SPU SRAM Address (0x1000 >> 3 = 0x200)
    bus.write16(0x1F801DA6, 0x0200);

    // 3. Enable DMA Channel 4 in DPCR
    bus.write32(0x1F8010F0, 1 << 19);

    // 4. Setup DMA Channel 4 (SPU)
    bus.write32(0x1F8010C0, 0x001F0000); // MADR: Where to put data in RAM
    bus.write32(0x1F8010C4, 1); // BCR: Transfer 1 word

    // CHCR: SyncMode=0, Dir=0 (Device to RAM), Step=0 (+4), Start=1, Trigger=1
    bus.write32(0x1F8010C8, (1 << 28) | (1 << 24) | (0 << 0));

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

    // 5. Verify data in Main RAM
    try expectEqual(@as(u32, 0xBBBBAAAA), bus.read32(0x001F0000));
}

test "ADPCM Decoding logic - No Filter, No Shift" {
    // 16 bytes of ADPCM data
    // Byte 0: Shift Factor=12 (Shift=0), Filter=0
    var block = [_]u8{0} ** 16;
    block[0] = 0x0C;

    // Fill data with nibbles = 1
    for (2..16) |i| {
        block[i] = 0x11;
    }

    var old: i32 = 0;
    var older: i32 = 0;
    var out_pcm: [28]i16 = undefined;

    ps1_core.spu.decodeBlock(&block, &old, &older, &out_pcm);

    for (out_pcm) |sample| {
        try expectEqual(@as(i16, 1), sample);
    }
}

test "ADPCM Decoding logic - Shift 12" {
    var block = [_]u8{0} ** 16;
    block[0] = 0x00; // Shift Factor=0 (Shift=12), Filter=0

    for (2..16) |i| {
        block[i] = 0x11;
    }

    var old: i32 = 0;
    var older: i32 = 0;
    var out_pcm: [28]i16 = undefined;

    ps1_core.spu.decodeBlock(&block, &old, &older, &out_pcm);

    for (out_pcm) |sample| {
        try expectEqual(@as(i16, 4096), sample);
    }
}

test "ADPCM Decoding logic - Filter 1" {
    var block = [_]u8{0} ** 16;
    block[0] = 0x1C; // Shift Factor=12 (Shift=0), Filter=1 (f0=60, f1=0)

    for (2..16) |i| {
        block[i] = 0x11;
    }

    var old: i32 = 0;
    var older: i32 = 0;
    var out_pcm: [28]i16 = undefined;

    ps1_core.spu.decodeBlock(&block, &old, &older, &out_pcm);

    try expectEqual(@as(i16, 1), out_pcm[0]);
    try expectEqual(@as(i16, 2), out_pcm[1]);
    try expectEqual(@as(i16, 3), out_pcm[2]);
}

test "SPU IRQ Trigger on SRAM Write" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // Enable IRQ9 in SPUCNT (bit 6)
    bus.write16(0x1F801DAA, 1 << 6);

    // Set IRQ Address to 0x1000 bytes (0x1000 / 8 = 0x0200)
    bus.write16(0x1F801DA4, 0x0200);

    // Set SRAM write address to 0x1000 bytes
    bus.write16(0x1F801DA6, 0x0200);

    // The IRQ should NOT be triggered yet
    try expectEqual(@as(u16, 0), bus.read16(0x1F801DAE) & (1 << 6));

    // Write to 0x1000
    bus.write16(0x1F801DA8, 0x1234);

    // The IRQ SHOULD be triggered now
    try expectEqual(@as(u16, 1 << 6), bus.read16(0x1F801DAE) & (1 << 6));
}

test "SPU exponential release always reaches zero and frees the voice" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;
    const voice = &bus.spu.voices[0];

    // ADSR1: sustain level 15, fastest decay; ADSR2: exponential release (bit5)
    // with a mid-range release shift, which is what a game's SFX bank uses.
    voice.adsr1 = 0x000F;
    voice.adsr2 = 0x0020 | 0x000E;

    voice.keyOn();
    voice.current_ad_vol = 0x7FFF;
    voice.adsr_state = .Release;
    voice.adsr_cycles = 0;

    // Hardware's exponential decrease is guaranteed to move by at least one
    // step per tick, so a release always terminates. Give it far more ticks
    // than it can need (44.1kHz * ~10s) and require the voice to be freed.
    var i: usize = 0;
    while (i < 441_000 and voice.is_on) : (i += 1) voice.stepAdsr();

    try expectEqual(@as(i32, 0), voice.current_ad_vol);
    try expectEqual(false, voice.is_on);
    try expectEqual(ps1_core.spu.AdsrState.Off, voice.adsr_state);
}

// A CPU word read spanning 0x1F801DA8 covers two *registers* — the SPU RAM
// transfer FIFO at 0x1DA8 and SPUCNT at 0x1DAA — not two FIFO pops. Treating it
// as two pops is DMA4's behaviour, and applying it to CPU reads means SPUCNT can
// never be read back through an unaligned word load, which is exactly what
// `cpu/io-access-bitwidth` does (LWL/LWR at 0x1F801DAA).
test "SPU word read at 0x1F801DA8 returns the FIFO and SPUCNT, not two FIFO pops" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    bus.write16(0x1F801DAA, 0x5678); // SPUCNT

    try expectEqual(@as(u32, 0x5678), bus.read32(0x1F801DA8) >> 16);
}

// DMA4 still pulls two consecutive halfwords out of the SPU RAM transfer FIFO
// for each 32-bit word it moves.
test "SPU DMA word read pops two halfwords from the transfer FIFO" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const bus = ctx.bus;

    // Seed SPU RAM at byte 0x1000 with two known halfwords.
    bus.write16(0x1F801DA6, 0x0200); // transfer address = 0x1000 bytes
    bus.write16(0x1F801DA8, 0x1234);
    bus.write16(0x1F801DA8, 0xABCD);

    bus.write16(0x1F801DA6, 0x0200); // rewind
    try expectEqual(@as(u32, 0xABCD1234), bus.dmaRead32(0x1F801DA8));
}

/// Puts the SPU into the exact state reverb_golden.cpp used to produce the
/// goldens: zeroed SPU RAM, the synthetic preset in the 32 reverb registers,
/// the reverb volumes, the work-area base, and SPUCNT bit 7 (master reverb).
fn setupReverbFixture(bus: *Bus) void {
    const spu = &bus.spu;
    @memset(&spu.sram, 0);
    for (reverb_preset.regs, 0..) |v, i| {
        bus.write16(@intCast(0x1F801DC0 + i * 2), @bitCast(v));
    }
    bus.write16(0x1F801D84, @bitCast(reverb_preset.vol_l));
    bus.write16(0x1F801D86, @bitCast(reverb_preset.vol_r));
    bus.write16(0x1F801DA2, reverb_preset.base);
    bus.write16(0x1F801DAA, 0x0080); // SPUCNT: master reverb enable
}

fn goldenPair(golden: []const u8, i: usize) struct { l: i16, r: i16 } {
    return .{
        .l = std.mem.readInt(i16, golden[i * 4 ..][0..2], .little),
        .r = std.mem.readInt(i16, golden[i * 4 + 2 ..][0..2], .little),
    };
}

test "SPU reverb impulse response matches the Avocado golden" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    setupReverbFixture(ctx.bus);
    const spu = &ctx.bus.spu;

    try expectEqual(reverb_preset.sample_count * 4, reverb_impulse_golden.len);

    for (0..reverb_preset.sample_count) |i| {
        const in: i32 = if (i == 0) 0x4000 else 0;
        const got = spu.doReverb(in, in);
        const want = goldenPair(reverb_impulse_golden, i);
        if (got.l != want.l or got.r != want.r) {
            std.debug.print(
                "reverb impulse mismatch at sample {}: got ({}, {}) want ({}, {})\n",
                .{ i, got.l, got.r, want.l, want.r },
            );
            return error.TestExpectedEqual;
        }
    }
}

test "SPU reverb pseudo-random response matches the Avocado golden" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    setupReverbFixture(ctx.bus);
    const spu = &ctx.bus.spu;

    try expectEqual(reverb_preset.sample_count * 4, reverb_noise_golden.len);

    var lcg = reverb_preset.Lcg{};
    for (0..reverb_preset.sample_count) |i| {
        const l_in: i32 = lcg.next();
        const r_in: i32 = lcg.next();
        const got = spu.doReverb(l_in, r_in);
        const want = goldenPair(reverb_noise_golden, i);
        if (got.l != want.l or got.r != want.r) {
            std.debug.print(
                "reverb noise mismatch at sample {}: got ({}, {}) want ({}, {})\n",
                .{ i, got.l, got.r, want.l, want.r },
            );
            return error.TestExpectedEqual;
        }
    }
}

test "SPU writing the reverb base resets the reverb write cursor" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const spu = &ctx.bus.spu;

    spu.reverb_curr_addr = 0x12345;
    ctx.bus.write16(0x1F801DA2, 0xFF80);

    try expectEqual(@as(u16, 0xFF80), spu.reverb_base);
    try expectEqual(@as(u32, 0xFF80) * 8, spu.reverb_curr_addr);
}

test "SPU reverb master disable stops SRAM writes but not reads or the cursor" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    setupReverbFixture(ctx.bus);
    const spu = &ctx.bus.spu;

    // Seed the work area. With a zeroed buffer every read returns 0 and the
    // output would be 0 whether or not the gate works, so the test would prove
    // nothing.
    const area_start: usize = @as(usize, reverb_preset.base) * 8;
    var seed: u16 = 0x1234;
    var a = area_start;
    while (a + 1 < spu.sram.len) : (a += 2) {
        std.mem.writeInt(u16, spu.sram[a..][0..2], seed, .little);
        seed = seed *% 3 +% 1;
    }
    var before: [0x400]u8 = undefined;
    @memcpy(&before, spu.sram[area_start..][0..0x400]);

    ctx.bus.write16(0x1F801DAA, 0x0000); // SPUCNT: master reverb OFF
    const addr_before = spu.reverb_curr_addr;

    const out = spu.doReverb(0x4000, 0x4000);

    try std.testing.expectEqualSlices(u8, &before, spu.sram[area_start..][0..0x400]);
    try expectEqual(addr_before + 2, spu.reverb_curr_addr);
    try std.testing.expect(out.l != 0 or out.r != 0);
}

test "SPU reverb runs at half rate and holds its output across the sample pair" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    setupReverbFixture(ctx.bus);
    const spu = &ctx.bus.spu;
    spu.reverb_counter = 0;

    // reverb_curr_addr advances by 2 per doReverb call, so it is the observable
    // for "the reverb ran" -- no test hook needed.
    const addr0 = spu.reverb_curr_addr;
    spu.step(768); // even sample: doReverb runs
    const addr1 = spu.reverb_curr_addr;
    const held_l = spu.reverb_out_l;
    const held_r = spu.reverb_out_r;
    spu.step(768); // odd sample: output re-used, doReverb does not run
    const addr2 = spu.reverb_curr_addr;

    try expectEqual(addr0 + 2, addr1);
    try expectEqual(addr1, addr2);
    try expectEqual(held_l, spu.reverb_out_l);
    try expectEqual(held_r, spu.reverb_out_r);
}

test "SPU reverb_enable false leaves the reverb stage completely inert" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    setupReverbFixture(ctx.bus);
    const spu = &ctx.bus.spu;
    spu.reverb_enable = false;

    const area_start: usize = @as(usize, reverb_preset.base) * 8;
    var before: [0x400]u8 = undefined;
    @memcpy(&before, spu.sram[area_start..][0..0x400]);
    const addr_before = spu.reverb_curr_addr;

    for (0..16) |_| spu.step(768);

    try expectEqual(@as(i32, 0), spu.reverb_out_l);
    try expectEqual(@as(i32, 0), spu.reverb_out_r);
    try expectEqual(addr_before, spu.reverb_curr_addr);
    try std.testing.expectEqualSlices(u8, &before, spu.sram[area_start..][0..0x400]);
}

test "SPU CD audio reaches the reverb send only when SPUCNT bits 0 and 2 are set" {
    // A single sample proves nothing: with a zeroed work area the signal needs
    // many passes to reach the comb taps, so both cases would read 0. Run long
    // enough for the send to show up in the output.
    const passes = 512;

    { // bits 0 (cdEnable) + 7 (master), but NOT bit 2 (cdReverb)
        var ctx = try TestContext.init();
        defer ctx.deinit();
        setupReverbFixture(ctx.bus);
        const spu = &ctx.bus.spu;
        spu.cd_vol_l = 0x3FFF;
        spu.cd_vol_r = 0x3FFF;
        ctx.bus.write16(0x1F801DAA, 0x0081);
        spu.pushCdAudio(0x4000, 0x4000);

        for (0..passes) |_| spu.step(768);

        try expectEqual(@as(i32, 0), spu.reverb_out_l);
        try expectEqual(@as(i32, 0), spu.reverb_out_r);
    }

    { // bits 0 + 2 + 7
        var ctx = try TestContext.init();
        defer ctx.deinit();
        setupReverbFixture(ctx.bus);
        const spu = &ctx.bus.spu;
        spu.cd_vol_l = 0x3FFF;
        spu.cd_vol_r = 0x3FFF;
        ctx.bus.write16(0x1F801DAA, 0x0085);
        spu.pushCdAudio(0x4000, 0x4000);

        for (0..passes) |_| spu.step(768);

        try std.testing.expect(spu.reverb_out_l != 0 or spu.reverb_out_r != 0);
    }
}
