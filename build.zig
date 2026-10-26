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
    run_cmd.addPassthruArgs();
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
    // One copy of the multi-FILE cue loader, for ps1-trace and ps1-golden's chd-verify.
    const cue_files_mod = b.createModule(.{
        .root_source_file = b.path("ps1-trace/src/cue_files.zig"),
        .target = target,
        .optimize = optimize,
    });
    trace_exe.root_module.addImport("cue_files", cue_files_mod);
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
    golden_exe.root_module.addImport("cue_files", cue_files_mod);
    b.installArtifact(golden_exe);

    const golden_run = b.addRunArtifact(golden_exe);
    golden_run.step.dependOn(b.getInstallStep());
    golden_run.addPassthruArgs();
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
    // The PGXP-ON parity fixture. Every other fixture in the corpus is
    // captured with PGXP off, so every `rw` in them is zero and the
    // perspective interpolant is uncovered by Gate 1 and Gate 2 alike. This is
    // the same tr1 window with PGXP on, and the Swift gate replaying it is the
    // whole automated coverage the shared integer path has.
    //
    // Chained onto the run before it for the same reason every other capture
    // is: `stream-capture` writes `synthetic-movers.p1fx` unconditionally,
    // regardless of filter, so parallel runs would race on that path.
    const fixtures_run_pgxp = b.addRunArtifact(golden_exe);
    fixtures_run_pgxp.step.dependOn(&prev_fixture_run.step);
    fixtures_run_pgxp.addArgs(&.{ "stream-capture", "--filter=tr1-usa-v1-1", "--pgxp-on" });
    prev_fixture_run = fixtures_run_pgxp;

    // The benchmark's Crash window (Metal renderer performance spec): ~890
    // draws per frame at 500M-700M instructions, one render pass per frame,
    // no VRAM->VRAM copies. A per-filter window, so its own run.
    const fixtures_run_crash = b.addRunArtifact(golden_exe);
    fixtures_run_crash.step.dependOn(&prev_fixture_run.step);
    fixtures_run_crash.addArgs(&.{
        "stream-capture",           "--filter=crash-bandicoot-warped",
        "--capture-from=500000000", "--frames=100",
        "--instructions=700000000",
    });
    prev_fixture_run = fixtures_run_crash;

    const fixtures_step = b.step("fixtures", "Write .p1fx command-stream fixtures to zig-out/fixtures");
    fixtures_step.dependOn(&prev_fixture_run.step);

    // The browser frontend is always built ReleaseFast, whatever -Doptimize says.
    // It runs one emulated frame per requestAnimationFrame, so it can never go
    // faster than real-time — only slower. A Debug core manages ~5M instr/s
    // against the ~11.7M instr/s a real PS1 needs, i.e. 0.45x speed, which turns
    // a 23-second boot into a 2-minute one and reads as a hang. Debug builds of
    // the core belong in ps1-debug/ps1-trace, where you can actually step them.
    // simd128 lets the core's `@Vector` code (the MDEC IDCT, the triangle
    // coverage test) lower to wasm SIMD instead of being scalarised; every
    // current browser engine supports it, and one without it refuses the
    // module at compile time rather than running it wrong.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
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
    const install_wasm = b.addInstallArtifact(wasm, .{});
    b.getInstallStep().dependOn(&install_wasm.step);

    // The npm package: the wasm above plus the TypeScript layer, bundled by
    // Bun. Found lazily, so a machine without Bun fails only this step, and
    // with a message naming the program.
    const web_step = b.step("web", "Build the ps1-web package into ps1-web/dist/");
    const bun = b.findProgramLazy(.{ .names = &.{"bun"} });
    const web_deps = std.Build.Step.Run.create(b, "bun install");
    web_deps.addFileArg(bun);
    web_deps.addArgs(&.{ "install", "--frozen-lockfile" });
    web_deps.setCwd(b.path("ps1-web"));
    const web = std.Build.Step.Run.create(b, "bun run build");
    web.addFileArg(bun);
    web.addArgs(&.{ "run", "build" });
    web.setCwd(b.path("ps1-web"));
    web.step.dependOn(&install_wasm.step);
    web.step.dependOn(&web_deps.step);
    web_step.dependOn(&web.step);

    const test_step = b.step("test", "Run emulator core unit tests");

    // A single substring filter across every unit-test binary. `zig build test`
    // builds and runs 17 of them; when iterating on one behaviour that is
    // 17 process launches for one assertion.
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
        "ps1-core/tests/discid_test.zig",
        "ps1-core/tests/bios_test.zig",
        "ps1-core/tests/pgxp_test.zig",
        "ps1-core/tests/timer_test.zig",
        "ps1-core/tests/savestate_test.zig",
        "ps1-core/tests/scheduler_test.zig",
        "ps1-core/tests/recompiler_test.zig",
        "ps1-core/tests/jit_test.zig",
        "ps1-core/tests/chd_test.zig",
        "ps1-core/tests/rewind_test.zig",
        "ps1-core/tests/ppf_test.zig",
        "ps1-core/tests/gpu_walk_test.zig",
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
    // no frontend links would leave the recorder's per-frame drain
    // (`Recorder.takeFrame`, which the session's frame path calls) untested.
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
    // recording core module; the 17 files in `unit_test_files` do not.
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

    // The benchmark harness, once per gpu_sink: `-dual` is the configuration
    // the macOS app ships, `-sw` the one every other native frontend uses, and
    // the gap between them is the price of recording the command stream.
    for ([_]struct { name: []const u8, mod: *std.Build.Module }{
        .{ .name = "ps1-bench-sw", .mod = core_mod },
        .{ .name = "ps1-bench-dual", .mod = record_core_mod },
    }) |b_cfg| {
        const bench = b.addExecutable(.{
            .name = b_cfg.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("ps1-bench/main.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        bench.root_module.addImport("ps1_core", b_cfg.mod);
        b.getInstallStep().dependOn(&b.addInstallArtifact(bench, .{}).step);
    }

    // The two archives the macOS app links are built for the app's deployment
    // target (`MACOSX_DEPLOYMENT_TARGET` in PS1.xcodeproj), not for the
    // host's macOS: otherwise ld warns that every object was "built for newer
    // macOS version than being linked", and the app would claim a macOS it
    // was never compiled for. Keep the two numbers in step.
    const app_target = b.resolveTargetQuery(blk: {
        var q = target.query;
        if (target.result.os.tag == .macos) q.os_version_min = .{ .semver = .{ .major = 26, .minor = 0, .patch = 0 } };
        break :blk q;
    });

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
        .target = app_target,
        .optimize = .ReleaseFast,
    });
    // .dual, per the parent spec's Decision 3: the macOS app needs BOTH the
    // software shadow (24bpp scanout, the resync, the divergence oracle) and
    // the recorded stream. Costs ~6.8 MB of Recorder inside Bus and a `push`
    // per GP0 effect, both accepted there.
    capi_core_mod.addOptions("gpu_options", recording_sink);

    // Its root is `lib.zig`: the machine ABI and, on arm64 macOS, the session
    // ABI, whose modules are built a second time over this core. The shader
    // library it references is `libps1shaders.a`, linked beside it.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("ps1-capi/src/root.zig"),
        .target = app_target,
        .optimize = .ReleaseFast,
    });
    capi_mod.addImport("ps1_core", capi_core_mod);
    const capi_obj = b.addObject(.{
        .name = "ps1capi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-capi/src/lib.zig"),
            .target = app_target,
            .optimize = .ReleaseFast,
        }),
    });
    capi_obj.root_module.addImport("ps1_capi", capi_mod);
    if (app_target.result.os.tag == .macos and app_target.result.cpu.arch == .aarch64) {
        const capi_metal_mod = metalModule(b, app_target, .ReleaseFast, capi_core_mod);
        capi_obj.root_module.addImport("ps1_session", sessionModule(b, app_target, .ReleaseFast, capi_core_mod, capi_metal_mod, capi_mod));
    }

    const repack = b.addSystemCommand(&.{ "xcrun", "libtool", "-static", "-o" });
    const lib_path = repack.addOutputFileArg("libps1core.a");
    repack.addFileArg(capi_obj.getEmittedBin());

    const install_lib = b.addInstallFile(lib_path, "lib/libps1core.a");

    const capi_lib_step = b.step("capi-lib", "Build libps1core.a for the macOS app");
    capi_lib_step.dependOn(&install_lib.step);
    // The archive must carry both ABIs: a module left unreferenced by
    // `lib.zig` compiles to nothing and fails only at the app's link. The
    // frame-stream drain must be ABSENT: the session takes each frame's
    // records from the recorder itself, and nothing outside it may drain them.
    if (app_target.result.os.tag == .macos and app_target.result.cpu.arch == .aarch64) {
        const symbols = b.addSystemCommand(&.{
            "sh",       "-c",
            \\nm -g "$1" | grep -q ' T _ps1_session_new$' ||
            \\{ echo "libps1core.a lacks _ps1_session_new" >&2; exit 1; }
            \\! nm -g "$1" | grep -q ' T _ps1_take_frame_stream$' ||
            \\{ echo "libps1core.a still exports _ps1_take_frame_stream" >&2; exit 1; }
            ,
            "nm-check",
        });
        symbols.addFileArg(lib_path);
        capi_lib_step.dependOn(&symbols.step);
    }

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
        // metal", which says nothing about the component download. The tool
        // is RUN, not merely located: `xcrun -f` resolves the stub an Xcode
        // update leaves behind while the toolchain component is absent.
        var status: u8 = 0;
        _ = b.runAllowFail(
            &.{ "xcrun", "metal", "--version" },
            &status,
            .ignore,
        ) catch break :blk false;
        break :blk status == 0;
    };

    // Both shader sources go into ONE metallib: `metallib` takes several
    // inputs, so the single embedded blob and the single MTLLibrary on the
    // Swift side keep working as the shader count grows.
    const metal_sources = [_][]const u8{
        "ps1-metal/shaders/DisplayShader.metal",
        "ps1-metal/shaders/Rasterizer.metal",
    };

    // The headers the two sources `#include`. Declared as INPUTS even though
    // they are never passed as arguments: without this the cache key covers
    // only the `.metal` files, so a header-only edit — which is where the
    // shared rasterizer expressions actually live — leaves the previous
    // metallib installed and the app silently running the OLD shader. That is
    // not hypothetical: it is what made the first attempt to prove the PGXP
    // parity gate could fail report a green that meant nothing.
    const metal_headers = [_][]const u8{
        "ps1-metal/shaders/Ps1Color.h",
        "ps1-metal/shaders/PrimInstance.h",
    };

    const metal_lib = b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metallib", "-o" });
    const metal_lib_path = metal_lib.addOutputFileArg("ps1.metallib");
    for (metal_sources) |src| {
        const ir = b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metal", "-Werror", "-o" });
        const ir_path = ir.addOutputFileArg(b.fmt("{s}.ir", .{std.fs.path.stem(src)}));
        ir.addArgs(&.{"-c"});
        ir.addFileArg(b.path(src));
        for (metal_headers) |h| ir.addFileInput(b.path(h));
        metal_lib.addFileArg(ir_path);
    }

    const shader_obj = b.addObject(.{
        .name = "ps1shaders",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-metal/shaders/embed.zig"),
            .target = app_target,
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

    // The Metal renderer as a Zig module. Its tests are split by what they
    // need: `pure_test` touches no framework and runs under `zig build test`
    // on any host, `metal_test` needs a device and the shader library and is
    // its own macOS-only step. `capi-lib` builds its own copy over its own
    // core, and never the shaders.
    const metal_mod = metalModule(b, target, optimize, record_core_mod);

    const metal_pure_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ps1-metal/pure_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    metal_pure_test.root_module.addImport("ps1_metal", metal_mod);
    metal_pure_test.root_module.addImport("ps1_core", record_core_mod);
    test_step.dependOn(&b.addRunArtifact(metal_pure_test).step);

    // The session: the emulator thread, audio and cards below the user
    // interface. macOS-only (it speaks CoreAudio and the render thread's
    // AppKit), so its no-device tests join `zig build test` on macOS hosts
    // only; anything needing Metal or an audio device runs under `test-metal`.
    const session_capi_mod = b.createModule(.{
        .root_source_file = b.path("ps1-capi/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    session_capi_mod.addImport("ps1_core", record_core_mod);
    const session_mod = sessionModule(b, target, optimize, record_core_mod, metal_mod, session_capi_mod);
    if (builtin.os.tag == .macos) {
        const session_pure_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("ps1-session/pure_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        session_pure_test.root_module.addImport("ps1_session", session_mod);
        session_pure_test.root_module.addImport("ps1_metal", metal_mod);
        session_pure_test.root_module.addImport("ps1_core", record_core_mod);
        // The thumbnail's PNG: plain C, no device.
        for ([_][]const u8{ "CoreGraphics", "ImageIO", "CoreFoundation" }) |framework| {
            session_pure_test.root_module.linkFramework(framework, .{});
        }
        // The emulator thread's autorelease pool.
        session_pure_test.root_module.linkSystemLibrary("objc", .{});
        test_step.dependOn(&b.addRunArtifact(session_pure_test).step);
    }

    // `-Dmetal-filter=<substring>` narrows `test-metal`. `test-metal-validate`
    // runs the tests whose names carry `[validate]` under Metal's API and
    // shader validation layers: Gate 1 over the corpus, the true-colour/off
    // corpus equality, one Gate 2 scale ladder and the display pass through
    // the screenshot path. A wrong enum value or an unbound resource that a
    // release run tolerates in silence is reported there. The leak tests stay
    // untagged: the debug layer allocates ~16 MB once on first use, which
    // reads as growth.
    const metal_filter = b.option([]const u8, "metal-filter", "Only run test-metal tests whose name contains this substring");
    const test_metal_step = b.step("test-metal", "Run the Metal renderer tests (macOS, needs the Metal toolchain)");
    const test_metal_validate_step = b.step("test-metal-validate", "Run the [validate]-tagged Metal tests under the Metal validation layers");
    if (metal_available) {
        const filters: []const []const u8 = if (metal_filter) |f| &.{f} else &.{};
        const metal_test = addMetalTest(b, target, optimize, "ps1-metal/metal_test.zig", metal_mod, record_core_mod, shader_obj, filters);
        test_metal_step.dependOn(&b.addRunArtifact(metal_test).step);
        const gpu_bench_test = addMetalTest(b, target, optimize, "ps1-bench/src/gpu_bench_test.zig", metal_mod, record_core_mod, shader_obj, filters);
        test_metal_step.dependOn(&b.addRunArtifact(gpu_bench_test).step);
        // The session's device tests: audio output, the render thread, the
        // layer. macOS only, like the module.
        const session_device_test = addMetalTest(b, target, optimize, "ps1-session/device_test.zig", metal_mod, record_core_mod, shader_obj, filters);
        session_device_test.root_module.addImport("ps1_session", session_mod);
        session_device_test.root_module.linkFramework("AudioToolbox", .{});
        test_metal_step.dependOn(&b.addRunArtifact(session_device_test).step);

        // The renderer benchmark, beside `ps1-bench-dual`/`-sw`: it replays
        // `.p1fx` fixtures through the Zig renderer, so it is installed only
        // where the shaders compile and the target links Metal.
        const gpu_bench = b.addExecutable(.{
            .name = "ps1-bench-gpu",
            .root_module = b.createModule(.{
                .root_source_file = b.path("ps1-bench/src/gpu_main.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        gpu_bench.root_module.addImport("ps1_metal", metal_mod);
        linkMetal(gpu_bench.root_module, shader_obj);
        // objc.zig refuses anything but arm64 Darwin, so an Intel target
        // (or `-Dtarget=x86_64-macos`) must not pull it into plain `zig build`.
        if (target.result.os.tag == .macos and target.result.cpu.arch == .aarch64) b.getInstallStep().dependOn(&b.addInstallArtifact(gpu_bench, .{}).step);

        const validate_test = addMetalTest(b, target, optimize, "ps1-metal/metal_test.zig", metal_mod, record_core_mod, shader_obj, &.{"[validate]"});
        const validate_run = b.addRunArtifact(validate_test);
        validate_run.setEnvironmentVariable("MTL_DEBUG_LAYER", "1");
        validate_run.setEnvironmentVariable("MTL_SHADER_VALIDATION", "1");
        test_metal_validate_step.dependOn(&validate_run.step);
    } else {
        test_metal_step.dependOn(&missing_metal.step);
        test_metal_validate_step.dependOn(&missing_metal.step);
    }

    // The product. macOS-only: it must fail with a clear message on any other
    // target rather than producing a broken bundle.
    const macos_step = b.step("macos", "Build the native macOS app bundle (zig-out/Substation.app)");
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

    // `-Dengine=cached` runs the ROM suites under a block engine. They were
    // written against the interpreter: a timing-sensitive test may differ,
    // and the difference is recorded, not fixed by re-pinning a floor.
    const RomEngine = enum { interpreter, cached, jit };
    const rom_engine = b.option(RomEngine, "engine", "CPU engine for the ROM suites (default interpreter)") orelse .interpreter;

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
        skip_opts.addOption([]const u8, "engine", "interpreter");
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
        opts.addOption([]const u8, "engine", @tagName(rom_engine));
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

/// The Metal renderer over `core_mod`. Built twice: over the recording core
/// for the tests, and over `libps1core.a`'s ReleaseFast core for the session.
fn metalModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
) *std.Build.Module {
    const fixture_mod = b.createModule(.{
        .root_source_file = b.path("ps1-golden/src/fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_mod.addImport("ps1_core", core_mod);
    const m = b.createModule(.{
        .root_source_file = b.path("ps1-metal/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    m.addImport("ps1_core", core_mod);
    m.addImport("fixture", fixture_mod);
    // The instance record is declared once, in C, and both the shader and
    // this module read that declaration.
    const prim_c = b.addTranslateC(.{
        .root_source_file = b.path("ps1-metal/shaders/PrimInstance.h"),
        .target = target,
        .optimize = optimize,
    });
    m.addImport("prim_instance_c", prim_c.createModule());
    return m;
}

/// The session over one core, its renderer and the machine ABI built over
/// that same core.
fn sessionModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    metal_mod: *std.Build.Module,
    capi_mod: *std.Build.Module,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("ps1-session/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    m.addImport("ps1_core", core_mod);
    m.addImport("ps1_metal", metal_mod);
    m.addImport("ps1_capi", capi_mod);
    return m;
}

/// A `test-metal` binary rooted at `root`: every framework the renderer and
/// its harness touch, and the embedded shader library.
fn addMetalTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
    metal_mod: *std.Build.Module,
    core_mod: *std.Build.Module,
    shader_obj: *std.Build.Step.Compile,
    filters: []const []const u8,
) *std.Build.Step.Compile {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        }),
        .filters = filters,
    });
    t.root_module.addImport("ps1_metal", metal_mod);
    // The harness replays every fixture through the software rasterizer as
    // well, so it needs the SAME core module the renderer was built against.
    t.root_module.addImport("ps1_core", core_mod);
    linkMetal(t.root_module, shader_obj);
    return t;
}

/// Every framework `ps1_metal` touches, and the embedded shader library.
fn linkMetal(m: *std.Build.Module, shader_obj: *std.Build.Step.Compile) void {
    for ([_][]const u8{ "Metal", "QuartzCore", "CoreGraphics", "ImageIO", "CoreFoundation", "AppKit" }) |framework| {
        m.linkFramework(framework, .{});
    }
    m.linkSystemLibrary("objc", .{});
    m.addObject(shader_obj);
}
