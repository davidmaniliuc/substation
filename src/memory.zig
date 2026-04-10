const std = @import("std");
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

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const bus = try allocator.create(Self);
        @memset(std.mem.asBytes(bus), 0);
        return bus;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn read32(self: *const Self, virtual_address: u32) u32 {
        // Mask the MIPS address to get the physical hardware location
        const physical_address = virtual_address & 0x1FFFFFFF;

        return switch (physical_address) {
            0x00000000...0x001FFFFF => self.readRam32(physical_address),
            0x1FC00000...0x1FC7FFFF => self.readBios32(physical_address),
            0x1F801000...0x1F802FFF => self.readIoRegister(physical_address),
            else => 0xFFFFFFFF,
        };
    }

    pub fn read16(self: *const Self, virtual_address: u32) u16 {
        const physical_address = virtual_address & 0x1FFFFFFF;
        return switch (physical_address) {
            0x00000000...0x001FFFFF => self.readRam16(physical_address),
            0x1F800000...0x1F8003FF => self.readScratchpad16(physical_address),
            0x1FC00000...0x1FC7FFFF => self.readBios16(physical_address),
            // I/O ports often use 16-bit reads for things like Joypads or Timers
            0x1F801000...0x1F802FFF => self.readIoRegister16(physical_address),
            else => 0xFFFF,
        };
    }

    pub fn read8(self: *const Self, virtual_address: u32) u8 {
        const physical_address = virtual_address & 0x1FFFFFFF;
        return switch (physical_address) {
            0x00000000...0x001FFFFF => self.readRam8(physical_address),
            0x1F800000...0x1F8003FF => self.readScratchpad8(physical_address),
            0x1FC00000...0x1FC7FFFF => self.readBios8(physical_address),
            0x1F801000...0x1F802FFF => self.readIoRegister8(physical_address),
            else => 0xFF,
        };
    }

    inline fn readRam32(self: *const Self, addr: u32) u32 {
        // & 0x1FFFFF wraps it to 2MB.
        // & ~@as(u32, 3) clears the bottom 2 bits to force 32-bit alignment.
        const safe_addr = (addr & 0x1FFFFF) & ~@as(u32, 3);
        return std.mem.readInt(u32, self.ram[safe_addr..][0..4], .little);
    }

    inline fn readRam16(self: *const Self, addr: u32) u16 {
        const safe_addr = (addr & 0x1FFFFF) & ~@as(u32, 1);
        return std.mem.readInt(u16, self.ram[safe_addr..][0..2], .little);
    }

    inline fn readRam8(self: *const Self, addr: u32) u8 {
        const safe_addr = addr & 0x1FFFFF;
        return self.ram[safe_addr];
    }

    inline fn readBios32(self: *const Self, addr: u32) u32 {
        const offset = addr - 0x1FC00000;
        return std.mem.readInt(u32, self.bios[offset..][0..4], .little);
    }

    inline fn readIoRegister(self: *const Self, addr: u32) u32 {
        const offset = addr - 0x1F801000;
        return std.mem.readInt(u32, self.io_ports[offset..][0..4], .little);
    }

    inline fn readScratchpad32(self: *const Self, addr: u32) u32 {
        const offset = addr & 0x3FF; // Mask to 1KB (1024 bytes)
        return std.mem.readInt(u32, self.scratchpad[offset..][0..4], .little);
    }

    inline fn writeScratchpad32(self: *Self, addr: u32, value: u32) void {
        const offset = addr & 0x3FF;
        std.mem.writeInt(u32, self.scratchpad[offset..][0..4], value, .little);
    }

    pub fn write32(self: *Self, virtual_address: u32, value: u32) void {
        const physical_address = virtual_address & 0x1FFFFFFF;
        switch (physical_address) {
            0x00000000...0x001FFFFF => self.writeRam32(value, physical_address),
            0x1F801000...0x1F802FFF => self.writeIoRegister(value, physical_address),
            0x1FC00000...0x1FC7FFFF => {},
            else => {},
        }
    }

    inline fn writeRam32(self: *Self, value: u32, addr: u32) void {
        const safe_addr = (addr & 0x1FFFFF) & ~@as(u32, 3);
        std.mem.writeInt(u32, self.ram[safe_addr..][0..4], value, .little);
    }

    inline fn writeRam16(self: *Self, value: u16, addr: u32) void {
        const safe_addr = (addr & 0x1FFFFF) & ~@as(u32, 1);
        std.mem.writeInt(u16, self.ram[safe_addr..][0..2], value, .little);
    }

    inline fn writeRam8(self: *Self, value: u8, addr: u32) void {
        const safe_addr = addr & 0x1FFFFF;
        self.ram[safe_addr] = value;
    }

    inline fn writeIoRegister(self: *Self, value: u32, addr: u32) void {
        const offset = addr - 0x1F801000;
        std.mem.writeInt(u32, self.io_ports[offset..][0..4], value, .little);
    }
};
