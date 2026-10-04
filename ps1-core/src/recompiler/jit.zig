//! The arm64 JIT (`.jit`): a block emitted as host code; it computes
//! exactly what `.cached` computes and shares its goldens (`trace-block/`).
//! See docs/superpowers/specs/2026-10-03-cpu-recompiler-design.md.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const block = @import("block.zig");
const cached = @import("cached.zig");

pub const emit = @import("arm64/emit.zig");
pub const emitter = @import("arm64/emitter.zig");
const code_buffer = @import("arm64/code_buffer.zig");
pub const CodeBuffer = code_buffer.CodeBuffer;
pub const available = code_buffer.available;
pub const translate = @import("arm64/translate.zig");

/// Which op families the JIT emits inline; every other op is a call to its
/// `exec.zig` handler. All on is the shipped engine. Turning one off
/// bisects a JIT bug to that family (`ps1-golden --jit-lower=`).
pub const Lowering = struct {
    alu: bool = true,
    branch: bool = true,
    load: bool = true,
    store: bool = true,
    /// Exits through direct branches jump straight to the next block.
    link: bool = true,

    pub const none: Lowering = .{ .alu = false, .branch = false, .load = false, .store = false, .link = false };
    /// The names `parse` takes, one per field.
    const families = .{ "alu", "branch", "load", "store", "link" };

    /// "all", "none", or a comma-separated list of the families to lower.
    pub fn parse(text: []const u8) error{UnknownFamily}!Lowering {
        if (std.mem.eql(u8, text, "all")) return .{};
        var l: Lowering = none;
        if (std.mem.eql(u8, text, "none")) return l;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |name| l = try with(l, name);
        return l;
    }

    fn with(l: Lowering, name: []const u8) error{UnknownFamily}!Lowering {
        var out = l;
        inline for (families) |f| {
            if (std.mem.eql(u8, name, f)) {
                @field(out, f) = true;
                return out;
            }
        }
        return error.UnknownFamily;
    }

    /// What may be inline under PGXP tier `tier`. A family joins here once
    /// its inline code leaves every shadow its handler would.
    pub fn under(l: Lowering, tier: Pgxp) Lowering {
        if (tier == .off) return l;
        var out: Lowering = .none;
        out.branch = l.branch;
        out.link = l.link;
        return out;
    }
};

/// What a block bakes in of PGXP's two switches (`run.pgxpTier`). `base`
/// is the master switch alone: loads, stores and the register-move idiom
/// propagate shadows and every other write clears one. `cpu` adds CPU
/// mode's hooks at every ALU, shift, mult/div and move.
pub const Pgxp = enum { off, base, cpu };

/// Called with each block's code once it is installed: `ps1-golden
/// --jit-dump` writes it out for `objdump`.
pub const Hook = struct {
    context: *anyopaque,
    f: *const fn (context: *anyopaque, b: *const block.Block, code: []const u32) void,
};

/// One MAP_JIT region (spec: Machinery). It is flushed whole when full.
pub const buffer_bytes: usize = 32 << 20;

/// What the JIT keeps beside the block cache: its code memory, the emitter a
/// compile builds in, and the stub every block returns through. Heap-only:
/// the emitter alone is about 100 KB.
pub const Jit = struct {
    buf: CodeBuffer,
    em: emitter.Emitter = .{},
    lower: Lowering = .{},
    dump: ?Hook = null,
    return_stub: usize = 0,
    /// Where an unlinked exit goes: records itself for `run.relink`, then
    /// falls into `return_stub`.
    relink_stub: usize = 0,
    /// Exits rewritten to jump straight to a block. For tests and the bench.
    links: u32 = 0,

    /// Fails with `EngineUnavailable` when MAP_JIT is refused.
    pub fn create(allocator: std.mem.Allocator, bytes: usize) error{ OutOfMemory, EngineUnavailable }!*Jit {
        const j = try allocator.create(Jit);
        errdefer allocator.destroy(j);
        j.* = .{ .buf = CodeBuffer.init(bytes) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.EngineUnavailable,
        } };
        // A fresh buffer has room for the stubs. The relink stub falls
        // through into the return stub, so they go in together.
        const stubs = translate.link.relink_stub ++ translate.return_stub;
        j.relink_stub = @intFromPtr(j.buf.install(&stubs) catch unreachable);
        j.return_stub = j.relink_stub + translate.link.relink_stub.len * 4;
        j.buf.pin();
        return j;
    }

    /// Rewrites the exit at `site` to jump straight to `entry`.
    pub fn link(j: *Jit, site: [*]u32, entry: [*]u32) void {
        j.buf.patch(site, emit.bl(@intCast(@as(i64, @intCast(@intFromPtr(entry))) - @as(i64, @intCast(@intFromPtr(site))))));
        j.links +%= 1;
    }

    /// Sends every jump into a dropped block's linked entry to the relink
    /// stub: the exit that made it records itself, and the dispatcher links
    /// it to whatever block is compiled there next.
    pub fn unlink(j: *Jit, b: *const block.Block) void {
        const entry = b.link_entry orelse return;
        j.buf.patch(entry, emit.b(@intCast(@as(i64, @intCast(j.relink_stub)) - @as(i64, @intCast(@intFromPtr(entry))))));
    }

    pub fn destroy(j: *Jit, allocator: std.mem.Allocator) void {
        j.buf.deinit();
        allocator.destroy(j);
    }
};

/// Runs `b`'s host code from `cpu.pipeline.pc`, its start. Same contract
/// as `cached.execute`.
pub fn execute(cpu: *Cpu, b: *const block.Block, fetch_cost: u32) u32 {
    // Inline code resolves the load delay at compile time, and cannot know
    // which register a load issued before the block targets.
    if (cpu.load_delay.load_r != 0) return cached.execute(cpu, b, fetch_cost);
    cached.begin(cpu);
    return b.code.?(cpu, fetch_cost);
}
