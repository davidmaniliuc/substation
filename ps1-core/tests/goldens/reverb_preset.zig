//! Shared fixture for the SPU reverb golden tests.
//!
//! These exact values are duplicated by hand in
//! `avocado_ref/src/platform/headless/reverb_golden.cpp` (gitignored). Change
//! anything here and you must change it there and regenerate the .bin goldens
//! — see docs/superpowers/plans/2026-08-08-spu-reverb.md, Task 1.
//!
//! The preset is synthetic, not one of the PSX-SPX hardware presets: it is
//! chosen for coverage, not for sound. Mixed-sign coefficients close to unity
//! reach the saturation paths, left and right differ in every field so a
//! swapped channel fails the test, and the work area is small enough that 512
//! invocations wrap the ring buffer exactly twice.
//!
//! Known divergence from Avocado, not exercised here: none of `regs`/vol_l/
//! vol_r below is 0x8000. Avocado's Sample::operator* narrows (a*b)>>15 back
//! to int16_t before the next +/-, so (-32768)*(-32768)>>15 wraps to -32768;
//! we keep the product in i32 and let the surrounding sat() clamp it to
//! +32767. Deliberate — see docs/superpowers/plans/2026-08-08-spu-reverb.md —
//! but it means a future preset that does hit 0x8000 will mismatch the
//! goldens for this reason, not because of a port bug.

/// Reverb work-area base, in 8-byte units. base * 8 = 0x7FC00, leaving 0x400
/// bytes (512 samples) of work area at the top of the 512 KB SPU RAM.
pub const base: u16 = 0xFF80;

pub const vol_l: i16 = 0x7FFF;
pub const vol_r: i16 = 0x6000;

/// Number of doReverb invocations captured in each golden.
pub const sample_count: usize = 512;

/// Reverb registers 0x00..0x1F, as written to 0x1F801DC0..0x1F801DFE.
pub const regs = [32]i16{
    0x0004, // 0x00 dAPF1
    0x0007, // 0x01 dAPF2
    0x6000, // 0x02 vIIR
    0x5000, // 0x03 vCOMB1
    -0x3000, // 0x04 vCOMB2
    0x2800, // 0x05 vCOMB3
    -0x1800, // 0x06 vCOMB4
    -0x7000, // 0x07 vWALL
    0x6000, // 0x08 vAPF1
    -0x5000, // 0x09 vAPF2
    0x0010, // 0x0A mLSAME
    0x0014, // 0x0B mRSAME
    0x0018, // 0x0C mLCOMB1
    0x001C, // 0x0D mRCOMB1
    0x0020, // 0x0E mLCOMB2
    0x0024, // 0x0F mRCOMB2
    0x0028, // 0x10 dLSAME
    0x002C, // 0x11 dRSAME
    0x0030, // 0x12 mLDIFF
    0x0034, // 0x13 mRDIFF
    0x0038, // 0x14 mLCOMB3
    0x003C, // 0x15 mRCOMB3
    0x0040, // 0x16 mLCOMB4
    0x0044, // 0x17 mRCOMB4
    0x0048, // 0x18 dLDIFF
    0x004C, // 0x19 dRDIFF
    0x0050, // 0x1A mLAPF1
    0x0054, // 0x1B mRAPF1
    0x0058, // 0x1C mLAPF2
    0x005C, // 0x1D mRAPF2
    0x7FFF, // 0x1E vLIN
    0x6000, // 0x1F vRIN
};

/// The pseudo-random input generator behind reverb_noise.bin. Mirrors the
/// lambda in reverb_golden.cpp exactly; both must stay in step.
pub const Lcg = struct {
    state: u32 = 0x13579BDF,

    pub fn next(self: *Lcg) i16 {
        self.state = self.state *% 1103515245 +% 12345;
        return @bitCast(@as(u16, @truncate(self.state >> 16)));
    }
};
