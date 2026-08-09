const Spu = @import("spu.zig").Spu;

/// Advances the noise LFSR by one sample tick. Extracted out of
/// `generateSample`.
pub fn step(self: *Spu) void {
    const noise_step = @as(i32, (self.spu_cnt >> 8) & 3) + 4; // 4..7
    const noise_shift = @as(u4, @truncate((self.spu_cnt >> 10) & 15));

    self.noise.timer -= noise_step;
    if (self.noise.timer <= 0) {
        self.noise.timer += (@as(i32, 0x20000) >> noise_shift);

        const lfsr = self.noise.lfsr;
        const parity = ((lfsr >> 15) & 1) ^ ((lfsr >> 12) & 1) ^ ((lfsr >> 11) & 1) ^ ((lfsr >> 10) & 1) ^ 1;
        self.noise.lfsr = (lfsr << 1) | parity;
        self.noise.level = @as(i16, @bitCast(@as(u16, @truncate(self.noise.lfsr))));
    }
}
