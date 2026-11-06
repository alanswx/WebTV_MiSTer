#!/usr/bin/env python3
"""Compare two 640x480 P6 PPMs; print the number of differing pixels and write a diff PNG
(differences in red over a dimmed copy of the reference)."""
import struct
import sys
import zlib


def load(p):
    d = open(p, 'rb').read()
    assert d[:2] == b'P6'
    parts = d.split(b'\n', 3)
    return parts[3]


def png(path, w, h, rgb):
    raw = b''.join(b'\x00' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    ch = lambda t, b: struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                           ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))


a, b = load(sys.argv[1]), load(sys.argv[2])
w, h = 640, 480
out = bytearray(w * h * 3)
bad = 0
first = None
for i in range(w * h):
    pa, pb = a[3 * i:3 * i + 3], b[3 * i:3 * i + 3]
    if pa != pb:
        bad += 1
        if first is None:
            first = (i % w, i // w, pa.hex(), pb.hex())
        out[3 * i:3 * i + 3] = b'\xff\x00\x00'
    else:
        out[3 * i:3 * i + 3] = bytes(v // 3 for v in pa)
if len(sys.argv) > 3:
    png(sys.argv[3], w, h, bytes(out))
print(f"{bad} of {w * h} pixels differ" + (f"; first at x={first[0]} y={first[1]} js={first[2]} rtl={first[3]}" if first else " (exact match)"))
