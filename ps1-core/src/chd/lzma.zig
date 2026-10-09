//! Raw LZMA, as chdman's `cdlz` stores a hunk's sector data: no header, the
//! properties fixed at lc 3, lp 0, pb 2, and one stream per hunk with the
//! window reset. The window is therefore the output itself, so a match copies
//! within `out` and there is no dictionary to keep, wrap or flush.
const std = @import("std");

pub const Error = error{BadHunk};

const lc = 3;
const pb = 2;
const pos_mask = (1 << pb) - 1;
const states = 12;
/// The first state after which the previous symbol was a match, and a literal
/// is coded against the byte at rep0.
const first_match_state = 7;
const pos_states_max = 16;
const len_to_pos_states = 4;
const end_pos_model_index = 14;
const full_distances = 128;
const align_bits = 4;
const match_len_min = 2;
const top = 1 << 24;
const prob_bits = 11;
const prob_init = 1 << (prob_bits - 1);
const move_bits = 5;

const LenProbs = struct {
    choice: u16 = prob_init,
    choice2: u16 = prob_init,
    low: [pos_states_max][1 << 3]u16 = @splat(@splat(prob_init)),
    mid: [pos_states_max][1 << 3]u16 = @splat(@splat(prob_init)),
    high: [1 << 8]u16 = @splat(prob_init),
};

/// Every adaptive probability. Reset per hunk by constructing a fresh one.
const Probs = struct {
    literal: [0x300 << lc]u16 = @splat(prob_init),
    is_match: [states * pos_states_max]u16 = @splat(prob_init),
    is_rep: [states]u16 = @splat(prob_init),
    is_rep_g0: [states]u16 = @splat(prob_init),
    is_rep_g1: [states]u16 = @splat(prob_init),
    is_rep_g2: [states]u16 = @splat(prob_init),
    is_rep0_long: [states * pos_states_max]u16 = @splat(prob_init),
    pos_slot: [len_to_pos_states][1 << 6]u16 = @splat(@splat(prob_init)),
    /// Index 0 is unused: a reverse bit tree is addressed from 1.
    pos: [1 + full_distances - end_pos_model_index]u16 = @splat(prob_init),
    alignment: [1 << align_bits]u16 = @splat(prob_init),
    len: LenProbs = .{},
    rep_len: LenProbs = .{},
};

/// Reading past the input feeds zeros and sets `overrun`, checked once at the
/// end, so the per-bit path carries no error union.
const RangeDecoder = struct {
    src: []const u8,
    pos: usize,
    range: u32 = 0xFFFF_FFFF,
    code: u32 = 0,
    overrun: bool = false,

    fn init(src: []const u8) Error!RangeDecoder {
        if (src.len < 5 or src[0] != 0) return error.BadHunk;
        const code = std.mem.readInt(u32, src[1..5], .big);
        if (code == 0xFFFF_FFFF) return error.BadHunk;
        return .{ .src = src, .pos = 5, .code = code };
    }

    inline fn normalize(self: *RangeDecoder) void {
        if (self.range < top) {
            self.range <<= 8;
            var byte: u8 = 0;
            if (self.pos < self.src.len) byte = self.src[self.pos] else self.overrun = true;
            self.pos += 1;
            self.code = (self.code << 8) | byte;
        }
    }

    inline fn bit(self: *RangeDecoder, prob: *u16) u1 {
        const bound = (self.range >> prob_bits) * prob.*;
        var b: u1 = undefined;
        if (self.code < bound) {
            prob.* += ((1 << prob_bits) - prob.*) >> move_bits;
            self.range = bound;
            b = 0;
        } else {
            prob.* -= prob.* >> move_bits;
            self.code -= bound;
            self.range -= bound;
            b = 1;
        }
        self.normalize();
        return b;
    }

    inline fn tree(self: *RangeDecoder, probs: []u16, comptime bits: u5) u32 {
        var m: u32 = 1;
        inline for (0..bits) |_| m = (m << 1) | self.bit(&probs[m]);
        return m - (1 << bits);
    }

    inline fn reverseTree(self: *RangeDecoder, probs: []u16, bits: u32) u32 {
        var m: u32 = 1;
        var symbol: u32 = 0;
        for (0..bits) |i| {
            const b = self.bit(&probs[m]);
            m = (m << 1) | b;
            symbol |= @as(u32, b) << @intCast(i);
        }
        return symbol;
    }

    /// Bits at a fixed probability of one half.
    inline fn direct(self: *RangeDecoder, bits: u32) u32 {
        var result: u32 = 0;
        for (0..bits) |_| {
            self.range >>= 1;
            const b: u32 = @intFromBool(self.code >= self.range);
            self.code -= self.range & (0 -% b);
            self.normalize();
            result = (result << 1) | b;
        }
        return result;
    }

    inline fn length(self: *RangeDecoder, probs: *LenProbs, pos_state: usize) u32 {
        if (self.bit(&probs.choice) == 0) return self.tree(&probs.low[pos_state], 3);
        if (self.bit(&probs.choice2) == 0) return 8 + self.tree(&probs.mid[pos_state], 3);
        return 16 + self.tree(&probs.high, 8);
    }
};

/// Decodes exactly `out.len` bytes from `src`.
pub fn decode(src: []const u8, out: []u8) Error!void {
    var rc = try RangeDecoder.init(src);
    var p: Probs = .{};
    var state: usize = 0;
    var rep: [4]u32 = @splat(0);
    var n: usize = 0;

    while (n < out.len) {
        const pos_state = n & pos_mask;
        if (rc.bit(&p.is_match[state * pos_states_max + pos_state]) == 0) {
            const prev: u32 = if (n == 0) 0 else out[n - 1];
            const probs = p.literal[0x300 * (prev >> (8 - lc)) ..][0..0x300];
            var symbol: u32 = 1;
            if (state >= first_match_state) {
                if (rep[0] >= n) return error.BadHunk;
                var match_byte: u32 = out[n - rep[0] - 1];
                while (symbol < 0x100) {
                    const match_bit = (match_byte >> 7) & 1;
                    match_byte <<= 1;
                    const b = rc.bit(&probs[((1 + match_bit) << 8) + symbol]);
                    symbol = (symbol << 1) | b;
                    if (match_bit != b) break;
                }
            }
            while (symbol < 0x100) symbol = (symbol << 1) | rc.bit(&probs[symbol]);
            out[n] = @truncate(symbol);
            n += 1;
            state = if (state < 4) 0 else if (state < 10) state - 3 else state - 6;
            continue;
        }

        var len: u32 = undefined;
        if (rc.bit(&p.is_rep[state]) != 0) {
            if (n == 0) return error.BadHunk;
            if (rc.bit(&p.is_rep_g0[state]) == 0) {
                if (rc.bit(&p.is_rep0_long[state * pos_states_max + pos_state]) == 0) {
                    // Short rep: one byte from rep0.
                    if (rep[0] >= n) return error.BadHunk;
                    out[n] = out[n - rep[0] - 1];
                    n += 1;
                    state = if (state < first_match_state) 9 else 11;
                    continue;
                }
            } else {
                var dist: u32 = undefined;
                if (rc.bit(&p.is_rep_g1[state]) == 0) {
                    dist = rep[1];
                } else {
                    if (rc.bit(&p.is_rep_g2[state]) == 0) {
                        dist = rep[2];
                    } else {
                        dist = rep[3];
                        rep[3] = rep[2];
                    }
                    rep[2] = rep[1];
                }
                rep[1] = rep[0];
                rep[0] = dist;
            }
            len = rc.length(&p.rep_len, pos_state);
            state = if (state < first_match_state) 8 else 11;
        } else {
            rep[3] = rep[2];
            rep[2] = rep[1];
            rep[1] = rep[0];
            len = rc.length(&p.len, pos_state);
            state = if (state < first_match_state) 7 else 10;
            rep[0] = distance(&rc, &p, len);
        }

        // Also refuses the end marker (distance 0xFFFFFFFF): the size is known.
        if (rep[0] >= n) return error.BadHunk;
        const count = len + match_len_min;
        if (count > out.len - n) return error.BadHunk;
        const from = n - rep[0] - 1;
        if (rep[0] + 1 >= count) {
            @memcpy(out[n..][0..count], out[from..][0..count]);
        } else {
            // An overlapping copy repeats the last rep0 + 1 bytes, so it must
            // run forward a byte at a time.
            for (0..count) |i| out[n + i] = out[from + i];
        }
        n += count;
    }
    if (rc.overrun) return error.BadHunk;
}

inline fn distance(rc: *RangeDecoder, p: *Probs, len: u32) u32 {
    const slot = rc.tree(&p.pos_slot[@min(len, len_to_pos_states - 1)], 6);
    if (slot < 4) return slot;
    const direct_bits = (slot >> 1) - 1;
    const base = (2 | (slot & 1)) << @intCast(direct_bits);
    if (slot < end_pos_model_index) return base + rc.reverseTree(p.pos[base - slot ..], direct_bits);
    return base + (rc.direct(direct_bits - align_bits) << align_bits) + rc.reverseTree(&p.alignment, align_bits);
}
