const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const ps1_core = @import("ps1_core");
const Mdec = ps1_core.mdec.Mdec;

// MDEC command words: bits 31-29 = command, and for Decode Macroblocks
// bits 28-27 = output depth (2 = 24bpp, 3 = 15bpp), bits 15-0 = word count.
const cmd_decode: u32 = 0x20000000;
const cmd_quant: u32 = 0x40000000;
const cmd_scale: u32 = 0x60000000;

fn decodeCmd(depth: u32, words: u32) u32 {
    return cmd_decode | (depth << 27) | words;
}

/// One 16-bit MDEC token pair per 32-bit write.
fn pushHalfwords(m: *Mdec, halfwords: []const u16) void {
    var i: usize = 0;
    while (i < halfwords.len) : (i += 2) {
        const lo: u32 = halfwords[i];
        const hi: u32 = if (i + 1 < halfwords.len) halfwords[i + 1] else 0;
        m.write(lo | (hi << 16));
    }
}

fn setQuantTable(m: *Mdec, value: u8) void {
    m.write(cmd_quant);
    const w = @as(u32, value) | (@as(u32, value) << 8) | (@as(u32, value) << 16) | (@as(u32, value) << 24);
    for (0..32) |_| m.write(w);
}

fn setScaleTable(m: *Mdec, value: i16) void {
    m.write(cmd_scale);
    const u: u32 = @as(u16, @bitCast(value));
    for (0..32) |_| m.write(u | (u << 16));
}

fn dctWord(q_factor: u16, dc: u16) u16 {
    return (q_factor << 10) | (dc & 0x3FF);
}

/// RLE token that runs `n` past the end of the block, terminating it.
const block_end: u16 = 63 << 10;

test "MDEC decodes an all-zero macroblock to neutral grey, not black" {
    var m = Mdec.init();

    // The IDCT output is signed and centred on zero, so a macroblock whose
    // coefficients are all zero is mid-grey (0x808080), not black. Missing the
    // +128 bias made every FMV frame come out black/garbage.
    setQuantTable(&m, 1);

    var stream: [12]u16 = undefined;
    for (0..6) |b| { // Cr, Cb, Y0..Y3
        stream[b * 2 + 0] = dctWord(1, 0);
        stream[b * 2 + 1] = block_end;
    }

    m.write(decodeCmd(3, stream.len / 2));
    pushHalfwords(&m, &stream);

    // 15bpp: 0x80 >> 3 = 16 in each channel -> 16 | 16<<5 | 16<<10 = 0x4210,
    // two pixels packed per word.
    try expectEqual(@as(u32, 0x42104210), m.readData());
    try expectEqual(@as(u32, 0x42104210), m.readData());
}

test "MDEC output depth comes from the decode command, not the control register" {
    var m = Mdec.init();
    setQuantTable(&m, 1);

    var stream: [12]u16 = undefined;
    for (0..6) |b| {
        stream[b * 2 + 0] = dctWord(1, 0);
        stream[b * 2 + 1] = block_end;
    }

    // A control write carrying depth bits must NOT set the output depth; only
    // the MDEC(1) command word does. Latching it from the control register made
    // the pixel format depend on whichever control write happened last.
    m.writeControl(3 << 27);

    m.write(decodeCmd(2, stream.len / 2)); // 2 = 24bpp
    pushHalfwords(&m, &stream);

    // 24bpp packs 4 pixels into 3 words with no padding, so a uniform 0x808080
    // block reads back as 0x80808080 and 16x16 pixels occupy 192 words.
    try expectEqual(@as(u32, 0x80808080), m.readData());
    try expectEqual(@as(u32, 192), m.output_len + 1); // one word drained
}

// 24bpp output is *densely* packed: 4 pixels span exactly 3 words (Avocado
// mdec.cpp:35-48). Emitting one pixel per word instead injects a zero byte
// every 4th byte, which stretches each scanline by 4/3 and lays black stripes
// over it — Silent Hill's intro FMV was unwatchable because of this.
test "MDEC packs 24bpp output 4 pixels to 3 words" {
    var m = Mdec.init();
    setQuantTable(&m, 1);
    setScaleTable(&m, 0x2000); // without an IDCT table every block decodes flat grey

    // Cr DC non-zero so the macroblock is a uniform *non-grey* colour and the
    // three channels are distinguishable from one another.
    var stream: [12]u16 = undefined;
    for (0..6) |b| {
        stream[b * 2 + 0] = dctWord(1, if (b == 0) 100 else 0);
        stream[b * 2 + 1] = block_end;
    }

    m.write(decodeCmd(2, stream.len / 2)); // 2 = 24bpp
    pushHalfwords(&m, &stream);

    // 16x16 pixels / 4 * 3 = 192 words, no padding.
    try expectEqual(@as(u32, 192), m.output_len);

    // Three consecutive words are twelve consecutive bytes = four whole pixels.
    var bytes: [12]u8 = undefined;
    for (0..3) |w| {
        const word = m.readData();
        for (0..4) |b| bytes[w * 4 + b] = @truncate(word >> @intCast(b * 8));
    }

    // The block is uniform, so all four pixel triples must be identical. A
    // one-pixel-per-word packing would put a 0x00 in bytes 3, 7 and 11 and this
    // fails immediately.
    const px = bytes[0..3];
    try expect(std.mem.eql(u8, px, bytes[3..6]));
    try expect(std.mem.eql(u8, px, bytes[6..9]));
    try expect(std.mem.eql(u8, px, bytes[9..12]));

    // Guard against the assertion above passing trivially on a grey block.
    try expect(px[0] != px[1] or px[1] != px[2]);
}

test "MDEC honours the block's quantization factor" {
    // The qFactor lives in bits 15-10 of each block's DCT word and scales every
    // AC coefficient: value = (ac * quant[n] * qFactor + 4) / 8. Substituting
    // the uploaded scale/IDCT table for it (the old bug) made the decoded
    // picture independent of qFactor entirely.
    const ac: u16 = 511; // largest positive 10-bit AC

    var first: u32 = undefined;
    for ([_]u16{ 1, 2 }, 0..) |q_factor, run| {
        var m = Mdec.init();
        setQuantTable(&m, 8);
        setScaleTable(&m, 0x2000);

        var stream: [18]u16 = undefined;
        for (0..6) |b| {
            stream[b * 3 + 0] = dctWord(q_factor, 0);
            stream[b * 3 + 1] = ac; // zeroes = 0 -> coefficient at index 1
            stream[b * 3 + 2] = block_end;
        }

        m.write(decodeCmd(3, stream.len / 2));
        pushHalfwords(&m, &stream);

        const word = m.readData();
        if (run == 0) {
            first = word;
        } else {
            try expect(word != first);
        }
    }
}
