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
        "ps1-core/tests/rom_test.zig",
    };

    for (test_files) |path| {
        const is_rom_test = std.mem.eql(u8, path, "ps1-core/tests/rom_test.zig");
        const rom_test_options = b.addOptions();
        rom_test_options.addOption(bool, "enable_rom_tests", false);

        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.addImport("ps1_core", core_mod);
        if (is_rom_test) t.root_module.addOptions("rom_test_options", rom_test_options);

        const run_test = b.addRunArtifact(t);
        test_step.dependOn(&run_test.step);
    }

    const rom_test_options = b.addOptions();
    rom_test_options.addOption(bool, "enable_rom_tests", true);

    const rom_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-core/tests/rom_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rom_tests.root_module.addImport("ps1_core", core_mod);
    rom_tests.root_module.addOptions("rom_test_options", rom_test_options);

    const run_rom_tests = b.addRunArtifact(rom_tests);
    const rom_test_step = b.step("rom-test", "Run JaCzekanski PS1 ROM integration tests");
    rom_test_step.dependOn(&run_rom_tests.step);
}
