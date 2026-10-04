//! The JIT's code memory: one MAP_JIT mapping, filled from the bottom and
//! never freed piecemeal. When it fills, the block cache flushes every block
//! and it starts again from the bottom (spec: Full flushes).
//!
//! MAP_JIT memory is writable or executable per thread, never both. The
//! write window opens and closes inside `install` around one copy that
//! cannot fail, so no path leaves it open.

const std = @import("std");
const builtin = @import("builtin");

/// MAP_JIT and the per-thread write toggle exist only here. Every other
/// target, wasm included, must never analyse the code below; callers guard
/// with `if (comptime available)`.
pub const available = builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

pub const CodeBuffer = struct {
    words: []u32,
    used: usize = 0,
    /// Words below this survive `reset`: the stubs every block leaves
    /// through.
    base: usize = 0,

    /// Fails when MAP_JIT is refused: a hardened runtime without the
    /// `allow-jit` entitlement (spec: Findings).
    pub fn init(bytes: usize) std.posix.MMapError!CodeBuffer {
        const mem = try std.posix.mmap(
            null,
            bytes,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true },
            -1,
            0,
        );
        return .{ .words = @as([*]u32, @ptrCast(mem.ptr))[0 .. mem.len / 4] };
    }

    pub fn deinit(self: *CodeBuffer) void {
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(self.words.ptr));
        std.posix.munmap(bytes[0 .. self.words.len * 4]);
        self.* = undefined;
    }

    /// Copies `code` in and returns its first word, ready to call.
    pub fn install(self: *CodeBuffer, code: []const u32) error{CodeBufferFull}![*]const u32 {
        if (code.len > self.words.len - self.used) return error.CodeBufferFull;
        const dest = self.words[self.used..][0..code.len];
        pthread_jit_write_protect_np(0);
        @memcpy(dest, code);
        pthread_jit_write_protect_np(1);
        sys_icache_invalidate(dest.ptr, code.len * 4);
        self.used += code.len;
        return dest.ptr;
    }

    /// Rewrites one installed word: a link, or an unlink. It can run while
    /// emitted code is on the stack (a store's slow path drops a block): the
    /// write window is per thread and this thread is in Zig at that moment.
    pub fn patch(self: *CodeBuffer, at: [*]u32, word: u32) void {
        _ = self;
        pthread_jit_write_protect_np(0);
        at[0] = word;
        pthread_jit_write_protect_np(1);
        sys_icache_invalidate(at, 4);
    }

    /// The address the next `install` copies to.
    pub fn cursor(self: *const CodeBuffer) usize {
        return @intFromPtr(self.words.ptr + self.used);
    }

    /// Keeps everything installed so far across `reset`.
    pub fn pin(self: *CodeBuffer) void {
        self.base = self.used;
    }

    /// Forgets every function installed since `pin`. Only once nothing can
    /// call one.
    pub fn reset(self: *CodeBuffer) void {
        self.used = self.base;
    }
};
