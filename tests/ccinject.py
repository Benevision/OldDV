#!/usr/bin/env python3
"""ccinject.py IN.dv OUT.dv : adds EIA-608 captions (VAUX pack 0x65) to an NTSC DV file.
Pop-on captions in field 1, a roll-up caption in field 2."""
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
F = 120000
n = len(d) // F
def par(b):
    return b | (0x80 if bin(b).count('1') % 2 == 0 else 0)
def text(s):
    b = [ord(c) for c in s]
    if len(b) % 2: b.append(0)
    return [(b[i], b[i + 1]) for i in range(0, len(b), 2)]
def popon(lines):
    p = [(0x14, 0x20)] * 2 + [(0x14, 0x2E)] * 2
    for row, s in lines:
        p += [row] * 2 + text(s)
    return p + [(0x14, 0x2F)] * 2
R14, R15 = (0x14, 0x40), (0x14, 0x60)
f1 = {}
def at(tbl, frame, pairs):
    for i, pr in enumerate(pairs):
        tbl[frame + i] = pr
at(f1, 20, popon([(R14, "HELLO THERE"), (R15, "SECOND LINE")]))
at(f1, 80, [(0x14, 0x2C)] * 2)
at(f1, 100, popon([(R15, "CAF"), ]) [:-2] + [(0x65, 0x00), (0x12, 0x21), (0x12, 0x21)] + [(0x14, 0x2F)] * 2)
at(f1, 150, [(0x14, 0x2C)] * 2)
f2 = {}
at(f2, 10, [(0x15, 0x25)] * 2 + [(0x15, 0x60)] * 2 + text("ROLL ONE") + [(0x15, 0x2D)] * 2 + text("ROLL TWO") + [(0x15, 0x2D)] * 2)
at(f2, 120, [(0x15, 0x2C)] * 2)
for fr in range(n):
    a = f1.get(fr, (0, 0)); b = f2.get(fr, (0, 0))
    pack = bytes([0x65, par(a[0]), par(a[1]), par(b[0]), par(b[1])])
    for seq in range(10):
        done = False
        for blk in range(150):
            o = fr * F + seq * 12000 + blk * 80
            if d[o] >> 5 != 2: continue
            for p in range(15):
                q = o + 3 + p * 5
                if d[q] == 0xFF and not done:
                    d[q:q + 5] = pack; done = True
open(sys.argv[2], 'wb').write(d)
