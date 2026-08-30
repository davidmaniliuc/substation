const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.createModule(.{
        .root_source_file = b.path("ps1-core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Which GPU sink the core compiles with.
    //
    // `.software` is today's path: gp0.zig's effects go straight to the
    // rasterizer and nothing else, and `sink.Storage` is a zero-sized struct,
    // so a frontend that never asks for a command stream carries neither the
    // recorder's several megabytes nor a branch. `.dual` rasterizes AND
    // records.
    //
    // Selected per CORE MODULE rather than per frontend, because the sink
    // lives inside Gpu, which lives inside Bus, which cpu.zig threads
    // everywhere: a generic Gpu would go viral through the CPU.
    const GpuSink = enum { software, dual };

    const software_sink = b.addOptions();
    software_sink.addOption(GpuSink, "gpu_sink", .software);
    core_mod.addOptions("gpu_options", software_sink);

    const recording_sink = b.addOptions();
    recording_sink.addOption(GpuSink, "gpu_sink", .dual);

    // A second copy of the core, compiled with the recorder present. Used by
    // ps1-golden's `stream-verify`, the round-trip test and the ROM suites;
    // every other consumer keeps `core_mod` and pays nothing.
    const record_core_mod = b.createModule(.{
        .root_source_file = b.path("ps1-core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    record_core_mod.addOptions("gpu_options", recording_sink);

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

    // Trace-equivalence golden harness. The behaviour-freeze net for the core
    // refactor: hashes full machine state every N instructions across a fixed
    // set of boots and diffs against checked-in goldens. Run it ReleaseFast.
    const golden_exe = b.addExecutable(.{
        .name = "ps1-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-golden/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The recording core, so `stream-verify` exists at all. `capture`/`verify`
    // are unaffected: the recorder is armed at runtime and defaults to off.
    golden_exe.root_module.addImport("ps1_core", record_core_mod);
    b.installArtifact(golden_exe);

    const golden_run = b.addRunArtifact(golden_exe);
    golden_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| golden_run.addArgs(args);
    const golden_step = b.step("trace-golden", "Capture or verify machine-state trace goldens");
    golden_step.dependOn(&golden_run.step);

    // Regenerates the .p1fx fixtures the Swift bridge tests read. Separate from
    // `trace-golden` because it is a producer, not a gate, and because
    // ps1-macos/test.sh names it in its prerequisite warning.
    //
    // Filtered runs, not one bare `stream-capture`: `main.zig` only skips a
    // workload when `--filter` is given, so an unfiltered run would also
    // capture all nine 600M-instruction disc workloads (~90 MiB apiece for one
    // disc alone) instead of the six `pl-*` ROMs plus the measured windows the
    // plan's fixture set actually wants. The runs are chained, not parallel,
    // because every `stream-capture` invocation writes `synthetic-movers.p1fx`
    // unconditionally regardless of filter, and independent steps would race
    // on that path under zig's parallel runner.
    const fixtures_run_pl = b.addRunArtifact(golden_exe);
    fixtures_run_pl.step.dependOn(b.getInstallStep());
    fixtures_run_pl.addArgs(&.{ "stream-capture", "--filter=pl-" });
    const fixtures_run_croc = b.addRunArtifact(golden_exe);
    fixtures_run_croc.step.dependOn(&fixtures_run_pl.step);
    fixtures_run_croc.addArgs(&.{ "stream-capture", "--filter=croc" });

    // The two geometry workloads. Croc's window is FMV — 1,014 transfers, 50
    // fills and zero draw records — so it covers the movers at real payload
    // sizes and nothing else. These two are the real-game half of Phase B's
    // gate: triangles, textured rectangles and VRAM->VRAM copies from actual
    // game software rather than from a synthetic generator.
    const geometry_filters = [_][]const u8{
        "silent-hill-usa",
        "tr1-usa-v1-1",
    };
    var prev_fixture_run = fixtures_run_croc;
    for (geometry_filters) |f| {
        const run = b.addRunArtifact(golden_exe);
        run.step.dependOn(&prev_fixture_run.step);
        run.addArgs(&.{ "stream-capture", b.fmt("--filter={s}", .{f}) });
        prev_fixture_run = run;
    }
    const fixtures_step = b.step("fixtures", "Write .p1fx command-stream fixtures to zig-out/fixtures");
    fixtures_step.dependOn(&prev_fixture_run.step);

    // The browser frontend is always built ReleaseFast, whatever -Doptimize says.
    // It runs one emulated frame per requestAnimationFrame, so it can never go
    // faster than real-time — only slower. A Debug core manages ~5M instr/s
    // against the ~11.7M instr/s a real PS1 needs, i.e. 0.45x speed, which turns
    // a 23-second boot into a 2-minute one and reads as a hang. Debug builds of
    // the core belong in ps1-debug/ps1-trace, where you can actually step them.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    // Needs its own core module: core_mod carries the top-level `optimize`, and
    // the core is where every cycle is spent, so sharing it would leave the
    // emulator in Debug no matter what the executable is built as.
    const wasm_core_mod = b.createModule(.{
        .root_source_file = b.path("ps1-core/src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseFast,
    });
    wasm_core_mod.addOptions("gpu_options", software_sink);

    const wasm = b.addExecutable(.{
        .name = "emulator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-wasm/src/main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseFast,
        }),
    });
    wasm.root_module.addImport("ps1_core", wasm_core_mod);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.installArtifact(wasm);

    const test_step = b.step("test", "Run emulator core unit tests");

    // A single substring filter across every unit-test binary. `zig build test`
    // builds and runs fifteen of them; when iterating on one behaviour that is
    // fifteen process launches for one assertion.
    const test_filter = b.option([]const u8, "test-filter", "Only run unit tests whose name contains this substring");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const unit_test_files = [_][]const u8{
        "ps1-core/tests/disc_test.zig",
        "ps1-core/tests/cdrom_test.zig",
        "ps1-core/tests/cpu_test.zig",
        "ps1-core/tests/gte_test.zig",
        "ps1-core/tests/dma_test.zig",
        "ps1-core/tests/gpu_test.zig",
        "ps1-core/tests/spu_test.zig",
        "ps1-core/tests/sio_test.zig",
        "ps1-core/tests/mdec_test.zig",
    };

    for (unit_test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        t.root_module.addImport("ps1_core", core_mod);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Unit tests for the golden harness. It imports ps1_core for the state
    // hashers, so it needs the same module the frontends get.
    const golden_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-golden/src/golden_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    golden_test.root_module.addImport("ps1_core", core_mod);
    test_step.dependOn(&b.addRunArtifact(golden_test).step);

    // The C ABI frontend.
    // The RECORDING core, not the shared one: the shipped libps1core.a is
    // built .dual (below), and a test binary compiled against a configuration
    // no frontend links would leave ps1_take_frame_stream untested.
    const capi_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-capi/src/capi_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    capi_test.root_module.addImport("ps1_core", record_core_mod);
    test_step.dependOn(&b.addRunArtifact(capi_test).step);

    // The command-stream round trip. Its own binary because it needs the
    // recording core module; the nine files in `unit_test_files` do not.
    const stream_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-core/tests/gpu_stream_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    stream_test.root_module.addImport("ps1_core", record_core_mod);
    test_step.dependOn(&b.addRunArtifact(stream_test).step);

    // The fixture format and its hash. Needs ps1_core for `gpu.Vram`; the
    // recording module is not required, but sharing it avoids a fourth core
    // module compile.
    const fixture_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-golden/src/fixture_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    fixture_test.root_module.addImport("ps1_core", record_core_mod);
    // The committed fixture, reachable from @embedFile. A plain relative path
    // would have to climb out of ps1-golden/src, which is this module's root.
    fixture_test.root_module.addAnonymousImport("committed_synthetic", .{
        .root_source_file = b.path("ps1-core/tests/goldens/fixtures/synthetic-movers.p1fx"),
    });
    fixture_test.root_module.addAnonymousImport("committed_primitives", .{
        .root_source_file = b.path("ps1-core/tests/goldens/fixtures/synthetic-primitives.p1fx"),
    });
    test_step.dependOn(&b.addRunArtifact(fixture_test).step);

    // The shipped C ABI library.
    //
    // Emitted as one OBJECT and repacked with Apple's libtool, not as a Zig
    // static library: Zig's archiver writes members that Apple's ld rejects
    // outright ("64-bit mach-o not 8-byte aligned"), so `-lps1core` against a
    // Zig-produced .a fails to link.
    //
    // Its core module is pinned to ReleaseFast regardless of -Doptimize, for
    // the same reason the wasm build is: a Debug core runs ~0.45x real time,
    // which turns a 23-second boot into two minutes and reads as a hang.
    const capi_core_mod = b.createModule(.{
        .root_source_file = b.path("ps1-core/src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    // .dual, per the parent spec's Decision 3: the macOS app needs BOTH the
    // software shadow (24bpp scanout, the resync, the divergence oracle) and
    // the recorded stream. Costs ~6.8 MB of Recorder inside Bus and a `push`
    // per GP0 effect, both accepted there.
    capi_core_mod.addOptions("gpu_options", recording_sink);

    const capi_obj = b.addObject(.{
        .name = "ps1capi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-capi/src/root.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    capi_obj.root_module.addImport("ps1_core", capi_core_mod);

    const repack = b.addSystemCommand(&.{ "xcrun", "libtool", "-static", "-o" });
    const lib_path = repack.addOutputFileArg("libps1core.a");
    repack.addFileArg(capi_obj.getEmittedBin());

    const install_lib = b.addInstallFile(lib_path, "lib/libps1core.a");

    const capi_lib_step = b.step("capi-lib", "Build libps1core.a for the macOS app");
    capi_lib_step.dependOn(&install_lib.step);

    // The display shader, compiled OFFLINE and embedded in its own static
    // library.
    //
    // `metal`/`metallib` ship with Xcode, not with Command Line Tools, and on
    // Xcode 16.3+ they are a further separate download
    // (`xcodebuild -downloadComponent MetalToolchain`). That toolchain
    // requirement is why this is not folded into `capi-lib`: libps1core.a is
    // the portable emulator ABI and must stay buildable without it.
    //
    // Driving the two tools from here rather than from a shell script is what
    // gets the shader a real place in the build graph — edit the .metal and
    // `zig build macos` recompiles it, and only it.
    const metal_available = builtin.os.tag == .macos and blk: {
        // Probed at CONFIGURE time so the failure can name the two install
        // steps. Left to xcrun the whole message is "unable to find utility
        // metal", which says nothing about the component download.
        var status: u8 = 0;
        _ = b.runAllowFail(
            &.{ "xcrun", "-f", "metal" },
            &status,
            .ignore,
        ) catch break :blk false;
        break :blk status == 0;
    };

    // Both shader sources go into ONE metallib: `metallib` takes several
    // inputs, so the single embedded blob and the single MTLLibrary on the
    // Swift side keep working as the shader count grows.
    const metal_sources = [_][]const u8{
        "ps1-macos/Shaders/DisplayShader.metal",
        "ps1-macos/Shaders/Rasterizer.metal",
    };

    const metal_lib = b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metallib", "-o" });
    const metal_lib_path = metal_lib.addOutputFileArg("ps1.metallib");
    for (metal_sources) |src| {
        const ir = b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metal", "-Werror", "-o" });
        const ir_path = ir.addOutputFileArg(b.fmt("{s}.ir", .{std.fs.path.stem(src)}));
        ir.addArgs(&.{"-c"});
        ir.addFileArg(b.path(src));
        metal_lib.addFileArg(ir_path);
    }

    const shader_obj = b.addObject(.{
        .name = "ps1shaders",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-macos/Shaders/embed.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    shader_obj.root_module.addAnonymousImport("metallib", .{
        .root_source_file = metal_lib_path,
    });

    // Repacked with Apple's libtool for the same reason capi_obj is.
    const shader_repack = b.addSystemCommand(&.{ "xcrun", "libtool", "-static", "-o" });
    const shader_lib_path = shader_repack.addOutputFileArg("libps1shaders.a");
    shader_repack.addFileArg(shader_obj.getEmittedBin());

    const install_shader_lib = b.addInstallFile(shader_lib_path, "lib/libps1shaders.a");

    const metallib_step = b.step("metallib", "Compile the Metal shaders into libps1shaders.a");
    const missing_metal = b.addFail(
        \\the Metal compiler is unavailable. `metal` and `metallib` ship with Xcode, not
        \\with Command Line Tools, and on Xcode 16.3+ the toolchain is a FURTHER separate
        \\download on top of Xcode itself. All three steps are needed:
        \\
        \\    1. install Xcode (~20 GB installed, and more than that transiently)
        \\    2. sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
        \\    3. xcodebuild -downloadComponent MetalToolchain
        \\
        \\Step 2 failing with "invalid developer directory" means step 1 has not happened.
    );
    if (metal_available) {
        metallib_step.dependOn(&install_shader_lib.step);
    } else {
        metallib_step.dependOn(&missing_metal.step);
    }

    // The product. macOS-only: it must fail with a clear message on any other
    // target rather than producing a broken bundle.
    const macos_step = b.step("macos", "Build the native macOS app bundle (zig-out/PS1.app)");
    if (builtin.os.tag == .macos) {
        const app = b.addSystemCommand(&.{"ps1-macos/build.sh"});
        app.step.dependOn(&install_lib.step);
        app.step.dependOn(metallib_step);
        macos_step.dependOn(&app.step);
    } else {
        macos_step.dependOn(&b.addFail(
            "`zig build macos` requires macOS (SwiftUI, Metal and AudioToolbox are host frameworks)",
        ).step);
    }

    // ROM test suites. Each is its own build step so a suite can be run on its
    // own; both also compile-check (and self-skip via `enable_rom_tests=false`)
    // under `zig build test`. The `rom_test_options` flag is a compile-time
    // option, not a `-D` CLI flag.
    // `-Drom-filter=<substring>` narrows a suite to the matching tests, so a
    // single ROM can be iterated on without paying for the whole suite.
    const rom_filter = b.option([]const u8, "rom-filter", "Only run ROM tests whose name contains this substring");
    const rom_filters: []const []const u8 = if (rom_filter) |f| &.{f} else &.{};

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
        // Both ROM suites compile against the recording core: peterlemon_test
        // replays each frame's command stream against full VRAM. The JA suite
        // gains an unused recorder — 6.5 MB inside an already heap-allocated
        // Bus, and no branch it does not take — which is cheaper than keeping
        // a third core module alive to avoid it.
        skip_t.root_module.addImport("ps1_core", record_core_mod);
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
            .filters = rom_filters,
        });
        t.root_module.addImport("ps1_core", record_core_mod);
        t.root_module.addOptions("rom_test_options", opts);
        const suite_step = b.step(suite.step, suite.desc);
        suite_step.dependOn(&b.addRunArtifact(t).step);
    }
}
