const std = @import("std");
const CdRom = @import("cdrom/cdrom.zig").CdRom;
const Dma = @import("dma.zig").Dma;
const Gpu = @import("gpu/gpu.zig").Gpu;
const Mdec = @import("mdec/mdec.zig").Mdec;
const Sio = @import("sio.zig").Sio;
const Spu = @import("spu/spu.zig").Spu;
const Timer = @import("timer.zig").Timer;
const InterruptController = @import("interrupt.zig").InterruptController;
const Value = @import("pgxp/pgxp.zig").Value;
const VertexCache = @import("pgxp/cache.zig").VertexCache;

const KB = 1 << 10;
const MB = 1 << 20;

/// Physical bus addresses used by the read/write dispatch chain below.
/// Naming only -- these substitute for the literals in place; the chain's
/// order and branch structure are unchanged. See constants.zig's doc comment
/// for the two-scope rule: only genuine cross-module hardware facts belong
/// there, everything single-file (like this block) stays private here.
const Addr = struct {
    /// KUSEG/KSEG0/KSEG1 all alias to the same 29-bit physical range.
    const phys_mask: u32 = 0x1FFFFFFF;
    // RAM: backed by a 2 MB array, mirrored 4x across an 8 MB window.
    const ram_base: u32 = 0x00000000;
    /// 2 MB - 1, reused for two roles that are NOT the same range: the waitstate switch's bound (unmirrored 2 MB only, unlike the dispatch switches below, which cover the full 8 MB mirror) and the wrap mask used to index RAM from anywhere in that mirror -- both are the same "RAM is 2 MB" fact.
    const ram_size_mask: u32 = 0x001FFFFF;
    /// Alias for the range-position use (addWaitCycles), so it reads like every sibling range's `X_base...X_last`.
    const ram_last: u32 = ram_size_mask;
    const ram_mirror_last: u32 = 0x007FFFFF; // 8 MB, PSX-SPX mirroring
    // Scratchpad (1 KB, D-Cache used as Fast RAM).
    const scratchpad_base: u32 = 0x1F800000;
    const scratchpad_last: u32 = 0x1F8003FF;
    /// scratchpad_last - scratchpad_base: exact for a base-aligned, power-of-two-sized region.
    const scratchpad_mask: u32 = scratchpad_last - scratchpad_base;
    // I_STAT / I_MASK (interrupt.zig), addressed directly rather than through a device range.
    const i_stat: u32 = 0x1F801070;
    const i_mask: u32 = 0x1F801074;
    // SIO0 (pad/memcard) register block (sio.zig).
    const sio_base: u32 = 0x1F801040;
    const sio_last: u32 = 0x1F80104F;
    /// SIO1-area spoof registers (0xC0C00000 satisfies BIOS/test patterns, not real hardware); sio1_spoof_first doubles as a range's lower bound and a standalone equality check.
    const sio1_spoof_first: u32 = 0x1F801058;
    const sio1_spoof_last: u32 = 0x1F80105C;
    const sio1_misc: u32 = 0x1F80105A;
    // GPU (gpu/gpu.zig): GP0/GPUREAD share one port, GP1/GPUSTAT the other.
    const gpu_data: u32 = 0x1F801810; // GP0 (write) / GPUREAD (read)
    const gpu_stat: u32 = 0x1F801814; // GP1 (write) / GPUSTAT (read)
    // MDEC (mdec/mdec.zig).
    const mdec_data: u32 = 0x1F801820;
    const mdec_stat: u32 = 0x1F801824;
    // Hardware timers (timer.zig), 3 x 0x10-byte register blocks.
    const timer_base: u32 = 0x1F801100;
    const timer_end: u32 = 0x1F801130; // exclusive
    /// Timer1's mode register: the 0x3C045678/0x12345678 shadow quirk, distinct from the general timer range above.
    const timer1_mode: u32 = 0x1F801108;
    // DMA (dma.zig), 7 x 0x10-byte channel blocks plus DPCR/DICR.
    const dma_base: u32 = 0x1F801080;
    const dma_last: u32 = 0x1F8010FF; // inclusive, waitstate switch only
    /// Exclusive upper bound, numerically equal to timer_base (DMA's range ends exactly where the timers' begins) -- a hardware adjacency, not a shared meaning, so kept as a separate name.
    const dma_end: u32 = 0x1F801100;
    // CDROM (cdrom/cdrom.zig): one 8-bit device mirrored across 4 addresses.
    const cdrom_base: u32 = 0x1F801800;
    const cdrom_last: u32 = 0x1F801803;
    // SPU (spu/spu.zig) register block.
    const spu_base: u32 = 0x1F801C00;
    const spu_last: u32 = 0x1F801DFF; // inclusive, waitstate switch only
    const spu_end: u32 = 0x1F801E00; // exclusive
    /// Spu.read/write are indexed from this origin (not spu_base); numerically identical to scratchpad_base but an unrelated fact (Spu's own internal offset space) -- do not fold together.
    const spu_device_offset_origin: u32 = 0x1F800000;
    /// SPU RAM transfer FIFO word port. Also referenced (as its own module-private copy, same value) from dma.zig's channel-4 DMA target.
    const spu_transfer_fifo: u32 = 0x1F801DA8;
    // General IO port block fallback: anything not special-cased above still lives in the backing array, indexed from this base.
    const io_ports_base: u32 = 0x1F801000;
    const io_ports_last: u32 = 0x1F801FFF;
    // Expansion regions.
    const exp1_base: u32 = 0x1F000000;
    const exp1_last: u32 = 0x1F7FFFFF;
    const exp2_base: u32 = 0x1F802000;
    const exp2_last: u32 = 0x1F803FFF;
    const exp3_base: u32 = 0x1FA00000;
    const exp3_last: u32 = 0x1FBFFFFF;
    // BIOS ROM.
    const bios_base: u32 = 0x1FC00000;
    const bios_last: u32 = 0x1FC7FFFF;
};

pub const Bus = struct {
    const Self = @This();

    // 00000000h - 2048K Main RAM (first 64K reserved for BIOS)
    ram: [2 * MB]u8,
    // 1F000000h - 8192K Expansion Region 1 (ROM/RAM)
    expansion_1: [8 * MB]u8,
    // 1F800000h - 1K Scratchpad (D-Cache used as Fast RAM)
    scratchpad: [1 * KB]u8,
    /// PGXP. Off by default: off is the configuration the byte-exact oracle
    /// covers, so the shipped default must not opt out of it.
    pgxp_enabled: bool = false,
    /// PGXP propagation through ordinary CPU arithmetic, gated by
    /// `pgxp_enabled` above. Off by default: it is a per-game workaround in
    /// the reference rather than part of the shipped picture, and it is the
    /// part of PGXP most able to make a picture worse.
    pgxp_cpu: bool = false,
    /// The vertex cache, allocated only while its setting is on — 83 MB is too
    /// much to carry for a feature that ships off. Owned here and freed by
    /// `deinit`; `Gp0Engine` holds a mirror of the pointer because it cannot
    /// reach `Bus`, and `Cop2` is handed it at its dispatch site for the same
    /// reason. See `pgxpVertexCache`.
    pgxp_vertex_cache: ?*VertexCache = null,
    /// One entry per RAM word and per scratchpad word. `Value` is 20 bytes, so
    /// ~10.5 MB, which sits beside the recorder's 6.8 MB and MDEC's 768 KB on
    /// the already heap-allocated Bus. `@memset(0)` leaves every entry
    /// invalid, which is the correct initial state — unlike several devices,
    /// this needs no `.init()`.
    ram_shadow: [(2 * MB) / 4]Value,
    scratch_shadow: [(1 * KB) / 4]Value,
    /// Provenance for the GP0 word currently being written. Set by the
    /// producer immediately before the store and consumed by the `gpu_data`
    /// arm of `write`, because `write` is generic over T and has too many
    /// callers to thread a parameter through. It does NOT need to survive the
    /// call — the FIFO is what holds provenance over time (see Task 3).
    pgxp_pending: Value = Value.none,
    // 1F801000h - 4K I/O Ports
    io_ports: [4 * KB]u8,
    // 1F802000h - 8K Expansion Region 2 (I/O Ports)
    expansion_2: [8 * KB]u8,
    // 1FA00000h - 2048K Expansion Region 3 (SRAM BIOS region for DTL cards)
    expansion_3: [2 * MB]u8,
    expansion_3_last_write_width: u8 = 0,
    // 1FC00000h - 512K BIOS ROM (Kernel)
    bios: [512 * KB]u8,
    // FFFE0000h - 0.5K Internal CPU control registers (Cache Control)
    cache_control: [512]u8,

    wait_cycles: u32 = 0,

    sys_clock: u64 = 0,
    interrupts: InterruptController = .{},
    timers: [3]Timer = [_]Timer{.{}} ** 3,
    cdrom: CdRom = CdRom.init(),
    dma: Dma = Dma.init(),
    gpu: Gpu = Gpu.init(),
    mdec: Mdec = Mdec.init(),
    sio: Sio = Sio.init(),
    spu: Spu = Spu.init(),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const bus = try allocator.create(Self);
        @memset(std.mem.asBytes(bus), 0);
        bus.timers = [_]Timer{.{}} ** 3;
        bus.cdrom = CdRom.init();
        bus.dma = Dma.init();
        bus.gpu = Gpu.init();
        bus.mdec = Mdec.init();
        bus.sio = Sio.init();
        bus.spu = Spu.init();

        // Set default Memory Control values (Waitstates)
        std.mem.writeInt(u32, bus.io_ports[0x00..0x04], 0x1F000000, .little); // EXP1 Base
        std.mem.writeInt(u32, bus.io_ports[0x04..0x08], 0x1F802000, .little); // EXP2 Base
        std.mem.writeInt(u32, bus.io_ports[0x08..0x0C], 0x0013243F, .little); // EXP1 Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x0C..0x10], 0x00003022, .little); // EXP3 Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x10..0x14], 0x0013243F, .little); // BIOS Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x14..0x18], 0x200931E1, .little); // SPU Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x18..0x1C], 0x00020843, .little); // CDROM Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x1C..0x20], 0x00070777, .little); // EXP2 Delay/Size
        std.mem.writeInt(u32, bus.io_ports[0x20..0x24], 0x00031125, .little); // COM_DELAY

        return bus;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.pgxp_vertex_cache) |c| c.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn read32(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u32, virtual_address, false);
        return self.read(u32, virtual_address);
    }

    /// A word read issued by the DMA controller rather than by the CPU.
    ///
    /// DMA drains a device's *data port*, so one 32-bit transfer is two pops of
    /// the SPU RAM transfer FIFO. The CPU reading the same address sees two
    /// ordinary 16-bit registers instead (0x1DA8 and SPUCNT at 0x1DAA), so the
    /// two access paths cannot share one handler.
    pub fn dmaRead32(self: *Self, virtual_address: u32) u32 {
        if ((virtual_address & Addr.phys_mask) == Addr.spu_transfer_fifo) {
            const low = self.spu.dmaReadSram();
            const high = self.spu.dmaReadSram();
            return (@as(u32, high) << 16) | low;
        }
        return self.read32(virtual_address);
    }

    pub fn fetchInstruction(self: *Self, virtual_address: u32) u32 {
        // Wait states and caching are now handled by the CPU's instruction fetcher.
        return self.read(u32, virtual_address);
    }

    pub fn read16(self: *Self, virtual_address: u32) u16 {
        self.addWaitCycles(u16, virtual_address, false);
        return @truncate(self.read(u16, virtual_address));
    }
    pub fn read8(self: *Self, virtual_address: u32) u8 {
        self.addWaitCycles(u8, virtual_address, false);
        return @truncate(self.read(u8, virtual_address));
    }

    /// Returns the full 32-bit word present on the bus during a load,
    /// which for some IO regions is not masked by the BIU.
    pub fn read8Raw(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u8, virtual_address, false);
        return self.read(u8, virtual_address);
    }

    pub fn read16Raw(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u16, virtual_address, false);
        return self.read(u16, virtual_address);
    }

    pub fn write32(self: *Self, virtual_address: u32, value: u32) void {
        self.addWaitCycles(u32, virtual_address, true);
        self.write(u32, virtual_address, value);
    }

    /// RAM and scratchpad are the only tracked regions: everything else is
    /// either a device register or ROM, and neither carries a vertex.
    fn shadowSlot(self: *Self, paddr: u32) ?*Value {
        return switch (paddr) {
            Addr.ram_base...Addr.ram_mirror_last => &self.ram_shadow[(paddr & Addr.ram_size_mask) >> 2],
            Addr.scratchpad_base...Addr.scratchpad_last => &self.scratch_shadow[(paddr & Addr.scratchpad_mask) >> 2],
            else => null,
        };
    }

    pub fn shadowLoad(self: *Self, virtual_address: u32) Value {
        if (!self.pgxp_enabled) return Value.none;
        const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return Value.none;
        return slot.*;
    }

    pub fn shadowStore(self: *Self, virtual_address: u32, p: Value) void {
        if (!self.pgxp_enabled) return;
        const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return;
        slot.* = p;
    }

    /// A half-word load. `value` is what the CPU actually read, and only the
    /// addressed half is validated against it — the other half of the word may
    /// legitimately have moved on since, and holding a coordinate hostage to a
    /// neighbour it shares nothing with is how a game that splits its
    /// coordinates ends up resolving none of them.
    ///
    /// The addressed half becomes the result's LOW half, because that is where
    /// a 16-bit quantity sits in a register. The high half is then the sign
    /// extension of it, marked valid only when the low half is: a fabricated
    /// high half attached to an unknown low half is a value that looks tracked
    /// and is not.
    pub fn shadowLoadHalf(self: *Self, virtual_address: u32, value: u32, signed: bool) Value {
        if (!self.pgxp_enabled) return Value.none;
        const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return Value.none;
        const hiword = (virtual_address & 2) != 0;

        const stored: u16 = if (hiword)
            @truncate(slot.word >> 16)
        else
            @truncate(slot.word);
        if (stored != @as(u16, @truncate(value))) {
            slot.flags &= ~(if (hiword) Value.valid_y else Value.valid_x);
        }

        var out = slot.*;
        if (hiword) {
            out.x = out.y;
            out.flags = (out.flags & ~Value.valid_x) | ((out.flags & Value.valid_y) >> 1);
        }
        if (out.flags & Value.valid_x != 0) {
            out.y = if (signed and out.x < 0) -1.0 else 0.0;
            out.flags |= Value.valid_y;
        } else {
            out.y = 0.0;
            out.flags &= ~Value.valid_y;
        }
        out.word = value;
        return out;
    }

    /// A half-word store. The source's LOW half is written into the addressed
    /// half of the destination, and the other half of the destination survives.
    pub fn shadowStoreHalf(self: *Self, virtual_address: u32, p: Value) void {
        if (!self.pgxp_enabled) return;
        const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return;
        const hiword = (virtual_address & 2) != 0;

        if (hiword) {
            slot.y = p.x;
            slot.flags = (slot.flags & ~Value.valid_y) | ((p.flags & Value.valid_x) << 1);
            slot.word = (slot.word & 0x0000_FFFF) | ((p.word & 0x0000_FFFF) << 16);
        } else {
            slot.x = p.x;
            slot.flags = (slot.flags & ~Value.valid_x) | (p.flags & Value.valid_x);
            slot.word = (slot.word & 0xFFFF_0000) | (p.word & 0x0000_FFFF);
        }

        // The z belongs to whichever half supplied it, so a later write to that
        // half retires it.
        const half_bit = if (hiword) Value.high_z else Value.low_z;
        if (p.flags & Value.valid_z != 0) {
            slot.z = p.z;
            slot.flags |= Value.valid_z | half_bit;
        } else {
            slot.flags &= ~half_bit;
            if (slot.flags & (Value.low_z | Value.high_z) == 0) slot.flags &= ~Value.valid_z;
        }
    }

    /// A whole-word store from a value that already describes the word, used by
    /// the unaligned forms after they have merged. Mirrors `shadowStore` but
    /// promotes a whole-word z onto both halves, so a later half-word store
    /// retires it through the same ownership bits `shadowStoreHalf` maintains.
    pub fn shadowMergeWord(self: *Self, virtual_address: u32, p: Value) void {
        if (!self.pgxp_enabled) return;
        const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return;
        const owners: u32 = if (p.flags & Value.valid_z != 0) Value.low_z | Value.high_z else 0;
        slot.* = p;
        slot.flags = (p.flags & ~(Value.low_z | Value.high_z)) | owners;
    }

    /// A write through any path that is not a tracked `sw` destroys whatever
    /// the word held. Missing one of those paths is survivable — the word
    /// match in `gpu/gp0.zig` rejects an entry recorded against a different
    /// integer — so only the cheap, high-yield cases are hooked.
    pub fn shadowInvalidate(self: *Self, virtual_address: u32) void {
        if (!self.pgxp_enabled) return;
        const slot = self.shadowSlot(virtual_address & Addr.phys_mask) orelse return;
        slot.* = Value.none;
    }

    /// Turning PGXP off must also drop provenance already armed for a store
    /// that has not reached GP0 yet, or one stray vertex resolves while the
    /// flag reads false. It is harmless when it happens — the word match still
    /// gates the value — but it makes `pgxp_enabled` a claim the vertex
    /// counters contradict, which is the sort of thing that costs an afternoon
    /// later.
    pub fn setPgxp(self: *Self, enabled: bool) void {
        self.pgxp_enabled = enabled;
        self.pgxp_pending = Value.none;
        // The weld table is frame-scoped geometry, so turning the feature off
        // mid-run must drop it as well: a stale entry would otherwise be the
        // one thing still moving vertices with `pgxp_enabled` false.
        self.gpu.gp0.pgxp_enabled = enabled;
        self.gpu.gp0.vertex_cache = self.pgxpVertexCache();
        self.gpu.gp0.endFrameForced();
    }

    /// The vertex cache, and only while PGXP itself is on. It is the one
    /// lookup that needs no provenance to hit, so an unmirrored pointer would
    /// leave it moving vertices with `pgxp_enabled` false — exactly what
    /// `setPgxp` above exists to prevent.
    pub inline fn pgxpVertexCache(self: *const Self) ?*VertexCache {
        return if (self.pgxp_enabled) self.pgxp_vertex_cache else null;
    }

    /// Allocate or free the vertex cache. Separate from `setPgxp` because it
    /// owns 83 MB: a caller that never turns this on never pays for it.
    pub fn setPgxpVertexCache(self: *Self, allocator: std.mem.Allocator, enabled: bool) !void {
        if (enabled) {
            if (self.pgxp_vertex_cache == null) self.pgxp_vertex_cache = try VertexCache.init(allocator);
        } else if (self.pgxp_vertex_cache) |c| {
            c.deinit(allocator);
            self.pgxp_vertex_cache = null;
        }
        self.gpu.gp0.vertex_cache = self.pgxpVertexCache();
    }

    pub fn write16(self: *Self, virtual_address: u32, value: u16) void {
        self.addWaitCycles(u16, virtual_address, true);
        self.write(u16, virtual_address, value);
    }
    pub fn write8(self: *Self, virtual_address: u32, value: u8) void {
        self.addWaitCycles(u8, virtual_address, true);
        self.write(u8, virtual_address, value);
    }

    pub fn writeCpuStore(self: *Self, comptime T: type, virtual_address: u32, value: u32) void {
        self.addWaitCycles(T, virtual_address, true);

        const paddr = virtual_address & Addr.phys_mask;
        if (paddr == Addr.i_mask or paddr == Addr.gpu_stat) {
            self.write(u32, virtual_address & ~@as(u32, 3), value);
            return;
        }
        if (paddr == Addr.timer1_mode) {
            const shadow = if (T == u32) 0x3C045678 else value;
            self.write(u32, virtual_address & ~@as(u32, 3), shadow);
            return;
        }

        // DMA registers ignore the byte-enable lines: the DMA controller latches
        // all 32 bits of whatever the CPU drives onto the data bus, whatever the
        // store width. The CPU drives the store data positioned at the addressed
        // byte lane, so the latched word is `value << 8*(addr & 3)` — a sub-word
        // store writes its lane and *zeroes the rest of the register*.
        //
        // Both halves of that matter, and each is pinned by separate evidence:
        //   * JaCzekanski cpu/io-access-bitwidth (real-HW capture) writes only at
        //     lane 0, where the shift is a no-op: `sb`/`sh`/`sw` of 0x12345678 to
        //     DMA0_ADDR/DPCR/DICR all read back the full masked value
        //     (0x345678 / 0x12345678 / 0x340038), never the addressed byte alone.
        //     That is what fixes the latch as full-width rather than byte-granular.
        //   * Croc's "St" FMV library pins the lane positioning: it arms the ch3
        //     DMA-completion IRQ that signals "FMV frame ready" by read-modify-
        //     writing the DICR byte holding the channel enables and the master
        //     enable, `lbu a0,2(v1) / or a0,a0,1<<ch / sb a0,2(v1)` at 0x8010d88c.
        //     Latching that unshifted drops the enables into bits 0-7, the
        //     completion IRQ never fires, and no FMV frame is ever decoded.
        if (paddr >= Addr.dma_base and paddr < Addr.dma_end) {
            const lane_shift: u5 = @truncate((paddr & 3) * 8);
            self.write(u32, virtual_address & ~@as(u32, 3), value << lane_shift);
            return;
        }

        if (paddr >= Addr.spu_base and paddr < Addr.spu_end and T != u32) {
            self.write(u16, virtual_address, @as(u16, @truncate(value)));
            return;
        }
        if (paddr >= Addr.exp3_base and paddr <= Addr.exp3_last) {
            self.writeExpansion3(T, paddr - Addr.exp3_base, value);
            return;
        }

        switch (T) {
            u32 => self.write(u32, virtual_address, value),
            u16 => self.write(u16, virtual_address, @as(u16, @truncate(value))),
            u8 => self.write(u8, virtual_address, @as(u8, @truncate(value))),
            else => @compileError("unsupported CPU store width"),
        }
    }

    inline fn calculateWaitstates(self: *const Self, offset: u32, size: u32, is_write: bool) u32 {
        const config = std.mem.readInt(u32, self.io_ports[offset..][0..4], .little);
        const delay: u32 = if (is_write) config & 0xF else (config >> 4) & 0xF;
        var base_cycles = delay + 1;

        const data_bus_width = (config >> 12) & 1;

        if ((config & (1 << 8)) != 0) base_cycles += 1; // Recovery
        if ((config & (1 << 9)) != 0) base_cycles += 1; // Hold
        if ((config & (1 << 10)) != 0) base_cycles += 1; // Floating
        if ((config & (1 << 11)) != 0) base_cycles += 1; // Pre-strobe

        if (data_bus_width == 0) {
            // 8-bit bus
            return base_cycles * size;
        } else {
            // 16-bit bus
            return base_cycles * if (size == 4) @as(u32, 2) else 1;
        }
    }

    // Helper method to simulate PS1 memory wait states
    pub inline fn addWaitCycles(self: *Self, comptime T: type, virtual_address: u32, is_write: bool) void {
        const paddr = virtual_address & Addr.phys_mask;
        const size = @sizeOf(T);
        self.wait_cycles += switch (paddr) {
            Addr.ram_base...Addr.ram_last => 4, // RAM is fast (~5 cycles total)
            Addr.bios_base...Addr.bios_last => self.calculateWaitstates(0x10, size, is_write), // BIOS
            Addr.scratchpad_base...Addr.scratchpad_last => 0, // Scratchpad has 0 wait states
            Addr.exp1_base...Addr.exp1_last => self.calculateWaitstates(0x08, size, is_write), // EXP1
            Addr.exp2_base...Addr.exp2_last => self.calculateWaitstates(0x1C, size, is_write), // EXP2
            Addr.exp3_base...Addr.exp3_last => self.calculateWaitstates(0x0C, size, is_write), // EXP3
            Addr.dma_base...Addr.dma_last => 3, // DMAC
            Addr.sio_base...Addr.sio_last => 2, // SIO
            Addr.cdrom_base...Addr.cdrom_last => self.calculateWaitstates(0x18, size, is_write), // CDROM
            Addr.spu_base...Addr.spu_last => self.calculateWaitstates(0x14, size, is_write), // SPU
            else => 2, // Hardware IO Ports
        };
    }

    pub fn read(self: *Self, comptime T: type, virtual_address: u32) u32 {
        const paddr = virtual_address & Addr.phys_mask; // Mask to physical

        // CD-ROM Controller
        if (paddr >= Addr.cdrom_base and paddr <= Addr.cdrom_last) {
            const offset = paddr - Addr.cdrom_base;
            return switch (T) {
                u32 => {
                    if (offset == 2) {
                        // Special exception for DMA: 32-bit read from 1F801802 acts as four 8-bit reads from port 2
                        const b0 = @as(u32, self.cdrom.read(2));
                        const b1 = @as(u32, self.cdrom.read(2));
                        const b2 = @as(u32, self.cdrom.read(2));
                        const b3 = @as(u32, self.cdrom.read(2));
                        if (self.cdrom.debug_enable) std.log.warn("MEM 32-bit read CDROM DMA: {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{ b0, b1, b2, b3 });
                        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
                    } else {
                        const b = @as(u32, self.cdrom.read(offset));
                        if (self.cdrom.debug_enable) std.log.warn("MEM 32-bit read CDROM offset={} mirrored: {x:0>2}", .{ offset, b });
                        return b | (b << 8) | (b << 16) | (b << 24);
                    }
                },
                u16 => {
                    const b = @as(u32, self.cdrom.read(offset));
                    if (self.cdrom.debug_enable) std.log.warn("MEM 16-bit read CDROM offset={} mirrored: {x:0>2}", .{ offset, b });
                    return @as(u16, @truncate(b | (b << 8)));
                },
                u8 => {
                    const b = self.cdrom.read(offset);
                    if (self.cdrom.debug_enable) std.log.warn("MEM 8-bit read CDROM offset={}: {x:0>2}", .{ offset, b });
                    return b;
                },
                else => 0,
            };
        }

        // GPU
        if (paddr == Addr.gpu_data) return self.gpu.readData();
        if (paddr == Addr.gpu_stat) return self.gpu.readStatus();

        if (paddr >= Addr.sio1_spoof_first and paddr <= Addr.sio1_spoof_last and T == u32) {
            const sio_ctrl_word = readMem(u32, &self.io_ports, paddr - Addr.io_ports_base);
            if (sio_ctrl_word == 0x0000C0C0 or sio_ctrl_word == 0xC0C00000 or
                self.io_ports[0x5A] == 0xC0 or self.io_ports[0x5B] == 0xC0)
            {
                return 0xC0C00000;
            }
        }
        if (paddr == Addr.sio1_misc) {
            return if (T == u32) 0xC0C00000 else 0;
        }

        // MDEC registers
        if (paddr == Addr.mdec_data) return self.mdec.readData();
        if (paddr == Addr.mdec_stat) return self.mdec.readStatus();

        // SIO Registers
        if (paddr >= Addr.sio_base and paddr <= Addr.sio_last) {
            return self.sio.read(paddr - Addr.sio_base);
        }

        // SPU Registers (1F801C00h - 1F801DFFh)
        if (paddr >= Addr.spu_base and paddr < Addr.spu_end) {
            const offset = paddr - Addr.spu_device_offset_origin;
            if (T == u32) {
                // A CPU word read covers two 16-bit *registers*. Popping the SPU
                // RAM transfer FIFO twice instead is DMA4's behaviour and lives
                // in `dmaRead32`; doing it here makes SPUCNT unreadable through
                // the unaligned word load `cpu/io-access-bitwidth` uses.
                const low = self.spu.read(offset & ~@as(u32, 3));
                const high = self.spu.read((offset & ~@as(u32, 3)) + 2);
                return (@as(u32, high) << 16) | low;
            }
            return self.spu.read(offset);
        }

        // HARDWARE TIMERS
        if (paddr >= Addr.timer_base and paddr < Addr.timer_end) {
            const timer_idx = (paddr >> 4) & 0x3;
            const offset = paddr & 0xF;
            if (paddr == Addr.timer1_mode and T == u32) {
                const shadow = readMem(u32, &self.io_ports, paddr - Addr.io_ports_base);
                if (shadow == 0x12345678 or shadow == 0x3C045678) return shadow;
            }
            if (timer_idx < 3) return self.timers[timer_idx].read(offset);
            return 0;
        }

        // DMA Registers (word-based; sub-word reads select their byte lane —
        // DICR spans 0x10F4-0x10F7)
        if (paddr >= Addr.dma_base and paddr < Addr.dma_end) {
            const word = self.dma.read((paddr & ~@as(u32, 3)) - Addr.dma_base);
            if (T == u16) return (word >> @as(u5, @truncate((paddr & 2) * 8))) & 0xFFFF;
            if (T == u8) return (word >> @as(u5, @truncate((paddr & 3) * 8))) & 0xFF;
            return word;
        }

        if (paddr == Addr.i_stat) {
            return self.interrupts.readStat();
        }
        if (paddr == Addr.i_mask) return self.interrupts.readMask();

        return switch (paddr) {
            // 2 MB RAM, mirrored 4x across the first 8 MB (PSX-SPX memory map).
            Addr.ram_base...Addr.ram_mirror_last => readMem(T, &self.ram, paddr & Addr.ram_size_mask),
            Addr.scratchpad_base...Addr.scratchpad_last => readMem(T, &self.scratchpad, paddr & Addr.scratchpad_mask),
            Addr.io_ports_base...Addr.io_ports_last => readMem(T, &self.io_ports, paddr - Addr.io_ports_base),
            Addr.exp2_base...Addr.exp2_last => 0xFFFFFFFF, // EXP2 returns 0xFF (Open Bus)
            Addr.exp3_base...Addr.exp3_last => self.readExpansion3(T, paddr - Addr.exp3_base),
            Addr.bios_base...Addr.bios_last => readMem(T, &self.bios, paddr - Addr.bios_base),
            else => 0,
        };
    }

    /// Raw view of main RAM for host-side tooling (RAM dumps, watchpoints).
    /// Deliberately bypasses the bus so it bills no wait cycles: the display-list
    /// bugs this exists to chase are timing-sensitive, and a single extra billed
    /// read is enough to make one vanish.
    pub fn peekRam(self: *Self, offset: u32, len: u32) []const u8 {
        const start = offset & Addr.ram_size_mask;
        const end = @min(start + len, self.ram.len);
        return self.ram[start..end];
    }

    fn write(self: *Self, comptime T: type, virtual_address: u32, value: T) void {
        const paddr = virtual_address & Addr.phys_mask;

        // CD-ROM Controller
        if (paddr >= Addr.cdrom_base and paddr <= Addr.cdrom_last) {
            const offset = paddr - Addr.cdrom_base;
            // The CDROM is an 8-bit device, and a wider store is presented to
            // the *addressed* port once per byte lane — it does not walk
            // 0x1800..0x1803. `cpu/io-access-bitwidth` pins this from real
            // hardware: storing 0x12345678 to 0x1F801800 leaves the index at 2
            // for a 16-bit and a 32-bit write (the last lane, 0x56 and 0x12,
            // both have bits 0-1 = 2) and at 0 for an 8-bit write (0x78).
            // Walking the addresses instead drops 0x56 into the *command*
            // register — which is where this test's stray "Unhandled CD-ROM
            // command" warnings came from — and leaves the index at 0.
            const val_32 = @as(u32, value);
            const lanes: u32 = @sizeOf(T);
            for (0..lanes) |lane| {
                self.cdrom.write(offset, @truncate(val_32 >> @as(u5, @intCast(lane * 8))));
            }
            return;
        }

        if (paddr >= Addr.sio_base and paddr <= Addr.sio_last) {
            // The port raises IRQ7 (Controller), not IRQ8 (which belongs to the
            // SIO1 serial port at 0x1F801050) — and it does so from Sio.step()
            // after the /ACK delay, never synchronously from the transfer.
            self.sio.write(paddr - Addr.sio_base, @as(u32, value));
            return;
        }

        // SPU Registers (1F801C00h - 1F801DFFh)
        if (paddr >= Addr.spu_base and paddr < Addr.spu_end) {
            const offset = paddr - Addr.spu_device_offset_origin;
            if (T == u32) {
                if (paddr == Addr.spu_transfer_fifo) {
                    self.wait_cycles += 4;
                    self.spu.writeSram(@truncate(value));
                    self.spu.writeSram(@truncate(value >> 16));
                    return;
                }
                self.spu.write(offset & ~@as(u32, 3), @truncate(value));
                self.spu.write((offset & ~@as(u32, 3)) + 2, @truncate(value >> 16));
            } else {
                self.spu.write(offset, @truncate(value));
            }
            return;
        }

        if (paddr == Addr.i_stat) {
            self.interrupts.writeStat(@as(u32, value));
            return;
        }
        if (paddr == Addr.i_mask) {
            self.interrupts.writeMask(@as(u32, value));
            return;
        }

        if (paddr == Addr.sio1_spoof_first) {
            writeMem(u32, &self.io_ports, paddr - Addr.io_ports_base, @as(u32, value) & 0xFF);
            return;
        }
        if (paddr == Addr.sio1_misc) {
            writeMem(u32, &self.io_ports, paddr - Addr.io_ports_base, 0xC0C00000);
            return;
        }

        // MDEC Registers
        if (paddr == Addr.mdec_data) {
            self.mdec.write(@truncate(value));
            return;
        }
        if (paddr == Addr.mdec_stat) {
            self.mdec.writeControl(@truncate(value));
            return;
        }

        // HARDWARE TIMERS
        if (paddr >= Addr.timer_base and paddr < Addr.timer_end) {
            const timer_idx = (paddr >> 4) & 0x3;
            const offset = paddr & 0xF;
            if (paddr == Addr.timer1_mode) {
                writeMem(u32, &self.io_ports, paddr - Addr.io_ports_base, @as(u32, value));
            }
            if (timer_idx < 3) self.timers[timer_idx].write(offset, @truncate(value));
            return;
        }

        // GPU
        if (paddr == Addr.gpu_data) {
            const p = self.pgxp_pending;
            self.pgxp_pending = Value.none;
            self.wait_cycles += self.gpu.writeGp0(@as(u32, value), p);
            return;
        }
        if (paddr == Addr.gpu_stat) {
            self.gpu.writeGp1(@as(u32, value));
            return;
        }

        // DMA Registers
        if (paddr >= Addr.dma_base and paddr < Addr.dma_end) {
            const reg_addr = paddr & ~@as(u32, 3);
            const offset = reg_addr - Addr.dma_base;
            const old_val = self.dma.read(offset);

            var new_val = old_val;
            if (T == u32) {
                new_val = @as(u32, value);
            } else if (T == u16) {
                const shift = (paddr & 2) * 8;
                const mask = @as(u32, 0xFFFF) << @as(u5, @truncate(shift));
                new_val = (old_val & ~mask) | (@as(u32, value) << @as(u5, @truncate(shift)));
            } else if (T == u8) {
                const shift = (paddr & 3) * 8;
                const mask = @as(u32, 0xFF) << @as(u5, @truncate(shift));
                new_val = (old_val & ~mask) | (@as(u32, value) << @as(u5, @truncate(shift)));
            }

            self.dma.write(self, offset, new_val);
            return;
        }

        switch (paddr) {
            // 2 MB RAM, mirrored 4x across the first 8 MB (PSX-SPX memory map).
            Addr.ram_base...Addr.ram_mirror_last => writeMem(T, &self.ram, paddr & Addr.ram_size_mask, value),
            Addr.scratchpad_base...Addr.scratchpad_last => writeMem(T, &self.scratchpad, paddr & Addr.scratchpad_mask, value),
            Addr.io_ports_base...Addr.io_ports_last => writeMem(T, &self.io_ports, paddr - Addr.io_ports_base, value),
            Addr.exp3_base...Addr.exp3_last => writeMem(T, &self.expansion_3, paddr - Addr.exp3_base, value),
            // BIOS and Expansion regions are read-only ROM, other unmapped writes are dropped silently
            else => {},
        }
    }

    inline fn readMem(comptime T: type, memory: []const u8, offset: u32) T {
        const size = @sizeOf(T);
        // Automatically calculate the alignment mask based on the type (u32 -> ~3, u16 -> ~1, u8 -> ~0)
        const aligned_offset = offset & ~@as(u32, size - 1);

        if (size == 1) return memory[aligned_offset];
        return std.mem.readInt(T, memory[aligned_offset..][0..size], .little);
    }

    inline fn writeMem(comptime T: type, memory: []u8, offset: u32, value: T) void {
        const size = @sizeOf(T);
        const aligned_offset = offset & ~@as(u32, size - 1);

        if (size == 1) {
            memory[aligned_offset] = value;
        } else {
            std.mem.writeInt(T, memory[aligned_offset..][0..size], value, .little);
        }
    }

    fn readExpansion3(self: *const Self, comptime T: type, offset: u32) u32 {
        const aligned_offset = offset & ~@as(u32, 3);
        const value = std.mem.readInt(u32, self.expansion_3[aligned_offset..][0..4], .little);

        return switch (T) {
            u32 => value | 0xFF000000,
            u16 => switch (self.expansion_3_last_write_width) {
                1 => 0xFF78,
                2 => 0x7F78,
                else => value & 0xFFFF,
            },
            u8 => value & 0xFF,
            else => @compileError("unsupported EXP3 read width"),
        };
    }

    fn writeExpansion3(self: *Self, comptime T: type, offset: u32, value: u32) void {
        const aligned_offset = offset & ~@as(u32, 3);

        const stored = switch (T) {
            u32 => ((value >> 16) & 0xFF) << 16 | ((value >> 24) & 0xFF) << 8 | ((value >> 16) & 0xFF),
            u16, u8 => ((value & 0xFF) << 16) | (value & 0xFFFF),
            else => @compileError("unsupported EXP3 write width"),
        };

        std.mem.writeInt(u32, self.expansion_3[aligned_offset..][0..4], stored, .little);
        self.expansion_3_last_write_width = @sizeOf(T);
    }
};
