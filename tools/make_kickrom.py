#!/usr/bin/env python3
"""Build a 512-KB Kickstart ROM substitute from a bare-metal test binary.

Amiga 512-KB ROM addressing:
  ROM file offset 0  → physical address $00F80000 (ROM base)
  ROM file offset N  → physical address $00F80000 + N

The CPU exception-vector overlay maps address $0 → ROM file offset 0:
  physical $00000000 (reset SSP read) = ROM offset 0 = SSP value
  physical $00000004 (reset PC  read) = ROM offset 4 = PC  value

If the reset PC is $00FC0008 then the code must be at:
  ROM file offset = PC - ROMBASE = $FC0008 - $F80000 = $40008

INPUT binary layout (smoke.bin from vasmm68k_mot):
  bytes 0-3  : reset SSP  (kept as-is)
  bytes 4-7  : reset PC   (patched to ROMBASE + CODE_OFFSET)
  bytes 8+   : test code  (placed at ROM file offset CODE_OFFSET)

Usage:
    python3 tools/make_kickrom.py <input.bin> <output.rom>
"""
import sys, struct, pathlib

ROMSIZE      = 512 * 1024       # standard 512-KB Amiga ROM
ROMBASE      = 0x00F80000       # 512-KB ROM base address
CODE_OFFSET  = 0x00040008       # offset inside ROM file where code runs
                                 # = target_PC - ROMBASE = $FC0008 - $F80000


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <in.bin> <out.rom>")

    src = pathlib.Path(sys.argv[1]).read_bytes()
    if len(src) < 8:
        sys.exit("binary too short (need ≥ 8 bytes for reset vectors)")

    code = src[8:]          # test code (everything after the 8-byte vector table)
    ssp  = struct.unpack_from('>I', src, 0)[0]
    pc   = ROMBASE + CODE_OFFSET   # physical address where code starts

    # Build 512-KB ROM: fill with $FF, then place SSP/PC vectors and code
    rom = bytearray(b'\xff' * ROMSIZE)

    # Exception vectors at ROM base (= overlay address $0)
    struct.pack_into('>I', rom, 0, ssp)
    struct.pack_into('>I', rom, 4, pc)

    # Test code at the offset that matches the reset PC
    if CODE_OFFSET + len(code) > ROMSIZE:
        sys.exit(f"code ({len(code)} B) overflows ROM at offset {CODE_OFFSET:#x}")
    rom[CODE_OFFSET : CODE_OFFSET + len(code)] = code

    pathlib.Path(sys.argv[2]).write_bytes(bytes(rom))
    print(f"ROM: {sys.argv[2]}  SSP=0x{ssp:08x}  PC=0x{pc:08x}  "
          f"code@0x{CODE_OFFSET:05x}  size={ROMSIZE//1024}KB")


if __name__ == '__main__':
    main()
