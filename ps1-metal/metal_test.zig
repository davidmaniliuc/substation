//! Root of the `test-metal` binary: every test that needs a Metal device.
//! At the package root because a test file under tests/ could not reach
//! src/ otherwise; the per-area tests live under tests/.

test {
    _ = @import("tests/smoke_test.zig");
    _ = @import("tests/vram_test.zig");
}
