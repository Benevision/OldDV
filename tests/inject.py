#!/usr/bin/env python3
"""Create damaged DV files for testing OldDV Rescue.

usage: inject.py INPUT.dv OUTPUT.dv SEED [--clean]

Applies a random mix of the problems seen on real tapes: concealed video
blocks (STA), audio error codes, time code jumps / repeats, recording date
jumps, recording starts, dropped / repeated / truncated frames and frames
without auxiliary data. --clean only copies, so that two "takes" with
different damage can be generated from the same source for merge tests.
"""
import random
import sys


def frames_of(data):
    starts = []
    for off in range(0, len(data) - 79, 80):
        b = data[off:off + 3]
        if (b[0] & 0xE0) == 0 and b != b"\0\0\0" and (b[1] & 0xF0) == 0 and b[2] == 0 \
                and not (b[1] & 0x08) and (b[1] & 0x04):
            starts.append(off)
    starts.append(len(data))
    return [bytearray(data[starts[i]:starts[i + 1]]) for i in range(len(starts) - 1)]


def blocks(fr, sct):
    return [o for o in range(0, len(fr) - 79, 80) if (fr[o] & 0xE0) == sct]


def bcd(v):
    return ((v // 10) << 4) | (v % 10)


def set_tc(fr, h, m, s, f):
    for o in blocks(fr, 0x20):
        for p in range(0, 48, 8):
            pk = o + 3 + p + 3
            if fr[pk] == 0x13:
                fr[pk + 1] = (fr[pk + 1] & 0xC0) | bcd(f)
                fr[pk + 2] = (fr[pk + 2] & 0x80) | bcd(s)
                fr[pk + 3] = (fr[pk + 3] & 0x80) | bcd(m)
                fr[pk + 4] = (fr[pk + 4] & 0xC0) | bcd(h)


def set_rectime(fr, h, m, s):
    def patch(pk):
        fr[pk + 2] = (fr[pk + 2] & 0x80) | bcd(s)
        fr[pk + 3] = (fr[pk + 3] & 0x80) | bcd(m)
        fr[pk + 4] = (fr[pk + 4] & 0xC0) | bcd(h)
    for o in blocks(fr, 0x40):
        for i in range(15):
            if fr[o + 3 + i * 5] == 0x63:
                patch(o + 3 + i * 5)
    for o in blocks(fr, 0x20):
        for p in range(0, 48, 8):
            if fr[o + 3 + p + 3] == 0x63:
                patch(o + 3 + p + 3)
    for o in blocks(fr, 0x60):
        if fr[o + 3] == 0x53:
            patch(o + 3)


def damage(fr, rnd, kind):
    if kind == "sta":
        vb = blocks(fr, 0x80)
        val = rnd.choice([0x2, 0x4, 0x7, 0xA, 0xA, 0xF])
        start = rnd.randrange(len(vb))
        for o in vb[start:start + rnd.randint(1, 400)]:
            fr[o + 3] = (val << 4) | (fr[o + 3] & 0x0F)
    elif kind == "conceal":
        for o in blocks(fr, 0x80):
            fr[o + 3] = 0xA0 | (fr[o + 3] & 0x0F)
    elif kind == "audio":
        ab = blocks(fr, 0x60)
        start = rnd.randrange(len(ab))
        val = rnd.choice([b"\x80\x00", b"\x80\x00", b"\x12\x34"])
        for o in ab[start:start + rnd.randint(1, 40)]:
            fr[o + 8:o + 80] = val * 36
    elif kind == "audio_all":
        for o in blocks(fr, 0x60):
            fr[o + 8:o + 80] = b"\x80\x00" * 36
    elif kind == "recstart":
        for o in blocks(fr, 0x60):
            if fr[o + 3] == 0x51:
                fr[o + 5] &= 0x7F
    elif kind == "noaux":
        for o in blocks(fr, 0x40):
            fr[o + 3:o + 80] = b"\xff" * 77
    elif kind == "noaudpack":
        for o in blocks(fr, 0x60):
            fr[o + 3:o + 8] = b"\xff" * 5
    elif kind == "truncate":
        del fr[len(fr) - 80 * rnd.randint(1, 900):]


def main():
    src, dst, seed = sys.argv[1], sys.argv[2], int(sys.argv[3])
    clean = "--clean" in sys.argv
    rnd = random.Random(seed)
    frs = frames_of(open(src, "rb").read())
    out = []
    i = 0
    while i < len(frs):
        fr = frs[i]
        if not clean:
            r = rnd.random()
            if r < 0.02 and i > 2:
                i += rnd.randint(1, 5)  # dropped frames
                continue
            if r < 0.04:
                out.append(bytearray(fr))  # repeated frame
            for kind in ("sta", "conceal", "audio", "audio_all", "recstart", "noaux", "noaudpack", "truncate"):
                p = {"sta": 0.15, "audio": 0.08, "conceal": 0.02, "audio_all": 0.02, "recstart": 0.02,
                     "noaux": 0.02, "noaudpack": 0.02, "truncate": 0.01}[kind]
                if rnd.random() < p:
                    damage(fr, rnd, kind)
            if rnd.random() < 0.02:
                set_tc(fr, rnd.randint(0, 2), rnd.randint(0, 59), rnd.randint(0, 59), rnd.randint(0, 24))
            if rnd.random() < 0.02:
                set_rectime(fr, rnd.randint(0, 23), rnd.randint(0, 59), rnd.randint(0, 59))
        out.append(fr)
        i += 1
    with open(dst, "wb") as f:
        for fr in out:
            f.write(fr)


if __name__ == "__main__":
    main()
