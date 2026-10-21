//! Root of the ps1-session tests that need no device: no Metal, no audio
//! output, no window. They run under `zig build test` on macOS hosts (the
//! module is macOS-only).

test {
    _ = @import("tests/audio_test.zig");
}
