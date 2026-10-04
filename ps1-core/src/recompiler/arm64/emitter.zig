//! A block's code while it is built: a hot section, the straight path
//! through the block, and a cold one (slow paths and the stop tail), laid
//! out hot first so the path that runs is contiguous. A branch names a
//! label or an absolute address; `finish` encodes it once both sections'
//! sizes are known.

const std = @import("std");
const e = @import("emit.zig");

/// Words per section. A block of `block.max_len + 1` ops needs at most
/// about 50 hot and 70 cold words an op, so the worst block's two sections
/// fit together in `hot`, which is where `finish` lays them out.
pub const max_words = 8192;
const max_labels = 1024;
const max_fixups = 1024;

pub const Section = enum(u1) { hot, cold };
pub const Label = u16;
pub const Target = union(enum) { label: Label, address: usize };

/// A branch's form. `finish` encodes it once its offset is known.
pub const Branch = union(enum) {
    b,
    bl,
    cond: e.Cond,
    cbz: struct { e.Width, e.Reg },
    cbnz: struct { e.Width, e.Reg },
    tbnz: struct { e.Reg, u5 },

    fn encode(br: Branch, offset: i64) u32 {
        return switch (br) {
            .b => e.b(@intCast(offset)),
            .bl => e.bl(@intCast(offset)),
            .cond => |c| e.bCond(c, @intCast(offset)),
            .cbz => |r| e.cbz(r[0], r[1], @intCast(offset)),
            .cbnz => |r| e.cbnz(r[0], r[1], @intCast(offset)),
            .tbnz => |t| e.tbnz(t[0], t[1], @intCast(offset)),
        };
    }
};

const Pos = struct { section: Section, at: u32 };
const Fixup = struct { from: Pos, kind: Branch, to: Target };

pub const Emitter = struct {
    hot: [max_words]u32 = undefined,
    cold: [max_words]u32 = undefined,
    lens: [2]u32 = .{ 0, 0 },
    /// Where `put` writes.
    section: Section = .hot,
    labels: [max_labels]?Pos = undefined,
    label_count: u16 = 0,
    fixups: [max_fixups]Fixup = undefined,
    fixup_count: u32 = 0,

    /// Ready for the next block. Leaves the arrays as they are: only the
    /// counts say what is live.
    pub fn reset(em: *Emitter) void {
        em.lens = .{ 0, 0 };
        em.section = .hot;
        em.label_count = 0;
        em.fixup_count = 0;
    }

    pub fn put(em: *Emitter, word: u32) void {
        const s = @backingInt(em.section);
        const words = if (em.section == .hot) &em.hot else &em.cold;
        words[em.lens[s]] = word;
        em.lens[s] += 1;
    }

    fn here(em: *const Emitter) Pos {
        return .{ .section = em.section, .at = em.lens[@backingInt(em.section)] };
    }

    /// A label to bind later. Branches may name it before then.
    pub fn label(em: *Emitter) Label {
        em.labels[em.label_count] = null;
        em.label_count += 1;
        return em.label_count - 1;
    }

    /// Places `l` at the next word `put` writes.
    pub fn bind(em: *Emitter, l: Label) void {
        em.labels[l] = em.here();
    }

    /// A branch to `to`, encoded by `finish`.
    pub fn branch(em: *Emitter, kind: Branch, to: Target) void {
        em.fixups[em.fixup_count] = .{ .from = em.here(), .kind = kind, .to = to };
        em.fixup_count += 1;
        em.put(0);
    }

    /// MOVZ, and MOVK only when the high half is not zero.
    pub fn movImm32(em: *Emitter, rd: e.Reg, value: u32) void {
        em.put(e.movz(.w, rd, @truncate(value), 0));
        if (value >> 16 != 0) em.put(e.movk(.w, rd, @truncate(value >> 16), 1));
    }

    /// Always four words, whatever the value.
    pub fn movImm64(em: *Emitter, rd: e.Reg, value: u64) void {
        em.put(e.movz(.x, rd, @truncate(value), 0));
        em.put(e.movk(.x, rd, @truncate(value >> 16), 1));
        em.put(e.movk(.x, rd, @truncate(value >> 32), 2));
        em.put(e.movk(.x, rd, @truncate(value >> 48), 3));
    }

    /// A call through IP0, the intra-procedure-call scratch register.
    pub fn call(em: *Emitter, target: usize) void {
        em.movImm64(.x16, target);
        em.put(e.blr(.x16));
    }

    /// Words emitted so far, both sections.
    pub fn len(em: *const Emitter) usize {
        return em.lens[0] + em.lens[1];
    }

    /// Lays the code out for `at`, the address it will be installed at: hot,
    /// then cold. Every branch is encoded here. Valid until `reset`.
    pub fn finish(em: *Emitter, at: usize) []const u32 {
        const hot_len = em.lens[0];
        const total = hot_len + em.lens[1];
        std.debug.assert(total <= max_words);
        @memcpy(em.hot[hot_len..total], em.cold[0..em.lens[1]]);
        for (em.fixups[0..em.fixup_count]) |f| {
            const from = wordOf(f.from, hot_len);
            const to: i64 = switch (f.to) {
                .label => |l| @as(i64, wordOf(em.labels[l].?, hot_len)) * 4,
                .address => |a| @as(i64, @intCast(a)) - @as(i64, @intCast(at)),
            };
            em.hot[from] = f.kind.encode(to - @as(i64, from) * 4);
        }
        return em.hot[0..total];
    }

    /// Where `l` lands once the code is installed at `at`.
    pub fn addressOf(em: *const Emitter, l: Label, at: usize) usize {
        return at + @as(usize, wordOf(em.labels[l].?, em.lens[0])) * 4;
    }
};

fn wordOf(p: Pos, hot_len: u32) u32 {
    return p.at + if (p.section == .cold) hot_len else 0;
}
