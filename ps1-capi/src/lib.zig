//! The root of `libps1core.a`: the machine ABI (`ps1.h`) and, where the
//! session can run (arm64 macOS), the session ABI (`ps1_session.h`).

const builtin = @import("builtin");

comptime {
    _ = @import("ps1_capi");
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) _ = @import("ps1_session").abi;
}
