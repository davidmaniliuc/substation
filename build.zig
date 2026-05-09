const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.createModule(.{
        .root_source_file = b.path("ps1-core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ps1-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-debug/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("ps1_core", core_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the native debug emulator");
    run_step.dependOn(&run_cmd.step);

    const wasm = b.addExecutable(.{
        .name = "emulator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-wasm/src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
        }),
    });
    wasm.root_module.addImport("ps1_core", core_mod);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.installArtifact(wasm);

    const test_step = b.step("test", "Run emulator core tests");

    const test_files = [_][]const u8{
        "ps1-core/tests/cpu_test.zig",
        "ps1-core/tests/gte_test.zig",
        "ps1-core/tests/dma_test.zig",
        "ps1-core/tests/gpu_test.zig",
    };

    for (test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.addImport("ps1_core", core_mod);

        const run_test = b.addRunArtifact(t);
        test_step.dependOn(&run_test.step);
    }
}
