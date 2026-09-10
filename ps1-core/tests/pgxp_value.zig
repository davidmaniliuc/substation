//! Staging a `pgxp.Value` by hand, for the unit tests that need a shadow entry
//! the emulator has not produced itself.
//!
//! An entry is judged by the word it was recorded against, so a test cannot
//! name a sub-pixel position without also naming that word — which is what
//! this helper makes cheap to write and hard to get subtly wrong.

const Value = @import("ps1_core").pgxp.Value;

/// An entry recorded against `word`, whose halves are the word's own signed
/// 16-bit integers displaced by the given fractions. Pass a word the wire will
/// never carry to stage a STALE entry.
pub fn subPixel(word: u32, fx: f32, fy: f32) Value {
    return .{
        .x = half(word) + fx,
        .y = half(word >> 16) + fy,
        .word = word,
        .flags = Value.valid_xy,
    };
}

fn half(w: u32) f32 {
    const signed: i16 = @bitCast(@as(u16, @truncate(w)));
    return @floatFromInt(signed);
}
