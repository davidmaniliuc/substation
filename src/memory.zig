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
        return self.read(u32, virtual_address);
    }
    pub fn read16(self: *const Self, virtual_address: u32) u16 {
        return self.read(u16, virtual_address);
    }
    pub fn read8(self: *const Self, virtual_address: u32) u8 {
        return self.read(u8, virtual_address);
    }

    pub fn write32(self: *Self, virtual_address: u32, value: u32) void {
        self.write(u32, virtual_address, value);
    }
    pub fn write16(self: *Self, virtual_address: u32, value: u16) void {
        self.write(u16, virtual_address, value);
    }
    pub fn write8(self: *Self, virtual_address: u32, value: u8) void {
        self.write(u8, virtual_address, value);
    }

    fn read(self: *const Self, comptime T: type, virtual_address: u32) T {
        const paddr = virtual_address & 0x1FFFFFFF; // Mask to physical

        return switch (paddr) {
            0x00000000...0x001FFFFF => readMem(T, &self.ram, paddr & 0x1FFFFF),
            0x1F800000...0x1F8003FF => readMem(T, &self.scratchpad, paddr & 0x3FF),
            0x1F801000...0x1F801FFF => readMem(T, &self.io_ports, paddr - 0x1F801000),
            0x1F802000...0x1F803FFF => readMem(T, &self.expansion_2, paddr - 0x1F802000),
            0x1FC00000...0x1FC7FFFF => readMem(T, &self.bios, paddr - 0x1FC00000),
            // Unmapped memory typically floats high (returns 0xFFFFFFFF, 0xFFFF, or 0xFF)
            else => std.math.maxInt(T),
        };
    }

    fn write(self: *Self, comptime T: type, virtual_address: u32, value: T) void {
        const paddr = virtual_address & 0x1FFFFFFF;

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
