const std = @import("std");
const CdRom = @import("cdrom.zig").CdRom;
const Dma = @import("dma.zig").Dma;
const Gpu = @import("gpu/gpu.zig").Gpu;
const Sio = @import("sio.zig").Sio;
const Timer = @import("timer.zig").Timer;

const KB = 1 << 10;
const MB = 1 << 20;

pub const Bus = struct {
    const Self = @This();

    // 00000000h - 2048K Main RAM (first 64K reserved for BIOS)
    ram: [2 * MB]u8,
    // 1F000000h - 8192K Expansion Region 1 (ROM/RAM)
    expansion_1: [8 * MB]u8,
    // 1F800000h - 1K Scratchpad (D-Cache used as Fast RAM)
    scratchpad: [1 * KB]u8,
    // 1F801000h - 4K I/O Ports
    io_ports: [4 * KB]u8,
    // 1F802000h - 8K Expansion Region 2 (I/O Ports)
    expansion_2: [8 * KB]u8,
    // 1FA00000h - 2048K Expansion Region 3 (SRAM BIOS region for DTL cards)
    expansion_3: [2 * MB]u8,
    // 1FC00000h - 512K BIOS ROM (Kernel)
    bios: [512 * KB]u8,
    // FFFE0000h - 0.5K Internal CPU control registers (Cache Control)
    cache_control: [512]u8,

    wait_cycles: u32 = 0,

    sys_clock: u64 = 0,
    i_stat: u32 = 0, // Interrupt status register (I_STAT)
    i_mask: u32 = 0, // Interrupt mask register (I_MASK)
    timers: [3]Timer = [_]Timer{.{}} ** 3,
    cdrom: CdRom = CdRom.init(),
    dma: Dma = Dma.init(),
    gpu: Gpu = Gpu.init(),
    sio: Sio = Sio.init(),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const bus = try allocator.create(Self);
        @memset(std.mem.asBytes(bus), 0);
        bus.timers = [_]Timer{.{}} ** 3;
        bus.cdrom = CdRom.init();
        bus.dma = Dma.init();
        bus.gpu = Gpu.init();
        bus.sio = Sio.init();
        return bus;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn read32(self: *Self, virtual_address: u32) u32 {
        self.addWaitCycles(u32, virtual_address);
        return self.read(u32, virtual_address);
    }

    pub fn fetchInstruction(self: *Self, virtual_address: u32) u32 {
        // Only Uncached memory (KSEG1: 0xA0000000 - 0xBFFFFFFF) adds wait cycles for fetches.
        // Cached regions (KUSEG, KSEG0) simulate a 100% I-Cache hit rate (0 wait cycles).
        if (virtual_address >= 0xA0000000 and virtual_address <= 0xBFFFFFFF) {
            self.addWaitCycles(u32, virtual_address);
        }
        return self.read(u32, virtual_address);
    }

    pub fn read16(self: *Self, virtual_address: u32) u16 {
        self.addWaitCycles(u16, virtual_address);
        return self.read(u16, virtual_address);
    }
    pub fn read8(self: *Self, virtual_address: u32) u8 {
        self.addWaitCycles(u8, virtual_address);
        return self.read(u8, virtual_address);
    }

    pub fn write32(self: *Self, virtual_address: u32, value: u32) void {
        self.addWaitCycles(u32, virtual_address);
        self.write(u32, virtual_address, value);
    }
    pub fn write16(self: *Self, virtual_address: u32, value: u16) void {
        self.addWaitCycles(u16, virtual_address);
        self.write(u16, virtual_address, value);
    }
    pub fn write8(self: *Self, virtual_address: u32, value: u8) void {
        self.addWaitCycles(u8, virtual_address);
        self.write(u8, virtual_address, value);
    }

    // Helper method to simulate PS1 memory wait states
    inline fn addWaitCycles(self: *Self, comptime T: type, virtual_address: u32) void {
        const paddr = virtual_address & 0x1FFFFFFF;
        const size = @sizeOf(T);
        self.wait_cycles += switch (paddr) {
            0x00000000...0x001FFFFF => 4, // RAM is fast (~5 cycles total)
            0x1FC00000...0x1FC7FFFF => 6 * size, // BIOS is on an 8-bit bus
            0x1F800000...0x1F8003FF => 0, // Scratchpad has 0 wait states
            0x1F000000...0x1F7FFFFF => 6 * size, // EXP1
            0x1F802000...0x1F803FFF => 13 * size, // EXP2
            0x1FA00000...0x1FBFFFFF => 3 * size, // EXP3
            else => 2, // Hardware IO Ports
        };
    }

    fn read(self: *Self, comptime T: type, virtual_address: u32) T {
        const paddr = virtual_address & 0x1FFFFFFF; // Mask to physical

        // CD-ROM Controller
        if (paddr >= 0x1F801800 and paddr <= 0x1F801803) {
            return @as(T, @truncate(self.cdrom.read(paddr - 0x1F801800)));
        }

        // GPU
        if (paddr == 0x1F801810) return @as(T, @truncate(self.gpu.readData()));
        if (paddr == 0x1F801814) return @as(T, @truncate(self.gpu.readStatus()));

        // SIO Registers
        if (paddr >= 0x1F801040 and paddr <= 0x1F80104F) {
            return @as(T, @truncate(self.sio.read(paddr - 0x1F801040)));
        }

        // HARDWARE TIMERS
        if (paddr >= 0x1F801100 and paddr < 0x1F801130) {
            const timer_idx = (paddr >> 4) & 0x3;
            const offset = paddr & 0xF;
            if (timer_idx < 3) return @truncate(self.timers[timer_idx].read(offset));
            return 0;
        }

        // DMA Registers
        if (paddr >= 0x1F801080 and paddr <= 0x1F8010F4) {
            return @as(T, @truncate(self.dma.read(paddr - 0x1F801080)));
        }

        if (paddr == 0x1F801070) return @as(T, @truncate(self.i_stat));
        if (paddr == 0x1F801074) return @as(T, @truncate(self.i_mask));

        return switch (paddr) {
            0x00000000...0x001FFFFF => readMem(T, &self.ram, paddr & 0x1FFFFF),
            0x1F800000...0x1F8003FF => readMem(T, &self.scratchpad, paddr & 0x3FF),
            0x1F801000...0x1F801FFF => readMem(T, &self.io_ports, paddr - 0x1F801000),
            0x1F802000...0x1F803FFF => readMem(T, &self.expansion_2, paddr - 0x1F802000),
            0x1FC00000...0x1FC7FFFF => readMem(T, &self.bios, paddr - 0x1FC00000),
            else => 0,
        };
    }

    fn write(self: *Self, comptime T: type, virtual_address: u32, value: T) void {
        const paddr = virtual_address & 0x1FFFFFFF;

        // CD-ROM Controller
        if (paddr >= 0x1F801800 and paddr <= 0x1F801803) {
            self.cdrom.write(paddr - 0x1F801800, @as(u8, @truncate(value)));
            return;
        }

        if (paddr >= 0x1F801040 and paddr <= 0x1F80104F) {
            if (self.sio.write(paddr - 0x1F801040, @as(u32, value))) {
                self.i_stat |= (1 << 7); // IRQ7 is SIO
            }
            return;
        }

        if (paddr == 0x1F801070) {
            // Writing 0 to a bit acknowledges/clears that interrupt bit
            self.i_stat &= @as(u32, value);
            return;
        }
        if (paddr == 0x1F801074) {
            self.i_mask = @as(u32, value);
            return;
        }

        // HARDWARE TIMERS
        if (paddr >= 0x1F801100 and paddr < 0x1F801130) {
            const timer_idx = (paddr >> 4) & 0x3;
            const offset = paddr & 0xF;
            if (timer_idx < 3) self.timers[timer_idx].write(offset, @truncate(value));
            return;
        }

        // GPU
        if (paddr == 0x1F801810) {
            self.gpu.writeGp0(@as(u32, value));
            return;
        }
        if (paddr == 0x1F801814) {
            self.gpu.writeGp1(@as(u32, value));
            return;
        }

        // DMA Registers
        if (paddr >= 0x1F801080 and paddr <= 0x1F8010F4) {
            self.dma.write(self, paddr - 0x1F801080, @as(u32, value));
            return;
        }

        switch (paddr) {
            0x00000000...0x001FFFFF => writeMem(T, &self.ram, paddr & 0x1FFFFF, value),
            0x1F800000...0x1F8003FF => writeMem(T, &self.scratchpad, paddr & 0x3FF, value),
            0x1F801000...0x1F801FFF => writeMem(T, &self.io_ports, paddr - 0x1F801000, value),
            0x1F802000...0x1F803FFF => writeMem(T, &self.expansion_2, paddr - 0x1F802000, value),
            // BIOS is read-only ROM, other unmapped writes are dropped silently
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
};
