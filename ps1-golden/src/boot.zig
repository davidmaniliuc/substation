//! Booting a trace workload and stepping it frame by frame: what every
//! `ps1-golden` harness shares, whatever it then does with the machine.

const std = @import("std");
const ps1 = @import("ps1_core");
const golden = @import("golden.zig");
const script = @import("script.zig");

/// A LibCrypt disc without its `.sbi` never gets past its own protection
/// check, so a run without one records a loop, not a boot.
fn attachSbi(a: std.mem.Allocator, io: std.Io, d: *ps1.disc.Disc, cue_path: []const u8) !void {
    const sbi_path = try std.fmt.allocPrint(a, "{s}.sbi", .{cue_path[0 .. cue_path.len - 4]});
    if (std.Io.Dir.cwd().readFileAlloc(io, sbi_path, a, .limited(1 << 20))) |sbi| {
        d.setSbi(sbi);
    } else |_| {}
}

/// BIOS, disc image, cue and LibCrypt sidecar. Shared by every
/// harness that boots a workload; they differ only in what they do with it.
pub fn loadMachine(
    a: std.mem.Allocator,
    io: std.Io,
    wl: golden.Workload,
    bios_override: ?[]const u8,
    bus: *ps1.memory.Bus,
) !void {
    // The disc is attached BEFORE the BIOS is read, because the disc is what
    // says which BIOS it wants. `wl.bios_path` reads that off the rip's name,
    // which is a guess: Final Fantasy IX (France) carries no `(Europe)` token
    // and would draw a US BIOS and stop at the region-lock screen.
    var chosen = wl.bios_path;

    switch (wl.source) {
        // A PS-EXE sideload attaches nothing here. It needs the BIOS booted far
        // enough to have set up its jump tables before loadExe can run, and
        // loadMachine does not own the Cpu — so the caller boots, then calls
        // sideloadExe below.
        .bios_only, .exe => {},
        .disc => |cue_path| {
            const cue_text = try std.Io.Dir.cwd().readFileAlloc(io, cue_path, a, .limited(1 << 20));
            const bin_path = try std.fmt.allocPrint(a, "{s}.bin", .{cue_path[0 .. cue_path.len - 4]});
            const bin_bytes = try std.Io.Dir.cwd().readFileAlloc(io, bin_path, a, .limited(900 * 1024 * 1024));
            var d = ps1.disc.Disc.initFromCue(cue_text, bin_bytes);

            try attachSbi(a, io, &d, cue_path);

            if (ps1.discid.identify(d).region) |region| chosen = golden.biosForRegion(region);
            bus.cdrom.setDisc(d);
        },
        .chd => |src| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, src.chd, a, .limited(1 << 30));
            var d = ps1.disc.Disc.initFromChd(try ps1.chd.Reader.open(a, bytes));
            try attachSbi(a, io, &d, src.cue);
            if (ps1.discid.identify(d).region) |region| chosen = golden.biosForRegion(region);
            bus.cdrom.setDisc(d);
        },
    }

    // An explicit --bios= beats both, so a run can be pointed at any BIOS
    // regardless of what the disc asks for.
    const bios = try std.Io.Dir.cwd().readFileAlloc(
        io,
        bios_override orelse chosen,
        a,
        .limited(1 << 20),
    );
    defer a.free(bios);
    if (bios.len != 512 * 1024) return error.BadBiosSize;
    @memcpy(bus.bios[0..], bios);
}

/// The `script.Pad` button schedule and vblank-rising-edge frame-boundary detector, shared
/// by `runStreamVerify` and `runStreamCapture`. It must be the ONE place that
/// owns this, not two copies: `stream-verify` is what proves a recorded
/// stream reconstructs VRAM, and `stream-capture` is what writes the streams
/// that get banked as fixtures, so a schedule that drifts between them would
/// silently stop describing the artifact.
pub const FrameStepper = struct {
    pad: script.Pad = .{},
    prev_vblank: bool = false,
    /// `step()` calls run so far: instructions, DMA words, interrupt entries.
    i: u64 = 0,

    pub const Frame = struct {
        stream: ps1.gpu.command.Stream,
        /// The count when the run that reached the boundary began. Under the
        /// interpreter that is the old per-instruction index, so probe logs
        /// and `--capture-from` keep their meaning.
        at: u64,
    };

    /// Drives the pad and one `cpu.run()`. Returns the drained stream when
    /// the run lands on a vblank rising edge (a frame boundary).
    pub fn step(self: *FrameStepper, cpu: *ps1.cpu.Cpu, bus: *ps1.memory.Bus) ?Frame {
        if (self.pad.maskAt(self.i)) |m| bus.sio.setButtons(m);
        const at = self.i;
        self.i += cpu.run();

        const vblank = bus.gpu.is_vblank;
        defer self.prev_vblank = vblank;
        if (!vblank or self.prev_vblank) return null;

        // The stream aliases the recorder's storage and is valid only until
        // emulation resumes, so callers must consume it before stepping again.
        return .{ .stream = bus.gpu.sink.rec.takeFrame(), .at = at };
    }
};

pub const Diff = struct { pixels: usize, index: usize, want: u16, got: u16 };

/// The equality fast path is load-bearing, not a micro-optimisation. This runs
/// once per emulated FRAME — on the order of 25,000 frames across the ten
/// workloads — and the counting loop below cannot vectorise: it carries a
/// dependency and an early-exit branch, so it is ~10^10 scalar compares on top
/// of a replay that already doubles every rasterisation. `std.mem.eql` lowers
/// to a vectorised memcmp and covers the case that holds on every frame except
/// the failing one.
pub fn firstDiff(want: *const ps1.gpu.Vram, got: *const ps1.gpu.Vram) ?Diff {
    if (std.mem.eql(u16, &want.data, &got.data)) return null;

    var found: ?Diff = null;
    var count: usize = 0;
    for (want.data, got.data, 0..) |w, g, i| {
        if (w == g) continue;
        count += 1;
        if (found == null) found = .{ .pixels = 0, .index = i, .want = w, .got = g };
    }
    if (found) |*d| {
        d.pixels = count;
        return d.*;
    }
    return null;
}

/// The block cache frees a block on every invalidation for the whole run,
/// so it takes the process allocator: a workload arena would keep every
/// block it ever freed.
pub fn selectEngine(cpu: *ps1.cpu.Cpu, engine: ps1.recompiler.Engine, jit_lower: ps1.recompiler.jit.Lowering) !void {
    try ps1.recompiler.setEngine(cpu, std.heap.smp_allocator, engine);
    ps1.recompiler.setLowering(cpu.bus, jit_lower);
}
