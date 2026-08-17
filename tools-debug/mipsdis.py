#!/usr/bin/env python3
"""Minimal R3000A (MIPS I) disassembler for PS-EXE images.

usage: mipsdis.py <exe> <vaddr> [count]
"""
import struct
import sys

R = ["zero", "at", "v0", "v1", "a0", "a1", "a2", "a3",
     "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
     "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7",
     "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra"]

SPECIAL = {0x00: "sll", 0x02: "srl", 0x03: "sra", 0x04: "sllv", 0x06: "srlv",
           0x07: "srav", 0x08: "jr", 0x09: "jalr", 0x0c: "syscall", 0x0d: "break",
           0x10: "mfhi", 0x11: "mthi", 0x12: "mflo", 0x13: "mtlo",
           0x18: "mult", 0x19: "multu", 0x1a: "div", 0x1b: "divu",
           0x20: "add", 0x21: "addu", 0x22: "sub", 0x23: "subu",
           0x24: "and", 0x25: "or", 0x26: "xor", 0x27: "nor",
           0x2a: "slt", 0x2b: "sltu"}

OPS = {0x02: "j", 0x03: "jal", 0x04: "beq", 0x05: "bne", 0x06: "blez", 0x07: "bgtz",
       0x08: "addi", 0x09: "addiu", 0x0a: "slti", 0x0b: "sltiu", 0x0c: "andi",
       0x0d: "ori", 0x0e: "xori", 0x0f: "lui",
       0x20: "lb", 0x21: "lh", 0x22: "lwl", 0x23: "lw", 0x24: "lbu", 0x25: "lhu",
       0x26: "lwr", 0x28: "sb", 0x29: "sh", 0x2a: "swl", 0x2b: "sw", 0x2e: "swr",
       0x32: "lwc2", 0x3a: "swc2"}

LOADSTORE = {0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x28, 0x29, 0x2a, 0x2b, 0x2e,
             0x32, 0x3a}


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def dis(w, pc):
    op = w >> 26
    rs, rt, rd = (w >> 21) & 31, (w >> 16) & 31, (w >> 11) & 31
    sa, fn, imm = (w >> 6) & 31, w & 63, w & 0xFFFF
    tgt = (pc + 4 & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
    br = pc + 4 + (s16(imm) << 2)

    if w == 0:
        return "nop"
    if op == 0:
        m = SPECIAL.get(fn)
        if m is None:
            return ".word 0x%08x" % w
        if m in ("sll", "srl", "sra"):
            return "%-7s %s, %s, %d" % (m, R[rd], R[rt], sa)
        if m in ("sllv", "srlv", "srav"):
            return "%-7s %s, %s, %s" % (m, R[rd], R[rt], R[rs])
        if m == "jr":
            return "jr      %s" % R[rs]
        if m == "jalr":
            return "jalr    %s, %s" % (R[rd], R[rs])
        if m in ("syscall", "break"):
            return "%-7s 0x%x" % (m, (w >> 6) & 0xFFFFF)
        if m in ("mfhi", "mflo"):
            return "%-7s %s" % (m, R[rd])
        if m in ("mthi", "mtlo"):
            return "%-7s %s" % (m, R[rs])
        if m in ("mult", "multu", "div", "divu"):
            return "%-7s %s, %s" % (m, R[rs], R[rt])
        return "%-7s %s, %s, %s" % (m, R[rd], R[rs], R[rt])
    if op == 1:
        m = {0: "bltz", 1: "bgez", 16: "bltzal", 17: "bgezal"}.get(rt, "bcondz?")
        return "%-7s %s, 0x%08x" % (m, R[rs], br)
    if op == 0x10:
        if rs == 0:
            return "mfc0    %s, $%d" % (R[rt], rd)
        if rs == 4:
            return "mtc0    %s, $%d" % (R[rt], rd)
        if w & 0x3F == 0x10:
            return "rfe"
        return "cop0    0x%07x" % (w & 0x1FFFFFF)
    if op == 0x12:
        if rs == 0:
            return "mfc2    %s, $%d" % (R[rt], rd)
        if rs == 2:
            return "cfc2    %s, $%d" % (R[rt], rd)
        if rs == 4:
            return "mtc2    %s, $%d" % (R[rt], rd)
        if rs == 6:
            return "ctc2    %s, $%d" % (R[rt], rd)
        return "cop2    0x%07x" % (w & 0x1FFFFFF)

    m = OPS.get(op)
    if m is None:
        return ".word 0x%08x" % w
    if m in ("j", "jal"):
        return "%-7s 0x%08x" % (m, tgt)
    if m in ("beq", "bne"):
        return "%-7s %s, %s, 0x%08x" % (m, R[rs], R[rt], br)
    if m in ("blez", "bgtz"):
        return "%-7s %s, 0x%08x" % (m, R[rs], br)
    if m == "lui":
        return "lui     %s, 0x%04x" % (R[rt], imm)
    if op in LOADSTORE:
        reg = "$%d" % rt if op in (0x32, 0x3a) else R[rt]
        return "%-7s %s, %d(%s)" % (m, reg, s16(imm), R[rs])
    return "%-7s %s, %s, %d" % (m, R[rt], R[rs], s16(imm))


def main():
    path, va = sys.argv[1], int(sys.argv[2], 0)
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 32
    data = open(path, "rb").read()
    t_addr, t_size = struct.unpack("<II", data[0x18:0x20])
    text = data[0x800:0x800 + t_size]
    off = va - t_addr
    for i in range(count):
        o = off + i * 4
        if o < 0 or o + 4 > len(text):
            break
        w = struct.unpack("<I", text[o:o + 4])[0]
        print("%08x: %08x  %s" % (va + i * 4, w, dis(w, va + i * 4)))


main()
