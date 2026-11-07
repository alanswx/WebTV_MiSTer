#!/usr/bin/env python3
"""Where is the WebTV box's CPU spending its time? (run on the MiSTer while the core is loaded)

The core samples the retiring PC every millisecond into a DDR3 ring (1024 entries at 0x30FA4000,
each {sample number, PC}). This names the samples with the OS's own symbol table, which debug
builds keep in RAM (the boot log says "Symbol file @ 0x80708590, len = 340971"), and prints a
histogram of the functions -- e.g. to see what a hung box is spinning in.

usage: pcsample.py [--last N] [--syms ADDR LEN] [--raw]
"""
import argparse, bisect, mmap, os, re, struct

RAM = 0x30000000            # box physical 0 in DDR3
RING = 0x30FA4000


def mem(fd, addr, size):
    base = addr & ~0xFFF
    m = mmap.mmap(fd, size + (addr - base), mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    return m[addr - base:addr - base + size]


def find_symfile():
    for path in ('/tmp/webtv_modem.log', '/tmp/webtv_modem.log.1'):
        try:
            text = open(path, encoding='latin-1').read()
        except OSError:
            continue
        m = re.findall(r'Symbol file @ 0x([0-9a-fA-F]+), len = (\d+)', text)
        if m:
            return int(m[-1][0], 16), int(m[-1][1])
    return 0x80708590, 340971


def load_symbols(fd, addr, ln):
    blob = mem(fd, RAM + (addr & 0x7FFFFF), ln)
    p, syms = 0, []
    while p + 4 < len(blob):
        a = struct.unpack('>I', blob[p:p + 4])[0]
        p += 4
        e = blob.find(b'\0', p)
        if e < 0:
            break
        syms.append((a, blob[p:e].decode('latin-1')))
        p = e + 1
    syms.sort()
    return syms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--last', type=int, default=1000, help='samples to use (max 1024)')
    ap.add_argument('--syms', nargs=2, metavar=('ADDR', 'LEN'), help='symbol table in box RAM (hex addr, length)')
    ap.add_argument('--raw', action='store_true', help='also list the samples, newest last')
    a = ap.parse_args()
    fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
    ring = mem(fd, RING, 1024 * 8)
    ent = []
    for i in range(1024):
        v = struct.unpack('<Q', ring[i * 8:i * 8 + 8])[0]
        ent.append((v >> 32, v & 0xFFFFFFFF))
    ent = [e for e in ent if e[1]]
    ent.sort()
    ent = ent[-min(a.last, 1024):]
    if not ent:
        print('no samples (is the WebTV core running?)')
        return
    sa, sl = (int(a.syms[0], 16), int(a.syms[1])) if a.syms else find_symfile()
    syms = load_symbols(fd, sa, sl)
    addrs = [s[0] for s in syms]

    def name(pc):
        i = bisect.bisect_right(addrs, pc) - 1
        return (syms[i][1], pc - syms[i][0]) if i >= 0 and pc - syms[i][0] < 0x10000 else (f'{pc:08x}', 0)

    hist = {}
    for _, pc in ent:
        n = name(pc)[0]
        hist[n] = hist.get(n, 0) + 1
    print(f'{len(ent)} samples (#{ent[0][0]}..#{ent[-1][0]}), {len(syms)} symbols')
    for n, c in sorted(hist.items(), key=lambda x: -x[1])[:25]:
        print(f'{100 * c / len(ent):5.1f}%  {c:5d}  {n}')
    if a.raw:
        for seq, pc in ent:
            n, off = name(pc)
            print(f'#{seq} {pc:08x} {n}+{off:x}')


if __name__ == '__main__':
    main()
