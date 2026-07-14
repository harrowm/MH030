#!/usr/bin/env python3
"""Convert a raw M68k binary to 32-bit big-endian hex words for $readmemh.

Usage: bin2hex.py <input.bin> [> output.hex]

Reads the binary file, pads to a longword boundary with 0x4E71 (NOP) bytes,
then emits one 8-digit lowercase hex word per line.
"""
import sys

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <input.bin>", file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1], 'rb') as f:
    data = bytearray(f.read())

while len(data) % 4:
    data += b'\x4e\x71'  # NOP fill to longword boundary

for i in range(0, len(data), 4):
    word = int.from_bytes(data[i:i+4], 'big')
    print(f'{word:08x}')
