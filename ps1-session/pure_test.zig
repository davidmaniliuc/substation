//! Root of the ps1-session tests that need no device: no Metal, no audio
//! output, no window. They run under `zig build test` on macOS hosts (the
//! module is macOS-only).

test {
    _ = @import("tests/audio_test.zig");
    _ = @import("tests/cards_test.zig");
    _ = @import("tests/emulator_thread_test.zig");
    _ = @import("tests/run_loop_frame_test.zig");
    _ = @import("tests/run_loop_requests_test.zig");
    _ = @import("tests/runahead_test.zig");
    _ = @import("tests/thumbnail_test.zig");
}
