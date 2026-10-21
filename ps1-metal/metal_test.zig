//! Root of the `test-metal` binary: every test that needs a Metal device.
//! At the package root because a test file under tests/ could not reach
//! src/ otherwise; the per-area tests live under tests/.

test {
    _ = @import("tests/smoke_test.zig");
    _ = @import("tests/vram_test.zig");
    _ = @import("tests/sidecar_test.zig");
    _ = @import("tests/mover_test.zig");
    _ = @import("tests/rasterizer_test.zig");
    _ = @import("tests/harness_test.zig");
    _ = @import("tests/scale_test.zig");
    _ = @import("tests/scale_sampling_test.zig");
    _ = @import("tests/scale_geometry_test.zig");
    _ = @import("tests/scale_gate_test.zig");
    _ = @import("tests/filter_test.zig");
    _ = @import("tests/true_colour_test.zig");
    _ = @import("tests/pgxp_parity_test.zig");
    _ = @import("tests/interp_fuzz_test.zig");
    _ = @import("tests/live_renderer_test.zig");
    _ = @import("tests/live_renderer_scale_test.zig");
    _ = @import("tests/speculation_test.zig");
    _ = @import("tests/display_test.zig");
    _ = @import("tests/display_scale_test.zig");
    _ = @import("tests/screenshot_test.zig");
    _ = @import("tests/layer_test.zig");
}
