//! What the player keeps: the memory cards and whole-machine savestates.

const ps1 = @import("ps1_core");
const machine = @import("machine.zig");
const codes = @import("codes.zig");

const Sio = ps1.sio.Sio;

fn slotIndex(slot: i32) ?usize {
    if (slot < 0 or slot >= Sio.memcard_slots) return null;
    return @intCast(slot);
}

/// Installs a card image. COPIED: a reset puts the card back from here.
export fn loadMemcard(slot: i32, ptr: [*]const u8, len: usize) i32 {
    const i = slotIndex(slot) orelse return codes.bad_slot;
    if (len != Sio.memcard_bytes) return codes.bad_memcard_size;
    @memcpy(machine.memcard[i][0..], ptr[0..Sio.memcard_bytes]);
    machine.bus.sio.setMemoryCardData(i, &machine.memcard[i]);
    return codes.ok;
}

/// A DRAIN: 1 having copied the card into `dst` and cleared its dirty flag,
/// 0 having touched nothing. One call rather than a query and a copy, so a
/// block written between the two cannot be reported and then dropped.
export fn takeMemcard(slot: i32, dst: [*]u8) i32 {
    const i = slotIndex(slot) orelse return codes.bad_slot;
    if (!machine.bus.sio.isMemoryCardDirty(i)) return 0;
    @memcpy(dst[0..Sio.memcard_bytes], machine.bus.sio.getMemoryCardData(i));
    machine.bus.sio.clearMemoryCardDirty(i);
    return 1;
}

/// The exact size `saveState` will write for the machine as it is now.
export fn saveStateSize() usize {
    return ps1.savestate.save(&machine.cpu, null) catch 0;
}

/// Returns the length written, or a negative code.
export fn saveState(dst: [*]u8, cap: usize) i32 {
    const n = ps1.savestate.save(&machine.cpu, dst[0..cap]) catch |err| return codes.ofState(err);
    return @intCast(n);
}

/// All-or-nothing: see `machine.loadState`. The caller frees `ptr`.
export fn loadState(ptr: [*]const u8, len: usize) i32 {
    machine.loadState(ptr[0..len]) catch |err| return codes.ofState(err);
    return codes.ok;
}
