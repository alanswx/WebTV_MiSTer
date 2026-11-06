#!/usr/bin/env python3
"""Compare an RTL trace with the JS reference trace (sim/trace.mjs format).

usage: python3 -I sim/compare.py REF(.gz) RTL [--context N] [--ignore-count]

Both traces list, per retired instruction: index pc op and the registers it changed.
Compares pc/op and the GPR/HI/LO values; reports the first mismatch with context.
CP0/FPU fields and MMIO accesses are shown but only GPR/HI/LO/pc/op are compared
(the RTL export doesn't carry CP0 diffs in the same form).
"""
import gzip
import sys
from collections import deque


def parse(line):
    f = line.split()
    if len(f) < 3:
        return None
    rec = {'idx': f[0], 'pc': f[1], 'op': f[2], 'regs': {}, 'extra': []}
    for t in f[3:]:
        if '=' in t and (t[0] == 'r' or t.startswith('hi=') or t.startswith('lo=')) and not t.startswith('MR'):
            k, v = t.split('=', 1)
            rec['regs'][k] = v
        else:
            rec['extra'].append(t)
    return rec


def open_any(p):
    return gzip.open(p, 'rt') if p.endswith('.gz') else open(p)


def main():
    a = sys.argv[1:]
    ctx = int(a[a.index('--context') + 1]) if '--context' in a else 8
    ref_p, rtl_p = a[0], a[1]
    hist = deque(maxlen=ctx)
    state_ref, state_rtl = {}, {}
    if '--snap' in a:  # seed both with the snapshot's registers (ss.txt from sim/trace.mjs)
        for ln in open(a[a.index('--snap') + 1]):
            k, v = ln.split()
            k = int(k)
            name = {3: 'hi', 4: 'lo'}.get(k, f'r{k - 32}' if 33 <= k < 64 else None)
            if name:
                state_ref[name] = state_rtl[name] = v
    n = 0
    with open_any(ref_p) as fr, open_any(rtl_p) as ft:
        for lr, lt in zip(fr, ft):
            r, t = parse(lr), parse(lt)
            if r is None or t is None:
                break
            state_ref.update(r['regs'])
            state_rtl.update(t['regs'])
            bad = []
            if n > 0 and (r['pc'] != t['pc'] or r['op'] != t['op']):
                bad.append(f"pc/op ref {r['pc']} {r['op']}  rtl {t['pc']} {t['op']}")
            for k in set(state_ref) | set(state_rtl):
                if state_ref.get(k, '0' * 16) != state_rtl.get(k, '0' * 16):
                    bad.append(f"{k}: ref {state_ref.get(k)} rtl {state_rtl.get(k)}")
            if bad:
                print(f"MISMATCH at instruction {n}:")
                for h in hist:
                    print('   ' + h)
                print(' R ' + lr.rstrip())
                print(' T ' + lt.rstrip())
                for b in bad:
                    print('   ' + b)
                nxt_r = [fr.readline().rstrip() for _ in range(3)]
                print('next ref:', *nxt_r, sep='\n   ')
                return 1
            hist.append(lr.rstrip())
            n += 1
    print(f"OK: {n} instructions match")
    return 0


if __name__ == '__main__':
    sys.exit(main())
