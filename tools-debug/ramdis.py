#!/usr/bin/env python3
"""Disassemble MIPS out of a raw 2MB PS1 RAM dump (ps1-trace's PS1_RAM_DUMP=1).

usage: ramdis.py <ram.bin> <vaddr> [count]
"""
import sys, struct, re, os
src = open(os.path.join(os.path.dirname(__file__), "mipsdis.py")).read()
src = re.sub(r"^main\(\)\s*$", "", src, flags=re.M)
ns = {"__name__": "ramdis"}
exec(compile(src, "mipsdis.py", "exec"), ns)
dis = ns["dis"]

ram = open(sys.argv[1], "rb").read()
va = int(sys.argv[2], 16)
count = int(sys.argv[3]) if len(sys.argv) > 3 else 32
for k in range(count):
    pc = va + 4 * k
    off = pc & 0x1FFFFF
    w = struct.unpack("<I", ram[off:off + 4])[0]
    print("%08x: %08x  %s" % (pc, w, dis(w, pc)))
