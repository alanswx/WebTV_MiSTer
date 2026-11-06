#!/usr/bin/env python3
"""Tiny boot-ROM test for the R4640 SPECIAL2 ops (MUL/MAD/MADU) and their hazards.
Writes a 2 MB ROM image; run it in the JS model and the RTL and compare traces."""
import struct, sys

def R(op, rs, rt, rd, sh, fn): return (op << 26) | (rs << 21) | (rt << 16) | (rd << 11) | (sh << 6) | fn
def I(op, rs, rt, imm): return (op << 26) | (rs << 21) | (rt << 16) | (imm & 0xffff)
lui   = lambda rt, i: I(0x0f, 0, rt, i)
ori   = lambda rt, rs, i: I(0x0d, rs, rt, i)
addiu = lambda rt, rs, i: I(0x09, rs, rt, i)
addu  = lambda rd, rs, rt: R(0, rs, rt, rd, 0, 0x21)
mul   = lambda rd, rs, rt: R(0x1c, rs, rt, rd, 0, 2)
mad   = lambda rs, rt: R(0x1c, rs, rt, 0, 0, 0)
madu  = lambda rs, rt: R(0x1c, rs, rt, 0, 0, 1)
mult  = lambda rs, rt: R(0, rs, rt, 0, 0, 0x18)
mfhi  = lambda rd: R(0, 0, 0, rd, 0, 0x10)
mflo  = lambda rd: R(0, 0, 0, rd, 0, 0x12)
mthi  = lambda rs: R(0, rs, 0, 0, 0, 0x11)
mtlo  = lambda rs: R(0, rs, 0, 0, 0, 0x13)
bne   = lambda rs, rt, off: I(0x05, rs, rt, off)
beq   = lambda rs, rt, off: I(0x04, rs, rt, off)
nop = 0

p = [
    lui(1, 0x1234), ori(1, 1, 0x5678),
    lui(2, 0xffff), ori(2, 2, 0xfff3),           # -13
    lui(11, 0x8000), ori(11, 11, 0x0001),
    mul(3, 1, 2),                                # rd only
    addu(4, 3, 1),                               # forward from MUL
    mul(5, 3, 1), mul(6, 5, 5),                  # dependent chain
    mtlo(1), mthi(2),
    mad(1, 2),                                   # HI:LO += 
    mfhi(7), mflo(8),
    madu(11, 11), madu(2, 2),                    # unsigned, carries
    mfhi(9), mflo(10),
    mult(1, 1), mul(12, 2, 2), mfhi(13), mflo(14), # MUL must leave HI/LO alone
    mad(11, 2), mul(15, 11, 11), addu(16, 15, 15), mfhi(17), mflo(18),
    addiu(20, 20, 1), addiu(21, 0, 5), bne(20, 21, (-(30) & 0xffff)), nop,   # loop a few times
    beq(0, 0, 0xffff), nop,
]
# fix the loop branch to jump back to the start (index 0) from its position
idx = p.index(bne(20, 21, (-(30) & 0xffff)))
p[idx] = bne(20, 21, (-(idx + 1)) & 0xffff)
rom = bytearray(2 * 1024 * 1024)
for i, w in enumerate(p):
    rom[4 * i:4 * i + 4] = struct.pack('>I', w)
open(sys.argv[1], 'wb').write(rom)
print(f'{len(p)} instructions -> {sys.argv[1]}')
