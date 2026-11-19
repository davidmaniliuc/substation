//! The one machine a wasm instance holds, and what the HOST owns beside it.
//! `Bus.init` memsets the struct, so the BIOS image, the disc and the cards
//! live here and every rebuilt `Bus` gets them back. `ps1-capi`'s `Handle`
//! is the model; this is its single-instance form.

const std = @import("std");
const ps1 = @import("ps1_core");

const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;
const Disc = ps1.disc.Disc;
const Sio = ps1.sio.Sio;

pub const allocator = std.heap.wasm_allocator;

pub var bus: *Bus = undefined;
pub var cpu: Cpu = undefined;
var built = false;

pub var bios: [ps1.bios.image_bytes]u8 = @splat(0);
pub var bios_loaded = false;
/// Host settings: they outlive every `Bus` this file builds.
pub var fast_boot = false;
pub var engine: ps1.recompiler.Engine = .interpreter;

pub var disc: ?Disc = null;
/// Owned. `disc` borrows them, and a CHD or ECM reader reads from them.
var disc_bytes: []u8 = &.{};
/// Owned copy of the sidecar `disc.sbi` slices into.
var sbi: []u8 = &.{};
/// Owned overlay of the disc's `.ppf`, which `disc.patch` is.
var patch: ps1.ppf.Overlay = .{};
var decoder: ps1.disc_image.Decoder = .none;
/// The executable booted in place of a disc (`loadExe`), owned. Every `Bus`
/// `build` makes borrows its `boot`, so a reset or a state load re-arms it.
pub var exe: ?Exe = null;

pub var memcard: [Sio.memcard_slots][Sio.memcard_bytes]u8 = @splat(@splat(0));

const Machine = struct { bus: *Bus, cpu: Cpu };

/// A program and its `libps`, copied: the parsed segments slice the copies.
pub const Exe = struct {
    bytes: []u8,
    libps: []u8,
    boot: ps1.exe_boot.Boot,

    pub fn deinit(self: *Exe) void {
        self.boot.main.deinit(allocator);
        if (self.boot.libps) |*p| p.deinit(allocator);
        allocator.free(self.bytes);
        allocator.free(self.libps);
    }
};

/// A machine on a fresh `Bus`, carrying the host's BIOS, disc, cards and
/// engine. The engine goes on BEFORE any state load: the load restores the
/// I-cache lines, and selecting an engine afterwards would flush them.
fn build() error{OutOfMemory}!Machine {
    const b = try Bus.init(allocator);
    if (disc) |d| b.cdrom.setDisc(d);
    b.exe_boot = if (exe) |*e| &e.boot else null;
    installBios(b);
    for (0..Sio.memcard_slots) |i| b.sio.setMemoryCardData(i, &memcard[i]);
    var c = Cpu.init(b);
    // A failure leaves the machine on the interpreter, which draws the same frames.
    ps1.recompiler.setEngine(&c, allocator, engine) catch {};
    return .{ .bus = b, .cpu = c };
}

pub fn create() error{OutOfMemory}!void {
    if (built) return;
    const m = try build();
    bus = m.bus;
    cpu = m.cpu;
    built = true;
}

/// Copies the LIVE cards into `memcard` and returns their dirty flags. A
/// rebuild installs the images through `setMemoryCardData`, which clears
/// dirty, so a write the host has not drained yet would otherwise be lost.
fn snapshotCards() [Sio.memcard_slots]bool {
    var dirty: [Sio.memcard_slots]bool = undefined;
    for (0..Sio.memcard_slots) |i| {
        @memcpy(memcard[i][0..], bus.sio.getMemoryCardData(i));
        dirty[i] = bus.sio.isMemoryCardDirty(i);
    }
    return dirty;
}

fn adopt(m: Machine, dirty: [Sio.memcard_slots]bool) void {
    bus.deinit(allocator);
    bus = m.bus;
    cpu = m.cpu;
    for (0..Sio.memcard_slots) |i| {
        if (dirty[i]) bus.sio.memcard_dirty[i] = true;
    }
}

/// The front-panel reset: a new machine, the same BIOS, disc and cards.
pub fn reset() error{OutOfMemory}!void {
    const dirty = snapshotCards();
    adopt(try build(), dirty);
}

/// All-or-nothing: the state is decoded into a fresh machine, swapped in
/// only once every section has parsed. A refusal leaves the running machine
/// exactly as it was.
pub fn loadState(src: []const u8) (error{OutOfMemory} || ps1.savestate.Error)!void {
    const dirty = snapshotCards();
    var m = try build();
    ps1.savestate.load(&m.cpu, src) catch |err| {
        m.bus.deinit(allocator);
        return err;
    };
    adopt(m, dirty);
}

/// Puts the BIOS in a bus's ROM, patched for fast boot only when the host
/// asked for it AND a PlayStation disc is in: with no disc the shell is all
/// there is, and for an audio CD it is the CD player.
pub fn installBios(b: *Bus) void {
    if (!bios_loaded) return;
    ps1.bios.install(b, &bios, fast_boot and isPlayStationDisc());
}

fn isPlayStationDisc() bool {
    const d = disc orelse return false;
    const id = ps1.discid.identify(d);
    return id.region != null or id.serial.slice().len > 0;
}

/// Installs a disc whose bytes this module now owns, and releases the last
/// one's, along with any executable it ran instead. `d` already carries
/// `new_sbi` and `new_patch`: the drive copies the `Disc` by value.
pub fn replaceDisc(d: Disc, bytes: []u8, new_decoder: ps1.disc_image.Decoder, new_sbi: []u8, new_patch: ps1.ppf.Overlay) void {
    if (exe) |*e| e.deinit();
    exe = null;
    bus.exe_boot = null;
    bus.cdrom.setDisc(d);
    keepDisc(d, bytes, new_decoder, new_sbi, new_patch);
    installBios(bus);
}

/// `replaceDisc` through the tray: the shell opens, the disc goes in and it
/// closes an emulated second later, leaving the status bit that tells the
/// game to re-read the TOC. The caller has checked no executable runs.
pub fn swapDisc(d: Disc, bytes: []u8, new_decoder: ps1.disc_image.Decoder, new_sbi: []u8, new_patch: ps1.ppf.Overlay) void {
    bus.cdrom.swapDisc(d, ps1.cdrom.shell_open_cycles);
    keepDisc(d, bytes, new_decoder, new_sbi, new_patch);
}

/// Boots `program` in place of a disc: a cold machine with no disc, which
/// jumps into it once the kernel is initialised. A refusal leaves the
/// running machine, its disc and its program as they were.
pub fn bootExe(program: Exe) error{OutOfMemory}!void {
    var old_exe = exe;
    const old_disc = disc;
    exe = program;
    disc = null;
    const dirty = snapshotCards();
    const m = build() catch |err| {
        exe = old_exe;
        disc = old_disc;
        return err;
    };
    adopt(m, dirty);
    if (old_exe) |*e| e.deinit();
    releaseDisc();
    disc_bytes = &.{};
    sbi = &.{};
    patch = .{};
    decoder = .none;
}

fn keepDisc(d: Disc, bytes: []u8, new_decoder: ps1.disc_image.Decoder, new_sbi: []u8, new_patch: ps1.ppf.Overlay) void {
    releaseDisc();
    disc = d;
    disc_bytes = bytes;
    decoder = new_decoder;
    sbi = new_sbi;
    patch = new_patch;
}

/// Frees what the disc in the drive reads from. The drive must already hold
/// another disc, or none.
fn releaseDisc() void {
    decoder.close();
    allocator.free(disc_bytes);
    allocator.free(sbi);
    patch.deinit(allocator);
}
