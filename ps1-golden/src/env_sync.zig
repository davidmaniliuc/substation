//! Extracted from `main.zig` so a test binary can reach it directly — see
//! `fixture_test.zig`'s "fixture: envSyncRecords ..." tests. Deliberately
//! kept to just this one function; nothing else belongs here.

const ps1 = @import("ps1_core");

/// Seven records that drive a default-constructed `DrawingEnv` to exactly
/// `env`'s state: `set_texture_disable_allowed` first (E1's own record below
/// re-applies `maskTextureDisable` against whatever `texture_disable_allowed`
/// is live at replay time, so it must already be correct before E1 replays),
/// then one `set_draw_env` per E1-E6 register. Every one of these is an
/// absolute-value set — `DrawingEnv.update` assigns, it never accumulates —
/// so replaying all seven against a fresh `DrawingEnv{}` reproduces `env`
/// exactly regardless of how `env` itself was built up over however many
/// discarded frames preceded it.
pub fn envSyncRecords(env: ps1.gpu.Regs.DrawingEnv) [7]ps1.gpu.command.Command {
    return .{
        .{ .kind = .set_texture_disable_allowed, .value = @intFromBool(env.texture_disable_allowed) },
        .{ .kind = .set_draw_env, .opcode = 0xE1, .value = env.draw_mode },
        .{ .kind = .set_draw_env, .opcode = 0xE2, .value = env.tex_window },
        .{ .kind = .set_draw_env, .opcode = 0xE3, .value = env.area_top_left },
        .{ .kind = .set_draw_env, .opcode = 0xE4, .value = env.area_bot_right },
        .{ .kind = .set_draw_env, .opcode = 0xE5, .value = env.offset },
        .{ .kind = .set_draw_env, .opcode = 0xE6, .value = env.mask_bit },
    };
}
