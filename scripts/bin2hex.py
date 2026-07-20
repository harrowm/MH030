#!/usr/bin/env python3
"""bin2hex.py — convert a raw 68k .bin (linked at 0x010000) to $readmemh hex.

The output hex file contains one 32-bit big-endian word per line and is
intended to be loaded by mustest_tb.sv into main_mem starting at index 16384:

    $readmemh(hexfile, main_mem, 16384, 32767);

Anything beyond 64 KB is silently truncated.

Usage:
    python3 scripts/bin2hex.py input.bin output.hex
"""

import struct, sys, pathlib


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} input.bin output.hex")
        sys.exit(1)

    data = pathlib.Path(sys.argv[1]).read_bytes()

    # Pad to longword boundary
    while len(data) % 4:
        data += b'\x00'

    if len(data) > 0x10000:
        print(f"[bin2hex] warning: binary {len(data):#x} bytes > 64 KB; truncating",
              file=sys.stderr)
        data = data[:0x10000]

    lines = []
    for i in range(0, len(data), 4):
        w = struct.unpack_from('>I', data, i)[0]
        lines.append(f'{w:08x}')

    pathlib.Path(sys.argv[2]).write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
