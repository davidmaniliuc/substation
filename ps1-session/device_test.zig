//! Root of the ps1-session tests that need a device: an audio output, a
//! Metal GPU, a screen. They run under `zig build test-metal`, and each one
//! that cannot find its device skips, naming what is missing.

test {
    _ = @import("tests/coreaudio_test.zig");
}
