//! Extracted from `main.zig` so a test binary can reach it directly — see
//! `fixture_test.zig`'s "fixture: vramSeedRecords ..." tests. Deliberately
//! kept to just these two functions; nothing else belongs here.

const ps1 = @import("ps1_core");

const command = ps1.gpu.command;
const pixels = ps1.constants.vram_width * ps1.constants.vram_height;

/// A whole-VRAM upload is this many payload words — one per pixel PAIR.
pub const payload_words: usize = pixels / 2;

/// Packs `vram`'s pixels into `out` low-pixel-first, the order `writeData`
/// unpacks a GP0(A0) data word in. Written by hand rather than by reinterpreting
/// the pixel array: `Vram.data` is `u16`-aligned, so a cast to `[]u32` needs an
/// `@alignCast` that would be a lie on any allocation that honoured the
/// declared alignment, and the byte order would then be the host's rather than
/// the format's.
pub fn writeSeedPayload(vram: *const ps1.gpu.Vram, out: []u32) void {
    for (out[0..payload_words], 0..) |*word, i| {
        word.* = @as(u32, vram.data[2 * i]) | @as(u32, vram.data[2 * i + 1]) << 16;
    }
}

/// The two records that put a whole VRAM back, reading `payload_words` words
/// starting at `payload_off`.
///
/// RULE: these replay BEFORE the env sync records, never after. `vram_write_data`
/// masks through `env.mask_bit`, and a from-blank consumer starts on a default
/// `DrawingEnv` whose `mask_bit` is 0 — so ahead of the sync the upload is
/// admitted unmasked, which is what a seed must be. Behind it, a window whose
/// env had check-mask set would drop every seed pixel landing on a set bit 15,
/// and bit 15 is already carried in the pixel values themselves.
pub fn seedRecords(payload_off: u32) [2]command.Command {
    return .{
        .{
            .kind = .vram_write_setup,
            .x = 0,
            .y = 0,
            .w = ps1.constants.vram_width,
            .h = ps1.constants.vram_height,
        },
        .{ .kind = .vram_write_data, .x = @intCast(payload_off), .y = payload_words },
    };
}
