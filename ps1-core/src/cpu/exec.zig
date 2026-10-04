const std = @import("std");
const alu = @import("../alu.zig");
const bits = @import("../bits.zig");
const signExtend16 = bits.sext16;
const signExtend8 = bits.sext8;
const Cpu = @import("cpu.zig").Cpu;
const Reg = @import("cpu.zig").Reg;
const icache = @import("icache.zig");
const pgxp = @import("../pgxp/pgxp.zig");
const Value = pgxp.Value;
const ops = pgxp.ops;
const shift_ops = pgxp.shift;
const muldiv = pgxp.muldiv;

pub const Instruction = packed union {
    raw: u32,
    r: packed struct(u32) {
        funct: u6, // Bits 0-5
        shamt: u5, // Bits 6-10
        rd: u5, // Bits 11-15
        rt: u5, // Bits 16-20
        rs: u5, // Bits 21-25
        opcode: u6, // Bits 26-31
    },
    i: packed struct(u32) {
        imm: u16, // Bits 0-15
        rt: u5, // Bits 16-20
        rs: u5, // Bits 21-25
        opcode: u6, // Bits 26-31
    },
    j: packed struct(u32) {
        target: u26, // Bits 0-25
        opcode: u6, // Bits 26-31
    },
};

pub inline fn decode(instr: u32) Instruction {
    return @as(Instruction, @bitCast(instr));
}

pub const LoadType = enum { Byte, Half, Word };
const UnalignedLoadType = enum { Left, Right };

pub const StoreType = enum { Byte, Half, Word };
const UnalignedStoreType = enum { Left, Right };

/// Effective address of a load or store: base register + sign-extended
/// 16-bit offset, wrapping.
inline fn effectiveAddress(cpu: *Cpu, instr: Instruction) u32 {
    return cpu.readReg(instr.i.rs) +% signExtend16(instr.i.imm);
}

/// Raise a load/store address error. Both halves are needed at every
/// misaligned-access site: without the BadVaddr write the kernel handler
/// reports whatever address faulted last.
inline fn addressError(cpu: *Cpu, address: u32, comptime kind: Cpu.Exception) void {
    cpu.cop0.setReg(.badvaddr, address);
    cpu.exception(kind, 0);
}

/// Alignment the access width requires: a word faults on the low two bits,
/// a halfword on the low one, a byte never faults.
fn alignMask(comptime width: anytype) u32 {
    return switch (width) {
        .Word => 3,
        .Half => 1,
        .Byte => 0,
    };
}

/// PGXP's CPU mode: on only when PGXP itself is, and off by default. Every
/// propagation site this task set adds is behind it.
inline fn cpuMode(cpu: *const Cpu) bool {
    return cpu.bus.pgxp_enabled and cpu.bus.pgxp_cpu;
}

/// Retire a register-form result to Rd, running `hook` first when PGXP's CPU
/// mode is on — for the same reason `iRetire` does: `writeReg` destroys both
/// the destination's shadow and its integer, and the destination is routinely
/// one of the sources.
inline fn rRetire(cpu: *Cpu, instr: Instruction, result: u32, comptime hook: ?ops.RegHook) void {
    if (hook) |h| {
        if (cpuMode(cpu)) {
            const p = h(cpu, instr.r.rs, instr.r.rt, result);
            cpu.writeRegPrecise(instr.r.rd, result, p);
            return;
        }
    }
    cpu.writeReg(instr.r.rd, result);
}

inline fn rOp(cpu: *Cpu, instr: Instruction, comptime op: fn (u32, u32) u32, comptime hook: ?ops.RegHook) void {
    rRetire(cpu, instr, op(cpu.readReg(instr.r.rs), cpu.readReg(instr.r.rt)), hook);
}

/// `or`/`addu` against $zero is the register-move idiom. It is the only
/// arithmetic BASE PGXP follows: with CPU mode off everything else falls
/// through `writeReg` and clears the shadow, which is what keeps the shipped
/// propagation set small.
inline fn rOpMove(cpu: *Cpu, instr: Instruction, comptime op: fn (u32, u32) u32, comptime hook: ?ops.RegHook) void {
    const a = cpu.readReg(instr.r.rs);
    const b = cpu.readReg(instr.r.rt);
    const value = op(a, b);
    if (cpu.bus.pgxp_enabled and instr.r.rt == 0) {
        // Base PGXP, NOT CPU mode: this idiom is part of the shipped
        // propagation set and predates the flag.
        const p = ops.move(cpu, instr.r.rs);
        cpu.writeRegPrecise(instr.r.rd, value, p);
    } else {
        rRetire(cpu, instr, value, hook);
    }
}

inline fn rOpChecked(cpu: *Cpu, instr: Instruction, comptime op: fn (u32, u32) ?u32, comptime hook: ?ops.RegHook) void {
    if (op(cpu.readReg(instr.r.rs), cpu.readReg(instr.r.rt))) |result| {
        rRetire(cpu, instr, result, hook);
    } else {
        cpu.exception(.ArithmeticOverflow, 0);
    }
}

inline fn hiLoOp(
    cpu: *Cpu,
    instr: Instruction,
    comptime op: fn (u32, u32) alu.HiLo,
    comptime hook: muldiv.Hook,
    comptime signed: bool,
) void {
    const result = op(cpu.readReg(instr.r.rs), cpu.readReg(instr.r.rt));
    cpu.hi = result.hi;
    cpu.lo = result.lo;
    // The hook runs AFTER the integer write, unlike every other CPU-mode op:
    // `hi` and `lo` are its destinations and never its sources, so nothing it
    // reads has been destroyed, and the words just written are the staleness
    // keys its two shadows are recorded against.
    if (cpuMode(cpu)) hook(cpu, instr.r.rs, instr.r.rt, signed);
}

/// What `execute` runs for one instruction word, resolved once. The block
/// engines decode a block's words into these when they compile it, and the
/// interpreter resolves one per step. There is one table, so a fix to an
/// instruction fixes it in every engine.
pub const Handler = *const fn (cpu: *Cpu, instr: Instruction) void;

/// `f(cpu, instr, args...)` as a `Handler`: binds an op's comptime
/// parameters, so the table can hold a plain function pointer. Comptime
/// memoisation gives one function per distinct `(f, args)`.
fn bind(comptime f: anytype, comptime args: anytype) Handler {
    return &struct {
        fn h(cpu: *Cpu, instr: Instruction) void {
            @call(.always_inline, f, .{ cpu, instr } ++ args);
        }
    }.h;
}

pub fn execute(cpu: *Cpu, raw_instr: u32) void {
    handlerFor(raw_instr)(cpu, decode(raw_instr));
}

pub inline fn handlerFor(raw: u32) Handler {
    const instr = decode(raw);
    return switch (instr.i.opcode) {
        0x00 => specialHandlerFor(instr.r.funct),
        0x01 => &opRegimm, // REGIMM (rt-based branches)
        0x02 => &opJ,
        0x03 => &opJal,

        0x04 => &opBeq,
        0x05 => &opBne,
        0x06 => &opBlez,
        0x07 => &opBgtz,

        0x08 => bind(iOpChecked, .{ alu.add, &ops.addi }),
        0x09 => bind(iOpSignExt, .{ alu.addu, &ops.addi }),
        0x0A => bind(iOpSignExt, .{ alu.slt, &ops.exact }),
        0x0B => bind(iOpSignExt, .{ alu.sltu, &ops.exact }),
        0x0C => bind(iOpZeroExt, .{ alu.and_, &ops.andi }),
        0x0D => bind(iOpZeroExt, .{ alu.or_, &ops.bitwiseImm }),
        0x0E => bind(iOpZeroExt, .{ alu.xor, &ops.bitwiseImm }),
        0x0F => &opLui,

        0x10 => bind(opCop, .{@as(u2, 0)}),
        0x11 => bind(opCop, .{@as(u2, 1)}),
        0x12 => bind(opCop, .{@as(u2, 2)}),
        0x13 => bind(opCop, .{@as(u2, 3)}),

        0x20 => bind(opLoad, .{ LoadType.Byte, true }), // LB  (Sign-extended)
        0x21 => bind(opLoad, .{ LoadType.Half, true }), // LH  (Sign-extended)
        0x22 => bind(opUnalignedLoad, .{UnalignedLoadType.Left}), // LWL
        0x23 => bind(opLoad, .{ LoadType.Word, false }), // LW  (Word)
        0x24 => bind(opLoad, .{ LoadType.Byte, false }), // LBU (Zero-extended)
        0x25 => bind(opLoad, .{ LoadType.Half, false }), // LHU (Zero-extended)
        0x26 => bind(opUnalignedLoad, .{UnalignedLoadType.Right}), // LWR

        0x28 => bind(opStore, .{StoreType.Byte}), // SB
        0x29 => bind(opStore, .{StoreType.Half}), // SH
        0x2A => bind(opUnalignedStore, .{UnalignedStoreType.Left}), // SWL
        0x2B => bind(opStore, .{StoreType.Word}), // SW
        0x2E => bind(opUnalignedStore, .{UnalignedStoreType.Right}), // SWR

        0x30 => bind(opLwc, .{@as(u2, 0)}), // LWC0
        0x31 => bind(opLwc, .{@as(u2, 1)}), // LWC1
        0x32 => bind(opLwc, .{@as(u2, 2)}), // LWC2
        0x33 => bind(opLwc, .{@as(u2, 3)}), // LWC3

        0x38 => bind(opSwc, .{@as(u2, 0)}), // SWC0
        0x39 => bind(opSwc, .{@as(u2, 1)}), // SWC1
        0x3A => bind(opSwc, .{@as(u2, 2)}), // SWC2
        0x3B => bind(opSwc, .{@as(u2, 3)}), // SWC3

        0x14...0x1F, 0x27, 0x2C, 0x2D, 0x2F, 0x34...0x37, 0x3C...0x3F => &opReserved,
    };
}

inline fn specialHandlerFor(funct: u6) Handler {
    return switch (funct) {
        0x00 => bind(shift, .{ alu.sll, &shift_ops.left }),
        0x02 => bind(shift, .{ alu.srl, &shift_ops.srl }),
        0x03 => bind(shift, .{ alu.sra, &shift_ops.sra }),
        0x04 => bind(shiftV, .{ alu.sll, &shift_ops.left }),
        0x06 => bind(shiftV, .{ alu.srl, &shift_ops.srlv }),
        0x07 => bind(shiftV, .{ alu.sra, &shift_ops.srav }),

        0x08 => &opJr,
        0x09 => &opJalr,

        0x0C => &opSyscall,
        0x0D => &opBreak,

        0x10 => &opMfhi,
        0x11 => &opMthi,
        0x12 => &opMflo,
        0x13 => &opMtlo,

        0x18 => bind(hiLoOp, .{ alu.mult, &muldiv.mult, true }),
        0x19 => bind(hiLoOp, .{ alu.multu, &muldiv.mult, false }),
        0x1A => bind(hiLoOp, .{ alu.div, &muldiv.div, true }),
        0x1B => bind(hiLoOp, .{ alu.divu, &muldiv.div, false }),

        0x20 => bind(rOpChecked, .{ alu.add, &ops.add }),
        0x21 => bind(rOpMove, .{ alu.addu, &ops.add }),
        0x22 => bind(rOpChecked, .{ alu.sub, &ops.sub }),
        0x23 => bind(rOp, .{ alu.subu, &ops.sub }),

        0x24 => bind(rOp, .{ alu.and_, &ops.bitwise }),
        0x25 => bind(rOpMove, .{ alu.or_, &ops.bitwise }),
        0x26 => bind(rOp, .{ alu.xor, &ops.bitwise }),
        0x27 => bind(rOp, .{ alu.nor, &ops.bitwise }),

        0x2A => bind(rOp, .{ alu.slt, &ops.sltReg }),
        0x2B => bind(rOp, .{ alu.sltu, &ops.sltReg }),

        // 0x01, 0x05, 0x0A-0x0B, 0x0E-0x0F, 0x14-0x17, 0x1C-0x1F, 0x28-0x29, 0x2C-0x3F
        else => &opReserved,
    };
}

fn opSyscall(cpu: *Cpu, instr: Instruction) void {
    _ = instr;
    cpu.exception(.Syscall, 0);
}

fn opBreak(cpu: *Cpu, instr: Instruction) void {
    _ = instr;
    cpu.exception(.Breakpoint, 0);
}

fn opReserved(cpu: *Cpu, instr: Instruction) void {
    _ = instr;
    cpu.exception(.ReservedInstruction, 0);
}

fn opMfhi(cpu: *Cpu, instr: Instruction) void {
    cpu.writeReg(instr.r.rd, cpu.hi);
    if (cpuMode(cpu)) muldiv.moveFromHi(cpu, instr.r.rd);
}

fn opMthi(cpu: *Cpu, instr: Instruction) void {
    cpu.hi = cpu.readReg(instr.r.rs);
    if (cpuMode(cpu)) muldiv.moveToHi(cpu, instr.r.rs);
}

fn opMflo(cpu: *Cpu, instr: Instruction) void {
    cpu.writeReg(instr.r.rd, cpu.lo);
    if (cpuMode(cpu)) muldiv.moveFromLo(cpu, instr.r.rd);
}

fn opMtlo(cpu: *Cpu, instr: Instruction) void {
    cpu.lo = cpu.readReg(instr.r.rs);
    if (cpuMode(cpu)) muldiv.moveToLo(cpu, instr.r.rs);
}

/// Retire a shift result to Rd, running `hook` first when PGXP's CPU mode is
/// on — for the same reason `rRetire` does: `sll $t0, $t0, 16` names its own
/// destination as its source, and `writeReg` would have destroyed both by the
/// time the hook ran.
inline fn shiftRetire(
    cpu: *Cpu,
    instr: Instruction,
    shamt: u5,
    result: u32,
    comptime hook: shift_ops.Hook,
) void {
    if (cpuMode(cpu)) {
        const p = hook(cpu, instr.r.rt, shamt, result);
        cpu.writeRegPrecise(instr.r.rd, result, p);
        return;
    }
    cpu.writeReg(instr.r.rd, result);
}

inline fn shift(cpu: *Cpu, instr: Instruction, comptime op: fn (u32, u5) u32, comptime hook: shift_ops.Hook) void {
    const shamt = instr.r.shamt;
    shiftRetire(cpu, instr, shamt, op(cpu.readReg(instr.r.rt), shamt), hook);
}

inline fn shiftV(cpu: *Cpu, instr: Instruction, comptime op: fn (u32, u5) u32, comptime hook: shift_ops.Hook) void {
    const shamt = @as(u5, @truncate(cpu.readReg(instr.r.rs) & 0x1F));
    shiftRetire(cpu, instr, shamt, op(cpu.readReg(instr.r.rt), shamt), hook);
}

fn opJ(cpu: *Cpu, instr: Instruction) void {
    cpu.pipeline.next_is_delay_slot = true;
    cpu.pipeline.next_pc = (cpu.pipeline.pc & 0xF0000000) | (@as(u32, instr.j.target) << 2);
}

fn opJal(cpu: *Cpu, instr: Instruction) void {
    cpu.writeReg(Reg.ra, cpu.pipeline.pc +% 4);
    opJ(cpu, instr);
}

fn opBeq(cpu: *Cpu, instr: Instruction) void {
    doBranch(cpu, cpu.readReg(instr.i.rs) == cpu.readReg(instr.i.rt), instr.i.imm);
}

fn opBne(cpu: *Cpu, instr: Instruction) void {
    doBranch(cpu, cpu.readReg(instr.i.rs) != cpu.readReg(instr.i.rt), instr.i.imm);
}

fn opBlez(cpu: *Cpu, instr: Instruction) void {
    const rs_val = @as(i32, @bitCast(cpu.readReg(instr.i.rs)));
    doBranch(cpu, rs_val <= 0, instr.i.imm);
}

fn opBgtz(cpu: *Cpu, instr: Instruction) void {
    const rs_val = @as(i32, @bitCast(cpu.readReg(instr.i.rs)));
    doBranch(cpu, rs_val > 0, instr.i.imm);
}

fn opRegimm(cpu: *Cpu, instr: Instruction) void {
    const rt = instr.i.rt;
    const rs_val = @as(i32, @bitCast(cpu.readReg(instr.i.rs)));
    const imm = instr.i.imm;

    switch (rt) {
        0x00 => doBranch(cpu, rs_val < 0, imm), // BLTZ (Branch Less Than Zero)
        0x01 => doBranch(cpu, rs_val >= 0, imm), // BGEZ (Branch Greater Than or Equal to Zero)
        0x10 => { // BLTZAL (Branch Less Than Zero And Link)
            cpu.writeReg(Reg.ra, cpu.pipeline.pc +% 4);
            doBranch(cpu, rs_val < 0, imm);
        },
        0x11 => { // BGEZAL (Branch Greater Than or Equal to Zero And Link)
            cpu.writeReg(Reg.ra, cpu.pipeline.pc +% 4);
            doBranch(cpu, rs_val >= 0, imm);
        },
        else => {
            cpu.exception(.ReservedInstruction, 0);
        },
    }
}

inline fn doBranch(cpu: *Cpu, condition: bool, imm: u16) void {
    cpu.pipeline.next_is_delay_slot = true;
    if (condition) {
        const offset = signExtend16(imm) << 2;
        cpu.pipeline.next_pc = cpu.pipeline.pc +% offset;
    }
}

fn opJr(cpu: *Cpu, instr: Instruction) void {
    cpu.pipeline.next_is_delay_slot = true;
    cpu.pipeline.next_pc = cpu.readReg(instr.r.rs);
}

fn opJalr(cpu: *Cpu, instr: Instruction) void {
    cpu.writeReg(instr.r.rd, cpu.pipeline.pc +% 4);
    cpu.pipeline.next_is_delay_slot = true;
    cpu.pipeline.next_pc = cpu.readReg(instr.r.rs);
}

/// Retire an immediate-form result to Rt, running `hook` first when PGXP's
/// CPU mode is on. First is the whole point: `writeReg` destroys both the
/// destination's shadow and its integer, so a hook running afterwards would
/// see neither whenever Rt IS Rs.
inline fn iRetire(
    cpu: *Cpu,
    instr: Instruction,
    imm32: u32,
    result: u32,
    comptime hook: ?ops.ImmHook,
) void {
    if (hook) |h| {
        if (cpuMode(cpu)) {
            const p = h(cpu, instr.i.rs, imm32, result);
            cpu.writeRegPrecise(instr.i.rt, result, p);
            return;
        }
    }
    cpu.writeReg(instr.i.rt, result);
}

inline fn iOpZeroExt(cpu: *Cpu, instr: Instruction, comptime op: fn (u32, u32) u32, comptime hook: ?ops.ImmHook) void {
    const imm32 = @as(u32, instr.i.imm);
    iRetire(cpu, instr, imm32, op(cpu.readReg(instr.i.rs), imm32), hook);
}

inline fn iOpSignExt(cpu: *Cpu, instr: Instruction, comptime op: fn (u32, u32) u32, comptime hook: ?ops.ImmHook) void {
    const imm32 = signExtend16(instr.i.imm);
    iRetire(cpu, instr, imm32, op(cpu.readReg(instr.i.rs), imm32), hook);
}

inline fn iOpChecked(cpu: *Cpu, instr: Instruction, comptime op: fn (u32, u32) ?u32, comptime hook: ?ops.ImmHook) void {
    const imm32 = signExtend16(instr.i.imm);
    if (op(cpu.readReg(instr.i.rs), imm32)) |result| {
        iRetire(cpu, instr, imm32, result, hook);
    } else {
        cpu.exception(.ArithmeticOverflow, 0);
    }
}

fn opLui(cpu: *Cpu, instr: Instruction) void {
    const imm32 = @as(u32, instr.i.imm);
    iRetire(cpu, instr, imm32, imm32 << 16, &ops.exact);
}

fn opCop(cpu: *Cpu, instr: Instruction, comptime cop_num: u2) void {
    const sr = cpu.cop0.readReg(.sr);
    const cu = (sr >> 28) & 0xF;

    // COP0 is always usable in Kernel Mode (Bits 1-2 of SR are 0)
    const is_kernel = (sr & 0x2) == 0;
    const cop0_usable = (cop_num == 0) and is_kernel;
    const cop_usable = (cu & (@as(u32, 1) << cop_num)) != 0;

    if (!cop0_usable and !cop_usable) {
        cpu.exception(.CoprocessorUnusable, cop_num);
        return;
    }

    if (cop_num == 1 or cop_num == 3) {
        // Unimplemented but "usable" cops are NOPs
        return;
    }

    const sub_op = instr.r.rs; // rs field is used for sub-op in COP instructions
    const rt = instr.r.rt;
    const rd = instr.r.rd;

    switch (sub_op) {
        0x00 => { // MFCn
            const value = switch (cop_num) {
                0 => cpu.cop0.readReg(rd),
                2 => cpu.cop2.readData(rd),
                else => unreachable,
            };
            if (cop_num == 2 and cpu.bus.pgxp_enabled) {
                cpu.writeRegPrecise(rt, value, cpu.cop2.readPreciseData(rd));
            } else {
                cpu.writeReg(rt, value);
                if (cop_num == 0 and cpuMode(cpu)) muldiv.mfc0(cpu, rt, rd);
            }
        },
        0x02 => { // CFCn
            const value = switch (cop_num) {
                0 => {
                    std.log.warn("CFC0 is not supported", .{});
                    return cpu.exception(.ReservedInstruction, 0);
                },
                2 => cpu.cop2.readCtrl(rd),
                else => unreachable,
            };
            cpu.writeReg(rt, value);
        },
        0x04 => { // MTCn
            const value = cpu.readReg(rt);
            switch (cop_num) {
                0 => {
                    if (rd == 12) { // Status register
                        const old_status = cpu.cop0.readReg(.sr);
                        const old_isc = (old_status & (1 << 16)) != 0;
                        const new_isc = (value & (1 << 16)) != 0;
                        if (new_isc and !old_isc) {
                            // Isolate Cache enabled: invalidate entire I-cache to mimic BIOS flush
                            icache.flush(cpu);
                        }
                    }
                    cpu.cop0.writeReg(rd, value);
                    if (cpuMode(cpu)) muldiv.mtc0(cpu, rd, rt);
                },
                2 => {
                    if (cpu.bus.pgxp_enabled) {
                        cpu.cop2.writeDataPrecise(rd, value, cpu.gpr_shadow[cpu.getIdx(rt)]);
                    } else {
                        cpu.cop2.writeData(rd, value);
                    }
                },
                else => unreachable,
            }
        },
        0x06 => { // CTCn
            const value = cpu.readReg(rt);
            switch (cop_num) {
                0 => {
                    std.log.warn("CTC0 is not supported", .{});
                    return cpu.exception(.ReservedInstruction, 0);
                },
                2 => cpu.cop2.writeCtrl(rd, value),
                else => unreachable,
            }
        },
        0x10...0x1F => {
            if (cop_num == 2) {
                cpu.cop2.executeCommand(instr.raw, cpu.bus.pgxpConfig());
            } else {
                // For COP0, 0x10...0x1F are CO functions
                const funct = instr.r.funct;
                if (funct == 0x10) {
                    cpu.cop0.rfe();
                } else {
                    // Unrecognised COP0 functions are NOPs on real hardware
                }
            }
        },
        else => {
            std.log.warn("Unhandled COP{} sub-op: 0x{x:0>2}", .{ cop_num, sub_op });
            cpu.exception(.ReservedInstruction, 0);
        },
    }
}

/// The shadow a load issues beside its value (`Cpu.load_shadow`). A byte
/// cannot carry a coordinate, so `.Byte` keeps nothing. A half-word can:
/// the addressed half becomes the register's low half, which is the other
/// end of the `sh` idiom in `storeShadow`. The JIT's inline loads call it
/// too (`recompiler/arm64/shadow.zig`).
pub inline fn loadShadow(cpu: *Cpu, address: u32, ltype: LoadType, value: u32, signed: bool) Value {
    return switch (ltype) {
        .Word => cpu.bus.shadowLoad(address),
        .Half => cpu.bus.shadowLoadHalf(address, value, signed),
        .Byte => Value.none,
    };
}

inline fn opLoad(cpu: *Cpu, instr: Instruction, comptime ltype: LoadType, comptime signed: bool) void {
    const address = effectiveAddress(cpu, instr);

    // One address is exempt from the word check: `cpu/io-access-bitwidth`
    // word-loads SIO_CTRL at 0x1F80105A and expects the spoofed 0xC0C00000
    // back rather than an exception (the golden's own fixup in
    // `jaczekanski_test.zig` pins that expectation).
    const sio_ctrl_exempt = ltype == .Word and (address & 0x1FFFFFFF) == 0x1F80105A;
    if (address & alignMask(ltype) != 0 and !sio_ctrl_exempt) {
        addressError(cpu, address, .LoadAddressError);
        return;
    }

    // Read from memory. For IO, this might return unmasked words.
    const raw_val: u32 = switch (ltype) {
        .Word => cpu.bus.read32(address),
        .Half => cpu.bus.read16Raw(address),
        .Byte => cpu.bus.read8Raw(address),
    };

    // Sign or Zero Extend. If raw_val was unmasked, it stays unmasked for zero-extension!
    const final_val = if (signed) switch (ltype) {
        .Word => raw_val,
        .Half => signExtend16(@as(u16, @truncate(raw_val))),
        .Byte => signExtend8(@as(u8, @truncate(raw_val))),
    } else raw_val;

    // Put the result in the Load Delay queue, NOT directly into the register
    cpu.load_delay.load_r = instr.i.rt;
    cpu.load_delay.load_v = final_val;
    cpu.load_shadow = loadShadow(cpu, address, ltype, final_val, signed);
}

inline fn opUnalignedLoad(cpu: *Cpu, instr: Instruction, comptime ul_type: UnalignedLoadType) void {
    const address = effectiveAddress(cpu, instr);

    // Always read the floor aligned word (masking out the bottom 2 bits)
    const aligned_addr = address & ~@as(u32, 3);
    const mem = cpu.bus.read32(aligned_addr);

    // Load Delay Bypass: Merge with the incoming load if targeting the same register!
    const current_val = if (cpu.load_delay.delay_r == instr.i.rt) cpu.load_delay.delay_v else cpu.readReg(instr.i.rt);
    const shift_idx = address & 3;

    const merged = switch (ul_type) {
        .Left => blk: {
            const shifts = [_]u5{ 24, 16, 8, 0 };
            const masks = [_]u32{ 0x00FFFFFF, 0x0000FFFF, 0x000000FF, 0x00000000 };
            break :blk (current_val & masks[shift_idx]) | (mem << shifts[shift_idx]);
        },
        .Right => blk: {
            const shifts = [_]u5{ 0, 8, 16, 24 };
            const masks = [_]u32{ 0x00000000, 0xFF000000, 0xFFFF0000, 0xFFFFFF00 };
            break :blk (current_val & masks[shift_idx]) | (mem >> shifts[shift_idx]);
        },
    };

    // Enqueue the newly merged value into the load delay slot
    cpu.load_delay.load_r = instr.i.rt;
    cpu.load_delay.load_v = merged;
}

/// What a store does to PGXP's shadows, before the store itself. The JIT's
/// inline stores call it too (`recompiler/arm64/shadow.zig`).
pub inline fn storeShadow(cpu: *Cpu, address: u32, rt: u5, stype: StoreType) void {
    switch (stype) {
        .Word => {
            const p = cpu.gpr_shadow[rt];
            cpu.bus.shadowStore(address, p);
            // Gated: this runs on every word store in the machine, one of the
            // hottest paths there is, and with PGXP off `p` is always
            // `Value.none` anyway (see `writeReg`/`writeRegPrecise`), so the
            // store would be a guaranteed-no-op write, not a guaranteed skip.
            if (cpu.bus.pgxp_enabled) cpu.bus.pgxp_pending = p;
        },
        // A half-word store carries the register's low half into the addressed
        // half of the destination and leaves the other half alone, which is
        // how a game that keeps its two coordinates in separate registers
        // moves them. It still drops any pending GP0 provenance a PRECEDING
        // `sw` armed: a half-word store to GP0 is not a vertex, and without
        // this it would hand an unrelated register's shadow to whichever GP0
        // word arrives next.
        .Half => {
            cpu.bus.shadowStoreHalf(address, cpu.gpr_shadow[rt]);
            if (cpu.bus.pgxp_enabled) cpu.bus.pgxp_pending = Value.none;
        },
        // A byte store lands inside a tracked word and destroys it — a byte
        // cannot carry a coordinate, so there is nothing to keep. Same GP0
        // provenance reasoning as above.
        .Byte => {
            cpu.bus.shadowInvalidate(address);
            if (cpu.bus.pgxp_enabled) cpu.bus.pgxp_pending = Value.none;
        },
    }
}

inline fn opStore(cpu: *Cpu, instr: Instruction, comptime stype: StoreType) void {
    const address = effectiveAddress(cpu, instr);

    if (address & alignMask(stype) != 0) {
        addressError(cpu, address, .StoreAddressError);
        return;
    }

    if (cpu.isCacheIsolated(address)) {
        return; // Drop the write
    }

    const value = cpu.readReg(instr.i.rt);
    storeShadow(cpu, address, instr.i.rt, stype);
    switch (stype) {
        .Word => cpu.bus.writeCpuStore(u32, address, value),
        .Half => cpu.bus.writeCpuStore(u16, address, value),
        .Byte => cpu.bus.writeCpuStore(u8, address, value),
    }
}

inline fn opUnalignedStore(cpu: *Cpu, instr: Instruction, comptime us_type: UnalignedStoreType) void {
    const address = effectiveAddress(cpu, instr);

    if (cpu.isCacheIsolated(address)) {
        return; // Drop the write
    }

    const aligned_addr = address & ~@as(u32, 3);
    const mem = cpu.bus.read32(aligned_addr);
    const val = cpu.readReg(instr.i.rt);
    const shift_idx = address & 3;

    // Mask out the part of memory we are overwriting, and OR in the shifted register value
    const merged = switch (us_type) {
        .Left => blk: {
            const shifts = [_]u5{ 24, 16, 8, 0 };
            const masks = [_]u32{ 0xFFFFFF00, 0xFFFF0000, 0xFF000000, 0x00000000 };
            break :blk (mem & masks[shift_idx]) | (val >> shifts[shift_idx]);
        },
        .Right => blk: {
            const shifts = [_]u5{ 0, 8, 16, 24 };
            const masks = [_]u32{ 0x00000000, 0x000000FF, 0x0000FFFF, 0x00FFFFFF };
            break :blk (mem & masks[shift_idx]) | (val << shifts[shift_idx]);
        },
    };

    if (cpu.bus.pgxp_enabled) {
        // Which bytes of the destination word this store actually overwrites.
        // A half none of them reach keeps its shadow; the usual case, where
        // both halves are touched, is the whole-word invalidation this always
        // was. These forms are rare, so the partial case stays conservative —
        // a half is kept only when it is untouched entire.
        const written: u32 = switch (us_type) {
            .Left => ([_]u32{ 0x0000_00FF, 0x0000_FFFF, 0x00FF_FFFF, 0xFFFF_FFFF })[shift_idx],
            .Right => ([_]u32{ 0xFFFF_FFFF, 0xFFFF_FF00, 0xFFFF_0000, 0xFF00_0000 })[shift_idx],
        };
        const hits_low = written & 0x0000_FFFF != 0;
        const hits_high = written & 0xFFFF_0000 != 0;
        if (hits_low and hits_high) {
            cpu.bus.shadowInvalidate(aligned_addr);
        } else {
            var p = cpu.bus.shadowLoad(aligned_addr);
            p.flags &= ~(if (hits_low) Value.valid_x else Value.valid_y);
            // The depth term describes the whole word and half of it just
            // moved, so it goes with the half that moved rather than being
            // re-attributed to the survivor.
            p.flags &= ~(Value.valid_z | Value.low_z | Value.high_z);
            // The surviving half's integer is untouched by construction, so
            // re-recording against the merged word keeps it valid rather than
            // stranding it against a word memory no longer holds.
            p.word = merged;
            cpu.bus.shadowMergeWord(aligned_addr, p);
        }
        // Same reasoning as opStore's sub-word arms: an unaligned store must
        // not let a preceding sw's GP0 provenance survive onto this word.
        cpu.bus.pgxp_pending = Value.none;
    }
    cpu.bus.write32(aligned_addr, merged);
}

inline fn opLwc(cpu: *Cpu, instr: Instruction, comptime cop_num: u2) void {
    const sr = cpu.cop0.readReg(.sr);
    const cu = (sr >> 28) & 0xF;
    const cop_usable = (cu & (@as(u32, 1) << cop_num)) != 0;

    if (!cop_usable) {
        cpu.exception(.CoprocessorUnusable, cop_num);
        return;
    }

    if (cop_num != 2) {
        // LWC0/1/3 are NOPs if usable
        return;
    }

    const address = effectiveAddress(cpu, instr);

    if (address & 3 != 0) {
        addressError(cpu, address, .LoadAddressError);
        return;
    }

    // Read from Bus, Write directly to GTE Data Register.
    //
    // The shadow lookup is the `lwc2` half of `writeDataPrecise`'s reason for
    // existing: libgte's `gte_ldsxy*` macros are an `lwc2` of a cached vertex,
    // and without this the sub-pixel is lost on the way back into the GTE.
    const raw_val = cpu.bus.read32(address);
    if (cpu.bus.pgxp_enabled) {
        cpu.cop2.writeDataPrecise(instr.i.rt, raw_val, cpu.bus.shadowLoad(address));
    } else {
        cpu.cop2.writeData(instr.i.rt, raw_val);
    }
}

inline fn opSwc(cpu: *Cpu, instr: Instruction, comptime cop_num: u2) void {
    const sr = cpu.cop0.readReg(.sr);
    const cu = (sr >> 28) & 0xF;
    const cop_usable = (cu & (@as(u32, 1) << cop_num)) != 0;

    if (!cop_usable) {
        cpu.exception(.CoprocessorUnusable, cop_num);
        return;
    }

    if (cop_num != 2) {
        // SWC0/1/3 are NOPs if usable
        return;
    }

    const address = effectiveAddress(cpu, instr);

    if (address & 3 != 0) {
        addressError(cpu, address, .StoreAddressError);
        return;
    }

    if (cpu.isCacheIsolated(address)) {
        return;
    }

    // Read from GTE Data Register, Write to Bus.
    //
    // This is the commonest way a real game moves a projected vertex: libgte's
    // `gte_stsxy*` macros are `swc2` of SXY0/1/2 straight into a display-list
    // primitive. So it carries the register's precise half, exactly as MFC2
    // does. A register that holds nothing carries `Value.none`, which also
    // stops a preceding `sw`'s pending provenance attaching itself to an
    // unrelated GTE store.
    //
    // Both halves are needed. `pgxp_pending` covers a store aimed straight at
    // GP0; `shadowStore` covers the ordinary case, where the primitive sits in
    // RAM until `DrawOTag` DMAs it a frame later and `dma.zig` reads the
    // shadow back out.
    const cop_val = cpu.cop2.readData(instr.i.rt);
    const p = if (cpu.bus.pgxp_enabled) cpu.cop2.readPreciseData(instr.i.rt) else Value.none;
    cpu.bus.shadowStore(address, p);
    if (cpu.bus.pgxp_enabled) cpu.bus.pgxp_pending = p;
    cpu.bus.write32(address, cop_val);
}
