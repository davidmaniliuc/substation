const Cop2 = @import("cop2.zig").Cop2;
const math = @import("math.zig");
const Value = @import("../pgxp/pgxp.zig").Value;

fn doPerspectiveTransform(cop2: *Cop2, vx: i64, vy: i64, vz: i64, sf: u6, lm: bool, set_mac0: bool) void {
    const tr = [3]i32{
        @as(i32, @bitCast(cop2.ctrl_regs[5])),
        @as(i32, @bitCast(cop2.ctrl_regs[6])),
        @as(i32, @bitCast(cop2.ctrl_regs[7])),
    };

    const m = math.matrixFromCtrl(cop2, 0); // rotation matrix RT

    // The translation enters the accumulator at 20.12 *before* the sf shift.
    var result: [3]i64 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var acc = math.accumulateMac(cop2, i + 1, (@as(i64, tr[i]) << 12) + @as(i64, m[i][0]) * vx);
        acc = math.accumulateMac(cop2, i + 1, acc + @as(i64, m[i][1]) * vy);
        acc = math.accumulateMac(cop2, i + 1, acc + @as(i64, m[i][2]) * vz);
        result[i] = acc;
    }

    math.setMacAndIr(cop2, 1, result[0], sf, lm);
    math.setMacAndIr(cop2, 2, result[1], sf, lm);
    math.checkMacOverflow(cop2, 3, result[2]);
    math.storeMac(cop2, 3, result[2] >> sf);

    // RTP derives the IR3 saturation flag from the unshifted Z as if lm were
    // always false, but the value it stores still honours lm.
    const z12 = result[2] >> 12;
    if (z12 > 32767 or z12 < -32768) cop2.setFlag(22);
    // Clipped from the stored 32-bit MAC3, not the wide accumulator.
    var ir3 = cop2.macs[3];
    const ir3_min: i64 = if (lm) 0 else -32768;
    if (ir3 > 32767) {
        ir3 = 32767;
    } else if (ir3 < ir3_min) {
        ir3 = ir3_min;
    }
    cop2.data_regs[11] = @as(u32, @bitCast(@as(i32, @as(i16, @intCast(ir3)))));

    // SZ FIFO Shift
    cop2.data_regs[16] = cop2.data_regs[17]; // sz0 = sz1
    cop2.data_regs[17] = cop2.data_regs[18]; // sz1 = sz2
    cop2.data_regs[18] = cop2.data_regs[19]; // sz2 = sz3

    // SZ3 always comes from the *unshifted* MAC3 >> 12, regardless of sf.
    var sz3 = z12;
    if (sz3 < 0) {
        cop2.setFlag(18);
        sz3 = 0;
    } else if (sz3 > 0xFFFF) {
        cop2.setFlag(18);
        sz3 = 0xFFFF;
    }
    cop2.data_regs[19] = @as(u32, @intCast(sz3));

    // Projection. h_s3z carries 16 fractional bits, matching OFX/OFY.
    const h = @as(u32, @as(u16, @truncate(cop2.ctrl_regs[26])));
    const h_s3z = @as(i64, math.divideUNR(cop2, h, @as(u32, @intCast(sz3))));

    const ofx = @as(i64, @as(i32, @bitCast(cop2.ctrl_regs[24])));
    const ofy = @as(i64, @as(i32, @bitCast(cop2.ctrl_regs[25])));

    const ir1 = @as(i64, Cop2.asI16(cop2.data_regs[9]));
    const ir2 = @as(i64, Cop2.asI16(cop2.data_regs[10]));

    // MAC0 is the projected coordinate in 16.16 — the `>> 16` below is the
    // whole of the precision loss PGXP exists to undo, so the unshifted value
    // is kept before it happens.
    const x_16_16 = math.setMac0(cop2, h_s3z * ir1 + ofx);
    const y_16_16 = math.setMac0(cop2, h_s3z * ir2 + ofy);
    const x = x_16_16 >> 16;
    const y = y_16_16 >> 16;

    // SXY FIFO Shift
    cop2.data_regs[12] = cop2.data_regs[13]; // sxy0 = sxy1
    cop2.data_regs[13] = cop2.data_regs[14]; // sxy1 = sxy2
    cop2.precise_sxy[0] = cop2.precise_sxy[1];
    cop2.precise_sxy[1] = cop2.precise_sxy[2];

    // Saturate X and Y to -1024..1023
    const sxy2 = Cop2.Point2D{
        .x = math.saturateSxy(cop2, x, 14), // flag bit 14 for X
        .y = math.saturateSxy(cop2, y, 13), // flag bit 13 for Y
    };
    cop2.data_regs[14] = @as(u32, @bitCast(sxy2));

    // A saturated vertex keeps its integer coordinate, and the rejection has
    // to happen HERE: the recorded word is taken from the saturated register,
    // so it matches the wire by construction and the staleness check at
    // consumption can never see the clamp. Recording it anyway would draw the
    // vertex from MAC0's unclamped position, up to a thousand columns from
    // where its own command word says it is. Hardware's clamp is the only
    // near-plane clip the machine has and games rely on it.
    cop2.precise_sxy[2] = Value.none;
    if (x == sxy2.x and y == sxy2.y) {
        cop2.precise_sxy[2] = .{
            .x = @floatCast(@as(f64, @floatFromInt(x_16_16)) / 65536.0),
            .y = @floatCast(@as(f64, @floatFromInt(y_16_16)) / 65536.0),
            .z = 0,
            .word = @bitCast(sxy2),
            .flags = Value.valid_xy,
        };
    }

    // Depth cueing: MAC0 = (H/SZ3)*DQA + DQB, IR0 = MAC0 >> 12 clamped to
    // 0..1000h. IR0 is the blend factor every fog/interpolate op reads.
    if (set_mac0) {
        const dqa = @as(i64, Cop2.asI16(cop2.ctrl_regs[27]));
        const dqb = @as(i64, @as(i32, @bitCast(cop2.ctrl_regs[28])));

        var ir0 = math.setMac0(cop2, h_s3z * dqa + dqb) >> 12;
        if (ir0 < 0) {
            cop2.setFlag(12);
            ir0 = 0;
        } else if (ir0 > 0x1000) {
            cop2.setFlag(12);
            ir0 = 0x1000;
        }
        cop2.data_regs[8] = @as(u32, @intCast(ir0));
    }
}

pub fn opRtps(cop2: *Cop2, sf: u6, lm: bool) void {
    const p = @as(Cop2.Point2D, @bitCast(cop2.data_regs[0]));
    const vz = cop2.data_regs[1];
    const vx0 = @as(i64, p.x);
    const vy0 = @as(i64, p.y);
    const vz0 = @as(i64, Cop2.asI16(vz));

    doPerspectiveTransform(cop2, vx0, vy0, vz0, sf, lm, true);
}

pub fn opRtpt(cop2: *Cop2, sf: u6, lm: bool) void {
    var j: usize = 0;
    while (j < 3) : (j += 1) {
        const base = j * 2;
        const p = @as(Cop2.Point2D, @bitCast(cop2.data_regs[base]));
        const vz = cop2.data_regs[base + 1];
        const vx = @as(i64, p.x);
        const vy = @as(i64, p.y);
        const vz_val = @as(i64, Cop2.asI16(vz));

        // Only the last vertex updates MAC0/IR0.
        doPerspectiveTransform(cop2, vx, vy, vz_val, sf, lm, j == 2);
    }
}

pub fn opNclip(cop2: *Cop2) void {
    // Cast the raw 32-bit registers directly to our packed struct
    const p0 = @as(Cop2.Point2D, @bitCast(cop2.data_regs[12]));
    const p1 = @as(Cop2.Point2D, @bitCast(cop2.data_regs[13]));
    const p2 = @as(Cop2.Point2D, @bitCast(cop2.data_regs[14]));

    const sx0 = @as(i64, p0.x);
    const sy0 = @as(i64, p0.y);
    const sx1 = @as(i64, p1.x);
    const sy1 = @as(i64, p1.y);
    const sx2 = @as(i64, p2.x);
    const sy2 = @as(i64, p2.y);

    // Perform the cross product: MAC0 = SX0*SY1 + SX1*SY2 + SX2*SY0 - SX0*SY2 - SX1*SY0 - SX2*SY1
    const result = (sx0 * sy1) + (sx1 * sy2) + (sx2 * sy0) -
        (sx0 * sy2) - (sx1 * sy0) - (sx2 * sy1);

    // A bare MAC0 store: the 32-bit overflow flags, then the narrowing store.
    _ = math.setMac0(cop2, result);
}

pub fn opMvmva(cop2: *Cop2, instr: u32, sf: u6, lm: bool) void {
    // COP2 command operand fields: bits 13-14 translation vector,
    // 15-16 multiply vector, 17-18 matrix.
    const trans_id = (instr >> 13) & 0x3;
    const vector_id = (instr >> 15) & 0x3;
    const matrix_id = (instr >> 17) & 0x3;

    // Matrix elements: i16. Selector 3 is not a fourth matrix and does not
    // alias RT — hardware assembles a garbage one out of the RGBC red
    // channel, IR0 and two stray rotation entries.
    const m: [3][3]i16 = switch (matrix_id) {
        0 => math.matrixFromCtrl(cop2, 0), // rotation
        1 => math.matrixFromCtrl(cop2, 8), // light
        2 => math.matrixFromCtrl(cop2, 16), // light colour
        3 => blk: {
            const rt = math.matrixFromCtrl(cop2, 0);
            const r = math.rgbcScaled(cop2)[0];
            const ir0 = Cop2.asI16(cop2.data_regs[8]);
            break :blk .{
                .{ -r, r, ir0 },
                .{ rt[0][2], rt[0][2], rt[0][2] },
                .{ rt[1][1], rt[1][1], rt[1][1] },
            };
        },
        else => unreachable,
    };

    // Vector: v0, v1, v2 (Data 0, 2, 4) or ir (Data 8, 9, 10)
    const v: [3]i16 = if (vector_id < 3) blk: {
        const base = vector_id * 2;
        const p = @as(Cop2.Point2D, @bitCast(cop2.data_regs[base]));
        const vz = cop2.data_regs[base + 1];
        break :blk .{
            p.x,
            p.y,
            Cop2.asI16(vz),
        };
    } else blk: {
        break :blk .{
            Cop2.asI16(cop2.data_regs[9]), // ir1
            Cop2.asI16(cop2.data_regs[10]), // ir2
            Cop2.asI16(cop2.data_regs[11]), // ir3
        };
    };

    // Translation: TR, BK, FC or None (Ctrl 5, 13, 21)
    const tr: [3]i32 = if (trans_id < 3) blk: {
        const base = 5 + (trans_id * 8);
        break :blk .{
            @as(i32, @bitCast(cop2.ctrl_regs[base])),
            @as(i32, @bitCast(cop2.ctrl_regs[base + 1])),
            @as(i32, @bitCast(cop2.ctrl_regs[base + 2])),
        };
    } else .{ 0, 0, 0 };

    // Selector 2 (far colour) is another documented hardware bug: the
    // translation is only applied while computing a throwaway first column,
    // whose sole lasting effect is the FLAG bits, and the MAC/IR actually
    // returned come from the 2nd and 3rd components with no translation at all.
    if (trans_id == 2) {
        for (0..3) |i| {
            const first = math.accumulateMac(cop2, i + 1, (@as(i64, tr[i]) << 12) + @as(i64, m[i][0]) * @as(i64, v[0]));
            math.saturateToIr(cop2, i + 1, first >> sf, lm);
        }
        for (0..3) |i| {
            var acc = math.accumulateMac(cop2, i + 1, @as(i64, m[i][1]) * @as(i64, v[1]));
            acc = math.accumulateMac(cop2, i + 1, acc + @as(i64, m[i][2]) * @as(i64, v[2]));
            math.setMacAndIr(cop2, i + 1, acc, sf, lm);
        }
        return;
    }

    math.multiplyMatrixByVector(cop2, m, v, tr, sf, lm);
}

pub fn opSqr(cop2: *Cop2, sf: u6, lm: bool) void {
    const ir = math.irVector64(cop2);

    // SQR is just IR multiplied element-wise by itself, so the overflow
    // check sees the un-shifted square.
    for (0..3) |i| {
        math.setMacAndIr(cop2, i + 1, ir[i] * ir[i], sf, lm);
    }
}

pub fn opAvsz(cop2: *Cop2, is_sz4: bool) void {
    // SZ FIFO uses 16-bit values, but they are unsigned for Z-depth
    const sz1 = @as(u32, @truncate(cop2.data_regs[17]));
    const sz2 = @as(u32, @truncate(cop2.data_regs[18]));
    const sz3 = @as(u32, @truncate(cop2.data_regs[19]));

    // ZSF3 and ZSF4 are 16-bit signed scale factors
    const zsf3 = @as(i64, Cop2.asI16(cop2.ctrl_regs[29]));
    const zsf4 = @as(i64, Cop2.asI16(cop2.ctrl_regs[30]));

    var sum: u32 = sz1 + sz2 + sz3;
    var zsf: i64 = zsf3;

    if (is_sz4) {
        const sz0 = @as(u32, @truncate(cop2.data_regs[16]));
        sum += sz0;
        zsf = zsf4;
    }

    // MAC0 = ZSF * Sum
    const mac0 = zsf * @as(i64, sum);
    math.storeMac(cop2, 0, mac0);

    // Overflow checks for MAC0
    if (mac0 > 0x7FFFFFFF) {
        cop2.setFlag(16); // MAC0 positive overflow
    } else if (mac0 < -0x80000000) {
        cop2.setFlag(15); // MAC0 negative overflow
    }

    // OTZ = MAC0 >> 12 (Divided by 4096)
    var otz = mac0 >> 12;

    // OTZ is saturated to 0..FFFF
    if (otz < 0) {
        otz = 0;
        cop2.setFlag(18); // SZ3 / OTZ saturation flag
    } else if (otz > 0xFFFF) {
        otz = 0xFFFF;
        cop2.setFlag(18); // SZ3 / OTZ saturation flag
    }

    cop2.data_regs[7] = @as(u32, @intCast(otz)); // Write to OTZ register
}

fn pushRgb(cop2: *Cop2, r: u8, g: u8, b: u8) void {
    // Shift RGB FIFO: RGB0 = RGB1, RGB1 = RGB2
    cop2.data_regs[20] = cop2.data_regs[21];
    cop2.data_regs[21] = cop2.data_regs[22];

    // Read the CODE (command byte) from RGBC (DataReg 6)
    const code = @as(u8, @truncate(cop2.data_regs[6] >> 24));

    // Pack new color into RGB2 (DataReg 22)
    const rgb2 = Cop2.ColorCode{ .r = r, .g = g, .b = b, .code = code };
    cop2.data_regs[22] = @as(u32, @bitCast(rgb2));
}

/// Push a colour onto the FIFO: MAC1..3 >> 4, clamped to 0..255.
fn pushColorFromMac(cop2: *Cop2) void {
    const r = math.clampColor(cop2, cop2.macs[1] >> 4, 21);
    const g = math.clampColor(cop2, cop2.macs[2] >> 4, 20);
    const b = math.clampColor(cop2, cop2.macs[3] >> 4, 19);
    pushRgb(cop2, r, g, b);
}

/// The lighting half shared by NCS/NCT/NCDS/NCDT/NCCS/NCCT: light matrix
/// against the vertex normal, then the light-colour matrix against the
/// resulting IR, translated by the background colour.
fn applyLighting(cop2: *Cop2, n: usize, sf: u6, lm: bool) void {
    math.multiplyMatrixByVector(cop2, math.matrixFromCtrl(cop2, 8), math.vertex(cop2, n), .{ 0, 0, 0 }, sf, lm);
    math.multiplyMatrixByVector(cop2, math.matrixFromCtrl(cop2, 16), math.irVector(cop2), math.backgroundColor(cop2), sf, lm);
}

/// Depth-cue tail shared by NCDS/NCDT and CDP.
///
/// This is deliberately a *two-stage* op: stage 1 interpolates towards the
/// far colour and saturates into IR with lm forced to 0, stage 2 folds that
/// saturated IR back in through IR0. Collapsing the two loses the
/// intermediate +/-0x7FFF clamp. Crucially, both stages weight by the RGBC
/// vertex colour — dropping it is what rendered the BIOS boot logo grey.
fn depthCueWithRgbc(cop2: *Cop2, sf: u6, lm: bool) void {
    const prev_ir = math.irVector(cop2);
    const col = math.rgbcScaled(cop2);
    const fc = math.farColor(cop2);

    for (0..3) |i| {
        math.setMacAndIr(cop2, i + 1, (fc[i] << 12) - @as(i64, col[i]) * @as(i64, prev_ir[i]), sf, false);
    }

    const ir0 = math.ir0(cop2);
    const ir = math.irVector(cop2);
    for (0..3) |i| {
        math.setMacAndIr(cop2, i + 1, @as(i64, col[i]) * @as(i64, prev_ir[i]) + ir0 * @as(i64, ir[i]), sf, lm);
    }

    pushColorFromMac(cop2);
}

// NCS / NCT: lighting only.
pub fn opNcs(cop2: *Cop2, sf: u6, lm: bool) void {
    ncsSingle(cop2, 0, sf, lm);
}

pub fn opNct(cop2: *Cop2, sf: u6, lm: bool) void {
    for (0..3) |n| ncsSingle(cop2, n, sf, lm);
}

fn ncsSingle(cop2: *Cop2, n: usize, sf: u6, lm: bool) void {
    applyLighting(cop2, n, sf, lm);
    pushColorFromMac(cop2);
}

// NCDS / NCDT: lighting -> depth cueing.
pub fn opNcds(cop2: *Cop2, sf: u6, lm: bool) void {
    ncdsSingle(cop2, 0, sf, lm);
}

pub fn opNcdt(cop2: *Cop2, sf: u6, lm: bool) void {
    for (0..3) |n| ncdsSingle(cop2, n, sf, lm);
}

fn ncdsSingle(cop2: *Cop2, n: usize, sf: u6, lm: bool) void {
    applyLighting(cop2, n, sf, lm);
    depthCueWithRgbc(cop2, sf, lm);
}

// NCCS / NCCT: lighting -> modulate by RGBC.
pub fn opNccs(cop2: *Cop2, sf: u6, lm: bool) void {
    nccsSingle(cop2, 0, sf, lm);
}

pub fn opNcct(cop2: *Cop2, sf: u6, lm: bool) void {
    for (0..3) |n| nccsSingle(cop2, n, sf, lm);
}

fn nccsSingle(cop2: *Cop2, n: usize, sf: u6, lm: bool) void {
    applyLighting(cop2, n, sf, lm);
    math.multiplyVectors(cop2, math.rgbcScaled(cop2), math.irVector(cop2), .{ 0, 0, 0 }, sf, lm);
    pushColorFromMac(cop2);
}

// CDP: colour matrix -> depth cueing.
pub fn opCdp(cop2: *Cop2, sf: u6, lm: bool) void {
    math.multiplyMatrixByVector(cop2, math.matrixFromCtrl(cop2, 16), math.irVector(cop2), math.backgroundColor(cop2), sf, lm);
    depthCueWithRgbc(cop2, sf, lm);
}

// CC: colour matrix -> modulate by RGBC.
pub fn opCc(cop2: *Cop2, sf: u6, lm: bool) void {
    math.multiplyMatrixByVector(cop2, math.matrixFromCtrl(cop2, 16), math.irVector(cop2), math.backgroundColor(cop2), sf, lm);
    math.multiplyVectors(cop2, math.rgbcScaled(cop2), math.irVector(cop2), .{ 0, 0, 0 }, sf, lm);
    pushColorFromMac(cop2);
}

/// The depth-cue body shared by DPCS / DPCT / INTPL: interpolate `base`
/// towards the far colour, then push the result onto the colour FIFO.
///
/// Deliberately a *two-stage* op, not the single fused expression it looks
/// like: stage 1 interpolates towards the far colour and saturates into IR
/// with lm forced to 0, stage 2 folds that already-saturated IR back in
/// through IR0. Collapsing the two loses the intermediate ±0x7FFF clamp.
/// The callers differ only in where `base` comes from.
fn depthCueFrom(cop2: *Cop2, base: [3]i64, sf: u6, lm: bool) void {
    const fc = math.farColor(cop2);

    // Stage 1: MAC = (FC << 12) - (base << 12), then IR = saturate(MAC).
    for (0..3) |i| {
        math.setMacAndIr(cop2, i + 1, (fc[i] << 12) - (base[i] << 12), sf, false);
    }

    // Stage 2: MAC = (base << 12) + IR0 * IR.
    const ir0 = math.ir0(cop2);
    for (0..3) |i| {
        const ir_new = @as(i64, Cop2.asI16(cop2.data_regs[9 + i]));
        math.setMacAndIr(cop2, i + 1, (base[i] << 12) + ir0 * ir_new, sf, lm);
    }

    pushColorFromMac(cop2);
}

/// Depth cueing for DPCS / DPCT: the base is a colour, which enters the
/// accumulator scaled by 16.
fn depthCueColor(cop2: *Cop2, r: u8, g: u8, b: u8, sf: u6, lm: bool) void {
    depthCueFrom(cop2, .{ @as(i64, r) << 4, @as(i64, g) << 4, @as(i64, b) << 4 }, sf, lm);
}

pub fn opDpcs(cop2: *Cop2, sf: u6, lm: bool) void {
    // DPCS reads RGBC, *not* the colour FIFO.
    const c = @as(Cop2.ColorCode, @bitCast(cop2.data_regs[6]));
    depthCueColor(cop2, c.r, c.g, c.b, sf, lm);
}

pub fn opDpct(cop2: *Cop2, sf: u6, lm: bool) void {
    // Three passes, each reading RGB0 — every pass pushes a new colour and
    // shifts the FIFO, so this walks all three entries.
    for (0..3) |_| {
        const c = @as(Cop2.ColorCode, @bitCast(cop2.data_regs[20]));
        depthCueColor(cop2, c.r, c.g, c.b, sf, lm);
    }
}

pub fn opDcpl(cop2: *Cop2, sf: u6, lm: bool) void {
    // DCPL does no matrix multiply: it is exactly the depth-cue tail,
    // interpolating the current IR towards the far colour weighted by RGBC.
    depthCueWithRgbc(cop2, sf, lm);
}

pub fn opOp(cop2: *Cop2, sf: u6, lm: bool) void {
    // OP crosses IR with the *diagonal* of RT, not with its third column.
    const rt = math.matrixFromCtrl(cop2, 0);
    const d = [3]i64{ rt[0][0], rt[1][1], rt[2][2] };
    const ir = math.irVector64(cop2);

    // All three MACs are computed before any IR is written back: MAC2 reads
    // IR3 and MAC3 reads IR2, and setMacAndIr overwrites them as it goes.
    const cross = [3]i64{
        (d[1] * ir[2]) - (d[2] * ir[1]),
        (d[2] * ir[0]) - (d[0] * ir[2]),
        (d[0] * ir[1]) - (d[1] * ir[0]),
    };

    for (0..3) |i| {
        math.setMacAndIr(cop2, i + 1, cross[i], sf, lm);
    }
}

/// INTPL: colour interpolation. The same depth cue as DPCS, based on the
/// current IR vector instead of a colour.
pub fn opIntpl(cop2: *Cop2, sf: u6, lm: bool) void {
    depthCueFrom(cop2, math.irVector64(cop2), sf, lm);
}

// GPF / GPL: General Purpose Interpolate
pub fn opGpx(cop2: *Cop2, sf: u6, lm: bool, accumulate: bool) void {
    const ir0 = math.ir0(cop2);
    const ir = math.irVector64(cop2);

    // GPF starts from zero; GPL accumulates the current MAC, scaled back up
    // by sf so that setMacAndIr's shift leaves it where it already was.
    // Capture all three first — setMacAndIr overwrites MAC as it goes.
    var base = [3]i64{ 0, 0, 0 };
    if (accumulate) {
        for (0..3) |i| base[i] = cop2.macs[i + 1] << sf;
    }

    for (0..3) |i| {
        math.setMacAndIr(cop2, i + 1, base[i] + ir0 * ir[i], sf, lm);
    }

    pushColorFromMac(cop2);
}
