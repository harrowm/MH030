#!/usr/bin/env python3
"""
gen_init_hex.py — generate a $readmemh hex file from a test vector.

The output is a 4KB (1024-word) hex file that can be loaded directly by
cosim_dat_tb.sv via +hexfile=.  No vasm invocation needed.

Hex layout (big-endian 68k memory):
  0x0000  : SSP = pre.a[7]
  0x0004  : reset PC = 0x0008  (-> init code)
  0x0008  : init code: MOVE.L #Di, Di  ×8   (6 bytes each = 48 bytes)
  0x0038  : init code: MOVEA.L #Ai, Ai  ×7  (6 bytes each = 42 bytes)
  0x0062  : MOVE.W #SR, SR              (4 bytes)
  0x0066  : instruction under test      (2–10 bytes)
  0x006C+ : padding NOPs, then STOP #$2700

Encoding reference (big-endian 68k, all sizes big-endian):
  MOVE.L  #imm32, Dn   : 0x2[0+2n]3C <imm32>   (6 bytes)
  MOVEA.L #imm32, An   : 0x2[0+2n]7C <imm32>   (6 bytes)
  MOVE.W  #imm16, SR   : 0x46FC <imm16>         (4 bytes)
  STOP    #$2700       : 0x4E72 0x2700           (4 bytes)
  NOP                  : 0x4E71                  (2 bytes)

Limitations:
  • Always runs in supervisor mode (SR[13]=1 forced; user-mode vectors skipped
    by the caller or handled by setting SR after other init).
  • Does not set up arbitrary memory contents for memory-addressing instructions.
    The testbench memory is filled with NOP (0x4E71) by default.
"""

import struct
import sys

MEM_SIZE = 4096          # bytes = 1024 × u32
RESET_PC = 0x0008        # init code start address


def _word(opcode):
    return struct.pack('>H', opcode)


def _long(value):
    return struct.pack('>I', value & 0xFFFF_FFFF)


def _move_l_imm_dn(n, val):
    """MOVE.L #val, Dn"""
    return _word(0x203C | (n << 9)) + _long(val)


def _movea_l_imm_an(n, val):
    """MOVEA.L #val, An  (n = 0..6; A7 set via SSP vector)"""
    return _word(0x207C | (n << 9)) + _long(val)


def _move_w_imm_sr(val):
    """MOVE.W #val, SR  (privileged; must be in supervisor mode)"""
    return _word(0x46FC) + _word(val & 0xFFFF)


def _stop_2700():
    """STOP #$2700"""
    return _word(0x4E72) + _word(0x2700)


def _nop():
    return _word(0x4E71)


def build_binary(pre, instr_bytes):
    """
    Build raw big-endian 68k binary for a test vector.

    Args:
        pre         : dict with keys 'd' (list[8]), 'a' (list[8]), 'sr', 'pc'
        instr_bytes : bytes, the instruction under test (2–10 bytes)

    Returns:
        bytes of length MEM_SIZE
    """
    code = bytearray()

    # Vector table
    code += _long(pre['a'][7])   # SSP (word 0, addr 0x0000)
    code += _long(RESET_PC)      # reset PC (word 1, addr 0x0004)

    # Init: D0–D7
    for n in range(8):
        code += _move_l_imm_dn(n, pre['d'][n])

    # Init: A0–A6  (A7 already set via SSP vector)
    for n in range(7):
        code += _movea_l_imm_an(n, pre['a'][n])

    # Init: SR  — always set last so mode change takes effect immediately
    # Force supervisor mode (bit 13) to stay 1 so the STOP later can run.
    # If the test vector is user-mode, the SR[13]=0 will actually switch mode.
    code += _move_w_imm_sr(pre['sr'] | 0x2000)

    # Pipeline bubble: MOVE.W #,SR writes the SR register (including X flag) in the
    # WB stage.  Without a gap, the very next instruction's EX stage coincides with
    # that WB and reads the stale (pre-write) SR value.  One NOP is enough.
    code += _nop()

    # Align to word boundary (should already be, but be safe)
    while len(code) % 2 != 0:
        code += b'\x00'

    # Instruction under test
    code += bytes(instr_bytes)

    # Pad instruction to even boundary
    if len(code) % 2 != 0:
        code += _nop()[:1]   # single byte pad (unusual)

    # STOP #$2700 — halts the CPU after the instruction completes
    code += _stop_2700()

    # Pad remaining memory with NOP longwords
    while len(code) < MEM_SIZE:
        code += _word(0x4E71)
    code = bytes(code[:MEM_SIZE])

    return code


def binary_to_hex(data):
    """Convert raw binary to $readmemh format: one 32-bit hex word per line."""
    assert len(data) % 4 == 0
    lines = []
    for i in range(0, len(data), 4):
        w = struct.unpack_from('>I', data, i)[0]
        lines.append(f'{w:08x}')
    return '\n'.join(lines) + '\n'


def gen_hex(pre, instr_bytes):
    """Return the complete hex-file string for a test vector."""
    return binary_to_hex(build_binary(pre, instr_bytes))


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    """Quick test: emit hex for a synthetic ADD.L D0,D1 with pre D0=1, D1=2."""
    pre = {
        'd':  [1, 2, 0, 0, 0, 0, 0, 0],
        'a':  [0] * 8,
        'sr': 0x2000,
        'pc': RESET_PC,
    }
    # ADD.L D0,D1 = 0xD280
    instr = struct.pack('>H', 0xD280)
    print(gen_hex(pre, instr), end='')


if __name__ == '__main__':
    main()
