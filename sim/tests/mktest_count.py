#!/usr/bin/env python3
"""Count-rate test ROM: zero Count, then loop reading it (mfc0 r1,$9) forever."""
import struct, sys
mtc0_r0_9 = (0x10 << 26) | (4 << 21) | (0 << 16) | (9 << 11)
mfc0_r1_9 = (0x10 << 26) | (0 << 21) | (1 << 16) | (9 << 11)
addiu_r2  = (0x09 << 26) | (2 << 21) | (2 << 16) | 1
b_back    = (0x04 << 26) | ((-3) & 0xffff)      # beq r0,r0,-3 -> mfc0
p = [mtc0_r0_9, 0, 0, mfc0_r1_9, addiu_r2, b_back, 0]
rom = bytearray(2 * 1024 * 1024)
for i, w in enumerate(p):
    rom[4 * i:4 * i + 4] = struct.pack('>I', w)
open(sys.argv[1], 'wb').write(rom)
