#!/usr/bin/env python3
"""Replace the LC_MAIN load command of an x86_64 Mach-O executable by an
equivalent LC_UNIXTHREAD (rip = entry point), so that it runs on
Mac OS X 10.6 / 10.7 whose kernel and dyld predate LC_MAIN.
The executable must be linked with -e start (crt_start_10_6.c) and enough
header padding (-headerpad 0x1000)."""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_MAIN = 0x80000028
LC_UNIXTHREAD = 0x5
x86_THREAD_STATE64 = 4

def main(path):
    data = bytearray(open(path, "rb").read())
    magic, cputype, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    assert magic == 0xFEEDFACF and cputype == 0x01000007, "not an x86_64 Mach-O"
    off = 32
    cmds = []
    text_vmaddr = None
    first_section_off = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        cmds.append((cmd, bytes(data[off:off + size])))
        if cmd == LC_SEGMENT_64:
            segname = data[off + 8:off + 24].rstrip(b"\0")
            vmaddr, = struct.unpack_from("<Q", data, off + 24)
            nsects, = struct.unpack_from("<I", data, off + 64)
            if segname == b"__TEXT":
                text_vmaddr = vmaddr
            for s in range(nsects):
                so = off + 72 + s * 80
                sect_off, = struct.unpack_from("<I", data, so + 48)
                if sect_off and (first_section_off is None or sect_off < first_section_off):
                    first_section_off = sect_off
        off += size
    new = []
    found = False
    for cmd, raw in cmds:
        if cmd == LC_MAIN:
            entryoff, = struct.unpack_from("<Q", raw, 8)
            regs = [0] * 21
            regs[16] = text_vmaddr + entryoff  # rip
            body = struct.pack("<II", x86_THREAD_STATE64, 42) + struct.pack("<21Q", *regs)
            raw = struct.pack("<II", LC_UNIXTHREAD, 8 + len(body)) + body
            found = True
        new.append(raw)
    if not found:
        print("no LC_MAIN found (already patched?)")
        return
    blob = b"".join(new)
    assert 32 + len(blob) <= first_section_off, "not enough header padding"
    data[32:32 + sizeofcmds] = b"\0" * sizeofcmds
    data[32:32 + len(blob)] = blob
    struct.pack_into("<I", data, 20, len(blob))
    # MH_PIE stays; MH_NOUNDEFS / DYLDLINK untouched
    open(path, "wb").write(data)
    print("patched %s: LC_MAIN -> LC_UNIXTHREAD, entry 0x%x" % (path, text_vmaddr + entryoff))

if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
