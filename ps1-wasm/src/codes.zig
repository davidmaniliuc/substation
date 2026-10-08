//! The negative codes every fallible export returns. The values are
//! `ps1.h`'s `PS1_ERR_*`, so one table describes both frontends;
//! `ps1-web/src/errors.ts` mirrors this file value for value.

const ps1 = @import("ps1_core");

pub const ok: i32 = 0;
pub const bad_bios_size: i32 = -1;
pub const bad_cue: i32 = -2;
pub const multi_file_cue: i32 = -3;
pub const oom: i32 = -4;
pub const bad_sbi: i32 = -5;
pub const bad_memcard_size: i32 = -6;
pub const bad_slot: i32 = -7;
pub const state_bad_magic: i32 = -8;
pub const state_version: i32 = -9;
pub const state_bios: i32 = -10;
pub const state_disc: i32 = -11;
pub const state_corrupt: i32 = -12;
pub const state_no_space: i32 = -13;
pub const engine_unavailable: i32 = -14;
pub const bad_chd: i32 = -15;

pub fn ofState(err: (error{OutOfMemory} || ps1.savestate.Error)) i32 {
    return switch (err) {
        error.OutOfMemory => oom,
        error.StateBadMagic => state_bad_magic,
        error.StateVersion => state_version,
        error.StateBios => state_bios,
        error.StateDisc => state_disc,
        error.StateCorrupt => state_corrupt,
        error.NoSpace => state_no_space,
    };
}
