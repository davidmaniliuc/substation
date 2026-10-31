//! PARAM.SFO, the key/value table at the head of an eboot: just enough of it
//! to refuse what is not a bootable PS1 title and to read its name.
const std = @import("std");

const magic = "\x00PSF";
const header_bytes = 0x14;
const entry_bytes = 16;
const max_entries = 16384;
const type_text: u16 = 0x0204;
const type_u32: u16 = 0x0404;

pub const Info = struct {
    /// The `TITLE` value, borrowed from the SFO; empty when it has none.
    title: []const u8,
};

const Entry = struct { key: []const u8, kind: u16, value: []const u8 };

fn u16At(data: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, data[at..][0..2], .little);
}

fn u32At(data: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, data[at..][0..4], .little);
}

/// `data[at..][0..len]`, or null when it does not fit.
fn slice(data: []const u8, at: usize, len: usize) ?[]const u8 {
    if (at > data.len or len > data.len - at) return null;
    return data[at..][0..len];
}

fn entry(sfo: []const u8, index: usize) error{BadPbp}!Entry {
    const e = slice(sfo, header_bytes + index * entry_bytes, entry_bytes) orelse return error.BadPbp;
    const keys = u32At(sfo, 8);
    const values = u32At(sfo, 12);
    const kind = u16At(e, 2);
    if (kind != type_text and kind != type_u32) return error.BadPbp;
    // Summed in u64: a usize is 32 bits on wasm32 and an unchecked wrap there
    // would read from the wrong place instead of refusing.
    const key_at: u64 = @as(u64, keys) + u16At(e, 0);
    if (key_at >= sfo.len) return error.BadPbp;
    const key = std.mem.sliceTo(sfo[@intCast(key_at)..], 0);
    const value_at: u64 = @as(u64, values) + u32At(e, 12);
    if (value_at > sfo.len) return error.BadPbp;
    const value = slice(sfo, @intCast(value_at), u32At(e, 4)) orelse return error.BadPbp;
    if (kind == type_u32 and value.len < 4) return error.BadPbp;
    return .{ .key = key, .kind = kind, .value = value };
}

/// Reads `sfo`, refusing anything but a bootable title of category `ME`.
pub fn parse(sfo: []const u8) error{BadPbp}!Info {
    if (!std.mem.startsWith(u8, sfo, magic) or sfo.len < header_bytes) return error.BadPbp;
    const count = u32At(sfo, 0x10);
    if (count > max_entries) return error.BadPbp;
    var title: []const u8 = "";
    var bootable = false;
    var category = false;
    for (0..count) |i| {
        const e = try entry(sfo, i);
        if (std.mem.eql(u8, e.key, "TITLE") and e.kind == type_text) {
            title = std.mem.sliceTo(e.value, 0);
        } else if (std.mem.eql(u8, e.key, "BOOTABLE") and e.kind == type_u32) {
            bootable = u32At(e.value, 0) == 1;
        } else if (std.mem.eql(u8, e.key, "CATEGORY") and e.kind == type_text) {
            category = std.mem.eql(u8, std.mem.sliceTo(e.value, 0), "ME");
        }
    }
    if (!bootable or !category) return error.BadPbp;
    return .{ .title = title };
}
