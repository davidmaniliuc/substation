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

    // Execution-diff trace harness (loads BIOS/disc at runtime, logs syscalls).
    const trace_exe = b.addExecutable(.{
        .name = "ps1-trace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-trace/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    trace_exe.root_module.addImport("ps1_core", core_mod);
    b.installArtifact(trace_exe);

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

    const test_step = b.step("test", "Run emulator core unit tests");

    const unit_test_files = [_][]const u8{
        "ps1-core/tests/disc_test.zig",
        "ps1-core/tests/cdrom_test.zig",
        "ps1-core/tests/cpu_test.zig",
        "ps1-core/tests/gte_test.zig",
        "ps1-core/tests/dma_test.zig",
        "ps1-core/tests/gpu_test.zig",
        "ps1-core/tests/spu_test.zig",
    };

    for (unit_test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.addImport("ps1_core", core_mod);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ROM test suites. Each is its own build step so a suite can be run on its
    // own; both also compile-check (and self-skip via `enable_rom_tests=false`)
    // under `zig build test`. The `rom_test_options` flag is a compile-time
    // option, not a `-D` CLI flag.
    const RomSuite = struct { step: []const u8, desc: []const u8, file: []const u8 };
    const rom_suites = [_]RomSuite{
        .{
            .step = "test-roms-pl",
            .desc = "Run the PeterLemon/PSX graphical-conformance ROM suite",
            .file = "ps1-core/tests/peterlemon_test.zig",
        },
        .{
            .step = "test-roms-ja",
            .desc = "Run the JaCzekanski hardware-conformance ROM suite",
            .file = "ps1-core/tests/jaczekanski_test.zig",
        },
    };

    for (rom_suites) |suite| {
        // Compile-check + self-skip under `zig build test`.
        const skip_opts = b.addOptions();
        skip_opts.addOption(bool, "enable_rom_tests", false);
        const skip_t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(suite.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        skip_t.root_module.addImport("ps1_core", core_mod);
        skip_t.root_module.addOptions("rom_test_options", skip_opts);
        test_step.dependOn(&b.addRunArtifact(skip_t).step);

        // Dedicated suite step with the ROM tests actually enabled.
        const opts = b.addOptions();
        opts.addOption(bool, "enable_rom_tests", true);
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(suite.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.addImport("ps1_core", core_mod);
        t.root_module.addOptions("rom_test_options", opts);
        const suite_step = b.step(suite.step, suite.desc);
        suite_step.dependOn(&b.addRunArtifact(t).step);
    }
}
