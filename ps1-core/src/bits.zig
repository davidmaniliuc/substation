//! Bit and cast idioms that clear the extraction bar: 3+ operations AND 4+
//! call sites. Anything below that bar stays written out at its call site —
//! forty tiny wrappers nobody can remember is worse than the casts were.

/// Sign-extend a 16-bit value into a 32-bit register word.
pub fn sext16(v: u16) u32 {
    const signed: i16 = @bitCast(v);
    return @bitCast(@as(i32, signed));
}

/// Sign-extend an 8-bit value into a 32-bit register word.
pub fn sext8(v: u8) u32 {
    const signed: i8 = @bitCast(v);
    return @bitCast(@as(i32, signed));
}
