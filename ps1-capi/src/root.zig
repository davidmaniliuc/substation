//! The C ABI for ps1-core.
//!
//! This is a frontend, not part of the core: the core stays free of host
//! assumptions and `include/ps1.h` stays a reviewable artifact that a rename
//! cannot silently break. Nothing here may trap across the boundary — every
//! failure is a negative return code, and `panic` aborts rather than unwinding
//! into Swift, where there is no unwinder to catch it.

const std = @import("std");
const ps1 = @import("ps1_core");

const Bus = ps1.memory.Bus;
const Cpu = ps1.cpu.Cpu;
const Disc = ps1.disc.Disc;

const allocator = std.heap.smp_allocator;

pub const PS1_OK: i32 = 0;
pub const PS1_ERR_BAD_BIOS_SIZE: i32 = -1;
pub const PS1_ERR_BAD_CUE: i32 = -2;
pub const PS1_ERR_MULTI_FILE_CUE: i32 = -3;
pub const PS1_ERR_OOM: i32 = -4;
pub const PS1_ERR_BAD_SBI: i32 = -5;
pub const PS1_ERR_BAD_MEMCARD_SIZE: i32 = -6;
pub const PS1_ERR_BAD_SLOT: i32 = -7;
pub const PS1_ERR_STATE_BAD_MAGIC: i32 = -8;
pub const PS1_ERR_STATE_VERSION: i32 = -9;
pub const PS1_ERR_STATE_BIOS: i32 = -10;
pub const PS1_ERR_STATE_DISC: i32 = -11;
pub const PS1_ERR_STATE_CORRUPT: i32 = -12;
pub const PS1_ERR_STATE_NO_SPACE: i32 = -13;
pub const PS1_ERR_ENGINE_UNAVAILABLE: i32 = -14;
pub const PS1_ERR_BAD_CHD: i32 = -15;

const Sio = ps1.sio.Sio;
const Engine = ps1.recompiler.Engine;

/// ps1-wasm's numbering, which ps1.h's PS1_ENGINE_* constants spell out.
fn engineFromC(engine: c_int) ?Engine {
    return switch (engine) {
        0 => .interpreter,
        1 => .cached,
        2 => .jit,
        else => null,
    };
}

/// The magic every `.sbi` opens with. Checked here rather than left to
/// `Disc.setSbi`, which ignores a file that lacks it: at this boundary a
/// silently-dropped sidecar is a black screen with nothing to say why.
const sbi_magic = "SBI\x00";

const bios_bytes = 512 * 1024;

pub const Handle = struct {
    bus: *Bus,
    cpu: Cpu,
    /// Retained so `ps1_reset` can re-copy it: `Bus.init` memsets the struct,
    /// which clears `bus.bios` along with everything else.
    bios: [bios_bytes]u8 = @splat(0),
    bios_loaded: bool = false,
    /// Skip the BIOS shell on a disc boot (`ps1_set_fast_boot`). A host
    /// setting like `engine`: it outlives every `Bus` this file builds.
    fast_boot: bool = false,
    /// Borrowed, never owned — `Disc` holds a slice into the caller's bytes.
    disc: ?Disc = null,
    /// Owned copy of the disc's `.sbi`, which `disc.sbi` slices into. Copied
    /// rather than borrowed because it is a few hundred bytes, and because a
    /// sidecar that outlived the disc it shipped with would flag sectors of
    /// the next one at random. Empty for a disc with no sidecar.
    sbi: []u8 = &.{},
    /// The open reader when the disc is a CHD, owned. `disc.source` points at
    /// it, so it is closed only once a new disc has replaced that one.
    chd: ?*ps1.chd.Reader = null,
    /// Retained for the same reason `bios` is: `Bus.init` memsets the struct,
    /// and a front-panel reset does not wipe a memory card.
    memcard: [Sio.memcard_slots][Sio.memcard_bytes]u8 =
        @splat(@splat(0)),
    /// The CPU engine the host chose. A host setting, like the PGXP flags:
    /// a block cache lives on `Bus`, and every `Bus` this file builds comes
    /// up on the interpreter, so each rebuild puts this back.
    engine: Engine = .interpreter,
    /// The `Io` the raster worker sleeps and wakes through. This is a
    /// library with no `main` to hand one down, so it keeps its own, in the
    /// single-threaded form: that installs no signal handlers in the host
    /// app, and its futex is the OS futex either way.
    io_impl: std.Io.Threaded = .init_single_threaded,
};

fn buildMachine(h: *Handle) void {
    h.cpu = Cpu.init(h.bus);
    installHost(h, h.bus);
    installEngine(h, &h.cpu);
    installWorker(h, h.bus);
}

/// Puts the host's engine on a machine just built on a fresh `Bus`. A
/// failure (out of memory, or MAP_JIT refused) leaves that machine on the
/// interpreter, which `ps1_get_cpu_engine` then reports: it reads the
/// machine, not this field.
fn installEngine(h: *const Handle, cpu: *Cpu) void {
    ps1.recompiler.setEngine(cpu, allocator, h.engine) catch {};
}

/// The raster worker is a host choice like the engine: every `Bus` comes up
/// without one, so each one this file builds gets it here. A failure leaves
/// the machine rasterizing inline, which draws the same pixels.
fn installWorker(h: *Handle, bus: *Bus) void {
    if (comptime !ps1.gpu.raster_worker_available) return;
    bus.gpu.attachRasterWorker(allocator, h.io_impl.io(), .thread) catch {};
}

/// Puts the host's BIOS in a bus's ROM, patched for fast boot when the host
/// asked for it AND a PlayStation disc is in. Anything else boots the shell:
/// with no disc it is all there is, and for an audio CD it is the CD player.
fn installBios(h: *const Handle, bus: *Bus) void {
    if (!h.bios_loaded) return;
    ps1.bios.install(bus, &h.bios, h.fast_boot and isPlayStationDisc(h.disc));
}

/// The licence string the BIOS checks, or a SYSTEM.CNF serial: what
/// DuckStation means by a disc that is not "NonPS1".
fn isPlayStationDisc(disc: ?Disc) bool {
    const d = disc orelse return false;
    const id = ps1.discid.identify(d);
    return id.region != null or id.serial.slice().len > 0;
}

/// What the HOST owns and a rebuilt `Bus` must get back: the recorder's arm,
/// the BIOS image, the disc and the cards. Shared by a reset and by a state
/// load, which both build a fresh `Bus`.
fn installHost(h: *Handle, bus: *Bus) void {
    // Armed HERE rather than in ps1_create: ps1_reset rebuilds Bus through
    // this same function, and Bus.init memsets the struct, so a reset would
    // otherwise leave the recorder disarmed and the stream permanently empty
    // with nothing to say why.
    if (comptime ps1.gpu.Sink.kind == .dual) bus.gpu.sink.rec.arm();
    if (h.disc) |d| bus.cdrom.setDisc(d);
    installBios(h, bus);
    // Unconditional, with no `loaded` flag: a handle that has never been given
    // a card holds zeros, which is exactly what `Bus.init` produces anyway.
    //
    // `ps1_reset` does NOT need to suppress the "fresh"/directory-unread FLAG
    // bit `setMemoryCardData` ORs in below: `memory.zig`'s `Bus.init` runs
    // `bus.sio = Sio.init()` right after the `@memset(0)` it does for
    // `ps1_reset`'s rebuild, and `Sio.init()`'s default already sets
    // `memcard_flag_fresh | memcard_flag_unknown` — so by the time this loop
    // runs, the bit is already set and the OR here is a no-op, not a bug to
    // special-case around. It is also the CORRECT post-reset state on its own
    // terms: a front-panel reset power-cycles the card on real hardware,
    // which is exactly "directory unread".
    for (0..Sio.memcard_slots) |i| bus.sio.setMemoryCardData(i, &h.memcard[i]);
}

pub export fn ps1_create() ?*Handle {
    const h = allocator.create(Handle) catch return null;
    h.* = .{
        .bus = Bus.init(allocator) catch {
            allocator.destroy(h);
            return null;
        },
        .cpu = undefined,
    };
    buildMachine(h);
    return h;
}

pub export fn ps1_destroy(handle: ?*Handle) void {
    const h = handle orelse return;
    h.bus.deinit(allocator);
    if (h.chd) |r| r.close();
    allocator.free(h.sbi);
    allocator.destroy(h);
}

/// The renderer settings that live on `Bus`. They are the player's choice, not
/// machine state, so every rebuild of `Bus` carries them across.
const HostSettings = struct {
    on: bool,
    cpu: bool,
    culling: bool,
    tolerance: f32,
    cache: bool,
    texture: bool,
    color: bool,
    depth: bool,
    transparent_depth: bool,
    disable_2d: bool,
    preserve_projection: bool,

    fn capture(bus: *const Bus) HostSettings {
        return .{
            .on = bus.pgxp_enabled,
            .cpu = bus.pgxp_cpu,
            .culling = bus.pgxp_culling,
            .tolerance = bus.pgxp_tolerance,
            .cache = bus.pgxp_vertex_cache != null,
            // Carried because `Bus.init` restores `pgxp_texture_correction` to
            // its default of `true`, which would silently undo a player's OFF
            // across a reset or a state load.
            .texture = bus.pgxp_texture_correction,
            .color = bus.pgxp_color_correction,
            .depth = bus.pgxp_depth_buffer,
            .transparent_depth = bus.pgxp_transparent_depth,
            .disable_2d = bus.pgxp_disable_2d,
            .preserve_projection = bus.pgxp_preserve_projection,
        };
    }

    fn apply(s: HostSettings, bus: *Bus) void {
        bus.setPgxpCpu(s.cpu);
        bus.pgxp_culling = s.culling;
        bus.setPgxpTolerance(s.tolerance);
        bus.setPgxpVertexCache(allocator, s.cache) catch {};
        bus.pgxp_texture_correction = s.texture;
        bus.pgxp_color_correction = s.color;
        bus.pgxp_depth_buffer = s.depth;
        bus.pgxp_transparent_depth = s.transparent_depth;
        bus.pgxp_disable_2d = s.disable_2d;
        bus.pgxp_preserve_projection = s.preserve_projection;
        // Last, because it is what mirrors the rest onto the GPU.
        bus.setPgxp(s.on);
    }
};

/// Copies the LIVE card images into the handle and returns their dirty
/// flags, so a rebuilt `Bus` gets the player's latest save rather than the
/// last one the frontend loaded. (Reasoning: see `ps1_reset`.)
fn snapshotCards(h: *Handle) [Sio.memcard_slots]bool {
    var dirty: [Sio.memcard_slots]bool = undefined;
    for (0..Sio.memcard_slots) |i| {
        @memcpy(h.memcard[i][0..], h.bus.sio.getMemoryCardData(i));
        dirty[i] = h.bus.sio.isMemoryCardDirty(i);
    }
    return dirty;
}

fn restoreDirty(bus: *Bus, dirty: [Sio.memcard_slots]bool) void {
    for (0..Sio.memcard_slots) |i| {
        if (dirty[i]) bus.sio.memcard_dirty[i] = true;
    }
}

/// The front-panel reset button: rebuilds the machine but keeps the BIOS and
/// the disc. Running with no disc is valid — it boots to the BIOS shell.
pub export fn ps1_reset(h: *Handle) void {
    // Snapshot the LIVE images, not the ones last loaded: a save the frontend
    // has not taken yet is still the player's save. The dirty flags have to
    // travel with them: `buildMachine` reinstalls the images through
    // `setMemoryCardData`, which by design clears dirty and marks the card
    // "fresh" — correct for an image arriving from the host, but these bytes
    // came from the machine itself. A write the frontend has not yet drained
    // with `ps1_take_memcard` must still look dirty after a reset, or a
    // player who resets inside the frontend's persistence debounce loses the
    // save: the bytes live on in the emulator, `ps1_take_memcard` reports a
    // clean card, and nothing is ever written to disk.
    const dirty = snapshotCards(h);
    // The renderer settings live on `Bus` too, and the rebuild below puts
    // every one of them back at its default. They are the player's choice, not
    // machine state, so they are carried across for the same reason the BIOS
    // image and the cards are.
    const settings = HostSettings.capture(h.bus);

    h.bus.deinit(allocator);
    h.bus = Bus.init(allocator) catch {
        // Re-allocating 2MB+ immediately after freeing it should not fail; if
        // it does there is no valid state to return to and no way to report it.
        @panic("ps1_reset: out of memory rebuilding Bus");
    };
    buildMachine(h);
    settings.apply(h.bus);
    // Re-raise dirty AFTER buildMachine, which is the call that just cleared
    // it. A card that was clean before the reset must stay clean — flagging
    // it regardless would cost the frontend a pointless 128 KB write on every
    // single reset, not just the ones that matter.
    restoreDirty(h.bus, dirty);
}

fn stateCode(err: ps1.savestate.Error) i32 {
    return switch (err) {
        error.StateBadMagic => PS1_ERR_STATE_BAD_MAGIC,
        error.StateVersion => PS1_ERR_STATE_VERSION,
        error.StateBios => PS1_ERR_STATE_BIOS,
        error.StateDisc => PS1_ERR_STATE_DISC,
        error.StateCorrupt => PS1_ERR_STATE_CORRUPT,
        error.NoSpace => PS1_ERR_STATE_NO_SPACE,
    };
}

/// The exact size `ps1_save_state` will write for the machine as it is now.
pub export fn ps1_save_state_size(h: *Handle) usize {
    h.cpu.bus.gpu.syncRaster();
    return ps1.savestate.save(&h.cpu, null) catch 0;
}

pub export fn ps1_save_state(h: *Handle, dst: [*]u8, cap: usize, out_len: *usize) i32 {
    h.cpu.bus.gpu.syncRaster();
    out_len.* = ps1.savestate.save(&h.cpu, dst[0..cap]) catch |err| return stateCode(err);
    return PS1_OK;
}

/// All-or-nothing: the state is decoded into a scratch `Bus` carrying this
/// handle's BIOS, disc and cards, and swapped in only once every section has
/// parsed. A refusal leaves the running machine exactly as it was. The
/// player's settings and an undrained card write are carried across, exactly
/// as `ps1_reset` carries them.
pub export fn ps1_load_state(h: *Handle, src: [*]const u8, len: usize) i32 {
    const fresh = Bus.init(allocator) catch return PS1_ERR_OOM;
    const dirty = snapshotCards(h);
    installHost(h, fresh);
    var cpu = Cpu.init(fresh);
    // BEFORE the load: it restores the I-cache lines as the saving machine
    // held them, and selecting an engine afterwards would flush them.
    installEngine(h, &cpu);
    ps1.savestate.load(&cpu, src[0..len]) catch |err| {
        fresh.deinit(allocator);
        return stateCode(err);
    };
    const settings = HostSettings.capture(h.bus);
    h.bus.deinit(allocator);
    h.bus = fresh;
    h.cpu = cpu;
    // After the swap, so the worker's env is the restored one. The old
    // machine's worker was drained and stopped by its `deinit` above; a
    // refused state returned before either, leaving it running.
    installWorker(h, h.bus);
    settings.apply(h.bus);
    restoreDirty(h.bus, dirty);
    return PS1_OK;
}

pub const Ps1StateInfo = extern struct {
    serial: [16]u8,
    bios_sha256: [32]u8,
};

pub export fn ps1_peek_state(src: [*]const u8, len: usize, out: *Ps1StateInfo) i32 {
    const id = ps1.savestate.peek(src[0..len]) catch |err| return stateCode(err);
    out.* = .{ .serial = id.serial, .bios_sha256 = id.bios_sha256 };
    return PS1_OK;
}

pub export fn ps1_load_bios(h: *Handle, bytes: [*]const u8, len: usize) i32 {
    if (len != bios_bytes) return PS1_ERR_BAD_BIOS_SIZE;
    @memcpy(h.bios[0..], bytes[0..bios_bytes]);
    h.bios_loaded = true;
    installBios(h, h.bus);
    return PS1_OK;
}

/// Attaches a disc. The `.bin` bytes are BORROWED, not copied — `Disc` holds a
/// slice into them, so they must outlive the handle or the next call here.
/// Pass `cue_len == 0` for the raw-`.bin` fallback, which is a single data
/// track at LBA 0 and cannot represent audio tracks.
///
/// A cue that splits its tracks across several FILEs wants `bin` to be those
/// images concatenated in cue order, and the cue to carry a `REM FILESIZE`
/// line before each FILE — that is how the seams survive the concatenation.
///
/// `sbi` is the disc's LibCrypt sidecar, and `sbi_len == 0` says it has none —
/// true of every unprotected disc, so that is not an error. It is copied into
/// the handle, which is what lets a caller drop the file after this returns
/// and what stops one disc's sidecar surviving into the next.
/// Validates the three buffers and, on success, returns a `Disc` with the
/// handle's sidecar already replaced by a copy of `sbi`.
///
/// Every rejection happens while nothing has been allocated and nothing on the
/// handle has been touched, so a caller that gets a negative code still has the
/// machine it had before. That matters more for `ps1_swap_disc` than for
/// `ps1_load_disc`: the swap is applied to a RUNNING machine.
const Prepared = struct { disc: Disc, old_chd: ?*ps1.chd.Reader };

fn prepareDisc(
    h: *Handle,
    bin: [*]const u8,
    bin_len: usize,
    cue: ?[*]const u8,
    cue_len: usize,
    sbi: ?[*]const u8,
    sbi_len: usize,
) union(enum) { ok: Prepared, err: i32 } {
    if (bin_len < ps1.constants.sector_bytes) return .{ .err = PS1_ERR_BAD_CUE };

    // Checked before the copy below, so every rejection happens while nothing
    // has been allocated and nothing on the handle has been touched. This
    // family returns a code rather than an error, so `errdefer` would not fire
    // and each early return would have to free by hand.
    if (sbi_len > 0) {
        const bytes = (sbi orelse return .{ .err = PS1_ERR_BAD_SBI })[0..sbi_len];
        if (!std.mem.startsWith(u8, bytes, sbi_magic)) return .{ .err = PS1_ERR_BAD_SBI };
    }

    const data = bin[0..bin_len];
    var d: Disc = undefined;
    var reader: ?*ps1.chd.Reader = null;

    if (ps1.chd.isChd(data)) {
        if (cue_len > 0) return .{ .err = PS1_ERR_BAD_CHD };
        reader = ps1.chd.Reader.open(allocator, data) catch |err|
            return .{ .err = if (err == error.OutOfMemory) PS1_ERR_OOM else PS1_ERR_BAD_CHD };
        d = Disc.initFromChd(reader.?);
    } else if (cue_len > 0) {
        const cue_ptr = cue orelse return .{ .err = PS1_ERR_BAD_CUE };
        const cue_text = cue_ptr[0..cue_len];

        const files = ps1.disc.countCueFiles(cue_text);
        if (files == 0) return .{ .err = PS1_ERR_BAD_CUE };
        // A multi-FILE cue is fine as long as the caller has concatenated the
        // images and said where the seams are; without the `REM FILESIZE`
        // lines that carry them, `initFromCue` stacks every FILE at the same
        // base LBA rather than failing, so it has to be caught here.
        if (files > 1 and !ps1.disc.cueFilesAreLaidOut(cue_text)) return .{ .err = PS1_ERR_MULTI_FILE_CUE };

        // `initFromCue` silently falls back to a single data track on a cue it
        // cannot parse, so a cue with no TRACK line has to be caught here.
        if (std.mem.indexOf(u8, cue_text, "TRACK ") == null) return .{ .err = PS1_ERR_BAD_CUE };

        d = Disc.initFromCue(cue_text, data);
    } else {
        d = Disc.init(data);
    }

    // Past this point nothing can fail but the copy itself, so the handle's
    // old sidecar is safe to drop.
    const new_sbi: []u8 = if (sbi_len > 0)
        allocator.dupe(u8, sbi.?[0..sbi_len]) catch {
            if (reader) |r| r.close();
            return .{ .err = PS1_ERR_OOM };
        }
    else
        &.{};
    allocator.free(h.sbi);
    h.sbi = new_sbi;
    // `setDisc`/`swapDisc` copy the Disc by value, so the sidecar has to be
    // attached to `d` before it is handed over rather than to `h.disc` after.
    d.setSbi(new_sbi);
    // The previous reader is returned, not closed: the machine still reads
    // from it until the caller has installed `d`.
    const old = h.chd;
    h.chd = reader;
    return .{ .ok = .{ .disc = d, .old_chd = old } };
}

pub export fn ps1_load_disc(
    h: *Handle,
    bin: [*]const u8,
    bin_len: usize,
    cue: ?[*]const u8,
    cue_len: usize,
    sbi: ?[*]const u8,
    sbi_len: usize,
) i32 {
    const p = switch (prepareDisc(h, bin, bin_len, cue, cue_len, sbi, sbi_len)) {
        .err => |code| return code,
        .ok => |p| p,
    };
    h.disc = p.disc;
    h.cpu.bus.cdrom.setDisc(p.disc);
    if (p.old_chd) |r| r.close();
    installBios(h, h.bus);
    return PS1_OK;
}

/// The region a disc names, as `Ps1Region` in the header. Zero is unknown,
/// which a caller must treat as "fall back to your own rule" rather than as
/// any particular console.
const region_unknown: u8 = 0;

pub const Ps1DiscId = extern struct {
    region: u8,
    /// "SLUS-00530", NUL-terminated. Empty when the disc names no serial.
    serial: [16]u8,
    /// The ISO volume identifier, NUL-terminated. Often empty, and never a
    /// title — it is `SLUS_00067` on Castlevania and absent on Silent Hill.
    volume_id: [33]u8,
};

/// The catalog metadata for one known multi-disc serial. Kept separate from
/// `Ps1DiscId` so the long-lived caller-owned identification struct is never
/// expanded in place.
pub const Ps1DiscSet = extern struct {
    game_title: [256]u8,
    disc_number: u8,
};

/// Identifies a disc without building a machine: no handle, no BIOS, no
/// allocation (except a CHD's map). A library scan calls this once per disc.
///
/// `bin` must be the WHOLE image. SYSTEM.CNF is reached through the ISO
/// directory, and its extent is 497 MB into Croc and 607 MB into Resident
/// Evil, so a caller that passes a head window silently loses the serial and
/// gets the licence region alone. Mapping the file rather than reading it is
/// what makes that cheap.
pub export fn ps1_identify_disc(bin: [*]const u8, bin_len: usize, out: *Ps1DiscId) i32 {
    out.* = .{
        .region = region_unknown,
        .serial = @splat(0),
        .volume_id = @splat(0),
    };
    if (bin_len < ps1.constants.sector_bytes) return PS1_ERR_BAD_CUE;

    const data = bin[0..bin_len];
    // A CHD needs its map decoded to be read at all; that is the one
    // allocation here, freed before returning. Each call opens its own
    // reader, so concurrent library scans never share one.
    const reader: ?*ps1.chd.Reader = if (ps1.chd.isChd(data))
        ps1.chd.Reader.open(allocator, data) catch return PS1_ERR_BAD_CHD
    else
        null;
    defer if (reader) |r| r.close();
    const id = ps1.discid.identify(if (reader) |r| Disc.initFromChd(r) else Disc.init(data));

    if (id.region) |region| out.region = switch (region) {
        .america => 1,
        .europe => 2,
        .japan => 3,
    };
    copyString(&out.serial, id.serial.slice());
    copyString(&out.volume_id, id.volumeId());
    return PS1_OK;
}

/// Read whenever the BIOS is installed (`ps1_reset`, `ps1_load_disc`,
/// `ps1_load_bios`, `ps1_load_state`), so it changes nothing by itself.
/// `ps1_load_disc` re-installs into a machine already going as well, which
/// is harmless: the patched routine runs once, at boot, and never again.
pub export fn ps1_set_fast_boot(h: *Handle, enabled: u8) void {
    h.fast_boot = enabled != 0;
}

pub const Ps1BiosId = extern struct {
    region: u8,
    description: [64]u8,
    version: [8]u8,
    models: [96]u8,
};

/// Identifies a BIOS image by content, without a handle. 1 and `out` filled
/// for an image in the core's table; 0 and `out` zeroed for any other.
pub export fn ps1_identify_bios(bytes: [*]const u8, len: usize, out: *Ps1BiosId) u8 {
    out.* = .{ .region = region_unknown, .description = @splat(0), .version = @splat(0), .models = @splat(0) };
    if (len != ps1.bios.image_bytes) return 0;
    const row = ps1.bios.identify(bytes[0..ps1.bios.image_bytes]) orelse return 0;
    out.region = switch (row.region) {
        .america => 1,
        .europe => 2,
        .japan => 3,
    };
    copyString(&out.description, row.description);
    copyString(&out.version, row.version);
    joinModels(&out.models, row.models);
    return 1;
}

/// "SCPH-7002,SCPH-7502,SCPH-9002". The last byte is never written, so the
/// zeroed field stays NUL-terminated even if a future row outgrows it.
fn joinModels(dst: []u8, models: []const []const u8) void {
    var w: std.Io.Writer = .fixed(dst[0 .. dst.len - 1]);
    for (models, 0..) |model, i| {
        if (i > 0) w.writeByte(',') catch return;
        w.writeAll(model) catch return;
    }
}

/// Looks up metadata only after a frontend has safely identified a disc. A
/// separate function prevents any ABI change to the caller-owned `Ps1DiscId`.
pub export fn ps1_lookup_disc_set(serial: [*:0]const u8, out: *Ps1DiscSet) u8 {
    out.* = .{ .game_title = @splat(0), .disc_number = 0 };
    const entry = ps1.discdb.lookup(std.mem.span(serial)) orelse return 0;
    copyString(&out.game_title, entry.game_title);
    out.disc_number = entry.disc_number;
    return 1;
}

/// One game's PGXP overrides. A switch is -1 where the player's setting
/// stands, else 0 or 1; `tolerance` counts only under `has_tolerance`.
pub const Ps1PgxpPreset = extern struct {
    tolerance: f32,
    has_tolerance: u8,
    enabled: i8,
    cpu: i8,
    culling: i8,
    vertex_cache: i8,
    texture_correction: i8,
    color_correction: i8,
    depth_buffer: i8,
    disable_2d: i8,
    preserve_projection: i8,
};

/// Looks a serial up in the preset table. Applies nothing: the frontend
/// re-applies every PGXP setting every frame, so it folds these in itself.
pub export fn ps1_lookup_pgxp_preset(serial: [*:0]const u8, out: *Ps1PgxpPreset) u8 {
    out.* = .{
        .tolerance = 0,
        .has_tolerance = 0,
        .enabled = -1,
        .cpu = -1,
        .culling = -1,
        .vertex_cache = -1,
        .texture_correction = -1,
        .color_correction = -1,
        .depth_buffer = -1,
        .disable_2d = -1,
        .preserve_projection = -1,
    };
    const p = ps1.pgxp_presets.lookup(std.mem.span(serial)) orelse return 0;
    out.enabled = override(p.enabled);
    out.cpu = override(p.cpu);
    out.culling = override(p.culling);
    out.vertex_cache = override(p.vertex_cache);
    out.texture_correction = override(p.texture_correction);
    out.color_correction = override(p.color_correction);
    out.depth_buffer = override(p.depth_buffer);
    out.disable_2d = override(p.disable_2d);
    out.preserve_projection = override(p.preserve_projection);
    if (p.tolerance) |t| {
        out.tolerance = t;
        out.has_tolerance = 1;
    }
    return 1;
}

fn override(value: ?bool) i8 {
    const v = value orelse return -1;
    return @intFromBool(v);
}

/// Copies `text` into a NUL-terminated C buffer, truncating rather than
/// overrunning. The destination is zeroed by the caller, so the terminator is
/// whatever is left.
fn copyString(dst: []u8, text: []const u8) void {
    const n = @min(text.len, dst.len - 1);
    @memcpy(dst[0..n], text[0..n]);
}

/// The tray version: the shell opens, the disc goes in, and it closes an
/// emulated second later, leaving the sticky status bit that tells the game to
/// re-read the TOC. `ps1_load_disc` on a running machine is invisible to it.
pub export fn ps1_swap_disc(
    h: *Handle,
    bin: [*]const u8,
    bin_len: usize,
    cue: ?[*]const u8,
    cue_len: usize,
    sbi: ?[*]const u8,
    sbi_len: usize,
) i32 {
    const p = switch (prepareDisc(h, bin, bin_len, cue, cue_len, sbi, sbi_len)) {
        .err => |code| return code,
        .ok => |p| p,
    };
    h.disc = p.disc;
    h.cpu.bus.cdrom.swapDisc(p.disc, ps1.cdrom.shell_open_cycles);
    if (p.old_chd) |r| r.close();
    return PS1_OK;
}

/// Mirrors `Ps1Display` in ps1.h. `extern struct` pins the C layout.
pub const Ps1Display = extern struct {
    vram_x: u32,
    vram_y: u32,
    width: u32,
    height: u32,
    depth24: u8,
    enabled: u8,
    pal: u8,
    _pad: u8,
};

/// Runs vblank-to-vblank, the same shape as the wasm frontend's `stepFrame`:
/// spin out of any vblank we are already in, then run until the next one.
pub export fn ps1_run_frame(h: *Handle) void {
    if (!h.bios_loaded) return;
    // `runFor`, not `run`: under the JIT, `run` is one block and never
    // follows a link. The vblank flag is a GPU deadline, so `runFor` stops
    // on it exactly as stepping would; on the interpreter it is one step.
    const budget = std.math.maxInt(u32);
    while (h.cpu.bus.gpu.is_vblank) _ = h.cpu.runFor(budget);
    while (!h.cpu.bus.gpu.is_vblank) _ = h.cpu.runFor(budget);
}

/// Takes `sio.zig`'s own convention: 0 means PRESSED, 1 means released,
/// 0xFFFF is idle. The ABI deliberately does not re-invent a button enum.
pub export fn ps1_set_buttons(h: *Handle, mask: u16) void {
    h.cpu.bus.sio.setButtons(mask);
}

/// The sticks, as the pad reports them: 0x80 centre, Y grows DOWN. Applied
/// to the next packet the game reads.
pub export fn ps1_set_analog(h: *Handle, lx: u8, ly: u8, rx: u8, ry: u8) void {
    h.cpu.bus.sio.pad.setSticks(lx, ly, rx, ry);
}

/// The pad's ANALOG button. Queued until the pad is next idle between
/// packets; the pad ignores it while the game holds the mode lock.
pub export fn ps1_press_analog_button(h: *Handle) void {
    h.cpu.bus.sio.pad.pressAnalogButton();
}

pub const Ps1PadStatus = extern struct {
    analog: u8,
    small: u8,
    large: u8,
};

/// The mode LED and both motors, for the host to show and to rumble with.
/// A reset rebuilds the pad, so it reads digital and still after one.
pub export fn ps1_get_pad_status(h: *Handle, out: *Ps1PadStatus) void {
    const p = &h.cpu.bus.sio.pad;
    out.* = .{ .analog = @intFromBool(p.analog), .small = p.motor_small, .large = p.motor_large };
}

/// Installs a memory card image. The bytes are COPIED — 128 KB is small enough
/// that a second lifetime obligation on the caller buys nothing, and the copy
/// is what lets `ps1_reset` put the card back afterwards.
pub export fn ps1_load_memcard(h: *Handle, slot: i32, bytes: [*]const u8, len: usize) i32 {
    if (slot < 0 or slot >= Sio.memcard_slots) return PS1_ERR_BAD_SLOT;
    if (len != Sio.memcard_bytes) return PS1_ERR_BAD_MEMCARD_SIZE;
    const i: usize = @intCast(slot);
    @memcpy(h.memcard[i][0..], bytes[0..Sio.memcard_bytes]);
    h.bus.sio.setMemoryCardData(i, &h.memcard[i]);
    return PS1_OK;
}

/// Takes the card image if the game has written it since the last call.
///
/// Returns 1 having copied PS1_MEMCARD_BYTES into `dst` and cleared the dirty
/// flag, or 0 having touched nothing. This is a DRAIN, and it is one call
/// rather than a dirty query followed by a copy so that a block committed
/// between the two cannot be reported and then dropped.
pub export fn ps1_take_memcard(h: *Handle, slot: i32, dst: [*]u8) i32 {
    if (slot < 0 or slot >= Sio.memcard_slots) return PS1_ERR_BAD_SLOT;
    const i: usize = @intCast(slot);
    if (!h.bus.sio.isMemoryCardDirty(i)) return 0;
    @memcpy(dst[0..Sio.memcard_bytes], h.bus.sio.getMemoryCardData(i));
    h.bus.sio.clearMemoryCardDirty(i);
    return 1;
}

comptime {
    // PS1_MEMCARD_BYTES and PS1_MEMCARD_SLOTS in ps1.h are hand-written
    // literals with nothing else tying them to sio.zig. Pin them here the
    // same way the GPU stream capacities are pinned below: a mismatch is
    // invisible to the Zig compiler and would only surface as a Swift-side
    // buffer overrun.
    if (Sio.memcard_bytes != 131_072)
        @compileError("PS1_MEMCARD_BYTES in ps1.h is out of step with sio.zig");
    if (Sio.memcard_slots != 2)
        @compileError("PS1_MEMCARD_SLOTS in ps1.h is out of step with sio.zig");
}

/// PGXP geometry correction. Safe at any time: the flag is read per GTE
/// operation and per store, and nothing caches it.
pub export fn ps1_set_pgxp(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxp(enabled != 0);
}

/// PGXP CPU mode: propagation through ordinary CPU arithmetic. Gated on
/// `ps1_set_pgxp`, so this alone does nothing.
pub export fn ps1_set_pgxp_cpu(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpCpu(enabled != 0);
}

/// PGXP culling correction: float NCLIP. On by default, gated on
/// `ps1_set_pgxp`.
pub export fn ps1_set_pgxp_culling(h: *Handle, enabled: c_int) void {
    h.cpu.bus.pgxp_culling = enabled != 0;
}

/// PGXP vertex cache. Allocates 83 MB while on, so a frontend that never turns
/// it on never pays for it. Gated on `ps1_set_pgxp`.
pub export fn ps1_set_pgxp_vertex_cache(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpVertexCache(allocator, enabled != 0) catch {
        // 83 MB is a real allocation and a real failure. The setting simply
        // stays off: the feature it drives is an optional refinement, and
        // there is no way to report this through a void setter.
        return;
    };
}

/// How far a PGXP candidate may sit from the integer vertex it claims to be,
/// in pixels. Negative disables the check, which is the default.
pub export fn ps1_set_pgxp_tolerance(h: *Handle, tolerance: f32) void {
    h.cpu.bus.setPgxpTolerance(tolerance);
}

/// Perspective-correct texturing. On by default, gated on `ps1_set_pgxp`. The
/// bus method (rather than a raw field write, unlike `ps1_set_pgxp_culling`)
/// also re-derives the `Gp0Engine` mirror the sink reads per primitive.
pub export fn ps1_set_pgxp_texture_correction(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpTextureCorrection(enabled != 0);
}

/// Perspective-correct vertex colour. OFF by default, gated on `ps1_set_pgxp`.
/// The bus method, not a raw field write, because it re-derives the
/// `Gp0Engine` mirror that decides the record's flag bits.
pub export fn ps1_set_pgxp_color_correction(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpColorCorrection(enabled != 0);
}

/// The PGXP depth buffer. OFF by default, gated on `ps1_set_pgxp`. A change
/// resets the plane through the command stream, so Metal's resets with it.
pub export fn ps1_set_pgxp_depth_buffer(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpDepthBuffer(enabled != 0);
}

/// Transparent polygons test (never write) the depth buffer. OFF by default;
/// acts only while the depth buffer is on.
pub export fn ps1_set_pgxp_transparent_depth(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpTransparentDepth(enabled != 0);
}

/// A primitive whose positions resolved but which lacks depths is drawn at
/// integer positions. OFF by default, gated on `ps1_set_pgxp`.
pub export fn ps1_set_pgxp_disable_2d(h: *Handle, enabled: c_int) void {
    h.cpu.bus.setPgxpDisable2d(enabled != 0);
}

/// Project from the GTE's exact accumulator instead of its rounded
/// IR1/IR2/SZ3. OFF by default, gated on `ps1_set_pgxp`.
pub export fn ps1_set_pgxp_preserve_projection(h: *Handle, enabled: c_int) void {
    h.cpu.bus.pgxp_preserve_projection = enabled != 0;
}

/// Selects the CPU engine. Between `ps1_run_frame` calls, on the thread that
/// makes them, or on any thread before the first frame. Re-selecting the current engine keeps its compiled blocks. On
/// any error the current engine stays selected.
pub export fn ps1_set_cpu_engine(h: *Handle, engine: c_int) i32 {
    const e = engineFromC(engine) orelse return PS1_ERR_ENGINE_UNAVAILABLE;
    ps1.recompiler.setEngine(&h.cpu, allocator, e) catch |err| return switch (err) {
        error.OutOfMemory => PS1_ERR_OOM,
        error.EngineUnavailable => PS1_ERR_ENGINE_UNAVAILABLE,
    };
    h.engine = e;
    return PS1_OK;
}

/// The engine the machine is running on now.
pub export fn ps1_get_cpu_engine(h: *const Handle) c_int {
    return switch (ps1.recompiler.engineOf(h.bus)) {
        .interpreter => 0,
        .cached => 1,
        .jit => 2,
    };
}

/// 1 if this build has the engine. The JIT exists only on arm64 macOS; a
/// MAP_JIT refusal at run time still surfaces from `ps1_set_cpu_engine`.
pub export fn ps1_cpu_engine_available(engine: c_int) c_int {
    const e = engineFromC(engine) orelse return 0;
    return @intFromBool(e != .jit or ps1.recompiler.jit.available);
}

/// The software depth plane, 1024x512 u32 — what a Metal resync adopts beside
/// `ps1_copy_vram`, under the same frame.
pub export fn ps1_copy_depth(h: *const Handle, dst: [*]u32) void {
    h.cpu.bus.gpu.syncRaster();
    const src = h.cpu.bus.gpu.vram.depth;
    @memcpy(dst[0..src.len], src[0..]);
}

pub export fn ps1_copy_vram(h: *const Handle, dst: [*]u16) void {
    h.cpu.bus.gpu.syncRaster();
    const src = h.cpu.bus.gpu.vram.data;
    @memcpy(dst[0..src.len], src[0..]);
}

pub export fn ps1_get_display(h: *const Handle, out: *Ps1Display) void {
    const g = &h.cpu.bus.gpu;
    out.* = .{
        .vram_x = g.disp_env.vram_x_start,
        .vram_y = g.disp_env.vram_y_start,
        .width = g.getDisplayWidth(),
        .height = g.getDisplayHeight(),
        .depth24 = @intFromBool((g.disp_env.display_mode & (1 << 4)) != 0),
        .enabled = @intFromBool(!g.disp_env.display_disabled),
        .pal = @intFromBool(!g.is_ntsc),
        ._pad = 0,
    };
}

/// Drains the SPU's output ring into `dst`, returning the number of floats
/// written (interleaved stereo, 44100 Hz).
///
/// The ring's indices belong to the core, not the caller: the wasm frontend
/// exposes them raw and makes JavaScript do the modular arithmetic, which is a
/// wasm-shaped ABI and is not repeated here.
///
/// `max_floats` should be even; an odd value is truncated down so a stereo
/// pair is never split across two calls.
pub export fn ps1_read_audio(h: *Handle, dst: [*]f32, max_floats: usize) usize {
    const spu = &h.cpu.bus.spu;
    const len = spu.output_buffer.len;

    const available = (spu.write_idx + len - spu.read_idx) % len;
    var n = @min(available, max_floats);
    n -= n % 2;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        dst[i] = spu.output_buffer[(spu.read_idx + i) % len];
    }
    spu.read_idx = (spu.read_idx + n) % len;
    return n;
}

comptime {
    // These two are PS1_GPU_MAX_RECORDS and PS1_GPU_MAX_PAYLOAD_WORDS in
    // ps1.h, where the Swift side sizes its queue slots from them. A capacity
    // that drifts between the two silently truncates a frame, so pin it here
    // the same way command.zig pins the 120-byte stride.
    if (ps1.gpu.recorder.max_records != 65_536)
        @compileError("PS1_GPU_MAX_RECORDS in ps1.h is out of step with recorder.zig");
    if (ps1.gpu.recorder.max_payload_words != 524_288)
        @compileError("PS1_GPU_MAX_PAYLOAD_WORDS in ps1.h is out of step with recorder.zig");
}

/// Mirrors `Ps1GpuStream` in ps1.h. `extern struct` pins the C layout.
///
/// Both pointers are CORE-OWNED and alias the recorder's own storage: they are
/// valid only until the next `ps1_run_frame` on this handle.
pub const Ps1GpuStream = extern struct {
    records: ?[*]const ps1.gpu.command.Command,
    record_count: usize,
    payload: ?[*]const u32,
    payload_count: usize,
    /// 0 means the records are a PREFIX of the frame, not a shorter frame.
    complete: u8,
    _pad: [7]u8,
};

/// Drains one frame of recorded GP0 commands. See contract rule 4 in ps1.h.
///
/// This is a DRAIN: `takeFrame` resets the recorder's counters. Call it exactly
/// once per `ps1_run_frame`. Skipping it does not keep the frame — it stacks
/// the next one on top until the capacity overruns and `complete` goes to 0.
pub export fn ps1_take_frame_stream(h: *Handle, out: *Ps1GpuStream) void {
    if (comptime ps1.gpu.Sink.kind != .dual) {
        // A .software build records nothing. An empty COMPLETE stream is the
        // honest answer: there is no frame to discard, and reporting it
        // incomplete would trigger a resync every frame forever.
        out.* = .{
            .records = null,
            .record_count = 0,
            .payload = null,
            .payload_count = 0,
            .complete = 1,
            ._pad = @splat(0),
        };
    } else {
        const s = h.cpu.bus.gpu.sink.rec.takeFrame();
        out.* = .{
            .records = s.records.ptr,
            .record_count = s.records.len,
            .payload = s.payload.ptr,
            .payload_count = s.payload.len,
            .complete = @intFromBool(s.complete),
            ._pad = @splat(0),
        };
    }
}

/// Nothing may unwind into Swift — there is no unwinder there to catch it.
/// Log to stderr and abort, so a crash is a readable message rather than a
/// corrupted stack.
pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = first_trace_addr;
        std.debug.print("ps1-capi PANIC: {s}\n", .{msg});
        std.process.abort();
    }
}.panicFn);
