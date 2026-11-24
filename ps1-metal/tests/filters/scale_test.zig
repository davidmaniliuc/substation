//! Scale2x and Scale3x's tests: draw with `filter_harness.filterGrid` and assert on the
//! sidecar it returns.

const std = @import("std");
const harness = @import("../harness.zig");
const fh = @import("../filter_harness.zig");
