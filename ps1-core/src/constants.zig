//! Hardware facts shared by more than one module. A constant that only one
//! file uses belongs in a private `const` block at the top of that file.

/// VRAM is 1024x512 16-bit pixels (ABGR1555).
pub const vram_width = 1024;
pub const vram_height = 512;

/// Every sector on disc is 2352 bytes on the wire, whatever the mode.
pub const sector_bytes = 2352;

/// MSF 00:02:00 == LBA 0. `MSF.toLba` subtracts this; `fromLba` re-adds it.
pub const lead_in_frames = 150;

/// R3000A clock. The GPU's video clock is 11/7 of this (53.2224 MHz).
pub const cpu_clock_hz = 33_868_800;
