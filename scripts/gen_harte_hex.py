#!/usr/bin/env python3
"""
gen_harte_hex.py — generate a sparse $readmemh hex file from a Tom Harte test case.

Memory layout (all byte addresses, indexed as 32-bit words via addr[23:2]):
  0x000000  reset SSP (= test.initial.ssp or .usp)
  0x000004  reset PC  = RESET_PC (0x000008)
  0x000008  init code: MOVE.L #Dn x8, MOVEA.L #An x7, MOVEA.L #A7, MOVE.W #SR
  0x000066  instruction under test  (remapped from initial.pc-4)
  0x000066+N  STOP #$2700  (N = final.pc - initial.pc = instruction byte length)
  0x000076+  NOP padding (IFU prefetch runway)
  <data addrs>  initial.ram entries at their natural 24-bit addresses

Limitations:
  - Instruction is always placed at 0x000066 regardless of original PC.
    PC-relative EA (mode 7, reg 2/3) will be wrong — filter those tests out.
  - Always runs in supervisor mode (SR forced | 0x2000) so STOP can execute.
  - Only the 24-bit portion of addresses is used (ext_a[23:2] in the testbench).
"""

import struct
import sys
from pathlib import Path

RESET_PC   = 0x000008   # init code start byte address
INSTR_ADDR = 0x000080   # instruction under test byte address (init code = 100 bytes → ends at 0x6C)


def _word(v):  return struct.pack('>H', v & 0xFFFF)
def _long(v):  return struct.pack('>I', v & 0xFFFFFFFF)


def _movea_l_imm_a7(val):
    """MOVEA.L #val, A7  (opcode 0x2E7C)"""
    return _word(0x2E7C) + _long(val)


def _move_l_imm_dn(n, val):
    """MOVE.L #val, Dn"""
    return _word(0x203C | (n << 9)) + _long(val)


def _movea_l_imm_an(n, val):
    """MOVEA.L #val, An  (n = 0..6)"""
    return _word(0x207C | (n << 9)) + _long(val)


def _move_w_imm_sr(val):
    return _word(0x46FC) + _word(val & 0xFFFF)


def _stop_2700():
    return _word(0x4E72) + _word(0x2700)


def _nop():
    return _word(0x4E71)


def build_patches(test):
    """
    Return dict {byte_addr: byte_value} for all locations that must be
    initialised in the testbench memory array.
    """
    ini   = test['initial']
    final = test['final']

    instr_len  = final['pc'] - ini['pc']     # bytes (= delta in 68k pipeline model)
    instr_src  = ini['pc'] - 4               # where instruction lives in original space

    patches = {}

    def patch(addr, data):
        for i, b in enumerate(data):
            patches[(addr + i) & 0xFFFFFF] = b   # keep in 24-bit space

    # Active A7: SSP in supervisor mode, USP in user mode
    a7_val = ini['ssp'] if (ini['sr'] & 0x2000) else ini['usp']

    # ── Reset vectors ────────────────────────────────────────────────────────
    patch(0x000000, _long(a7_val))
    patch(0x000004, _long(RESET_PC))

    # ── Init code ────────────────────────────────────────────────────────────
    code = bytearray()
    for n in range(8):
        code += _move_l_imm_dn(n, ini[f'd{n}'])
    for n in range(7):
        code += _movea_l_imm_an(n, ini[f'a{n}'])
    code += _movea_l_imm_a7(a7_val)
    # SR: force supervisor, clear trace bits (T1/T0) so STOP can execute.
    # XNZVC and interrupt mask are kept from the test's initial SR.
    sr = (ini['sr'] | 0x2000) & ~0xC000
    code += _move_w_imm_sr(sr)

    init_end = RESET_PC + len(code)
    assert init_end <= INSTR_ADDR, (
        f"init code overflows: ends at {init_end:#x}, instr at {INSTR_ADDR:#x}")

    patch(RESET_PC, bytes(code))

    # Fill gap between init code and instruction with NOPs so IFU prefetch
    # doesn't encounter uninitialized (X) memory.
    for addr in range(init_end, INSTR_ADDR, 2):
        patch(addr, _nop())

    # ── Instruction bytes at INSTR_ADDR ──────────────────────────────────────
    ram_map = {addr: val for addr, val in ini['ram']}
    instr_bytes = bytearray(
        ram_map.get(instr_src + i, 0x4E) for i in range(instr_len)
    )
    patch(INSTR_ADDR, bytes(instr_bytes))

    # STOP after the instruction; NOP runway for IFU prefetch
    stop_addr = INSTR_ADDR + instr_len
    patch(stop_addr, _stop_2700())
    nop_start = stop_addr + 4
    for i in range(8):
        patch(nop_start + i * 2, _nop())

    # ── Test data from initial.ram ────────────────────────────────────────────
    our_code_range = range(0x000000, 0x000070)
    for addr, val in ini['ram']:
        addr24 = addr & 0xFFFFFF
        if addr24 in our_code_range:
            continue   # our init code wins; don't let test data clobber it
        if instr_src <= addr < instr_src + instr_len:
            continue   # instruction bytes already placed at INSTR_ADDR
        patches[addr24] = val

    return patches, instr_len


def patches_to_hex(patches):
    """
    Convert a {byte_addr: byte_val} dict to $readmemh format.
    Groups consecutive bytes into 32-bit words and emits @word_addr entries.
    Addresses are folded to 16-bit word index (matching testbench mem_idx = ext_a[17:2])
    so all entries fit in the 64K-word memory model.
    """
    if not patches:
        return ''

    # Group bytes into 32-bit words: word_addr = (byte_addr >> 2) & 0xFFFF
    words = {}
    for baddr, bval in patches.items():
        waddr = (baddr >> 2) & 0xFFFF     # fold to 16-bit word index
        shift = (3 - (baddr & 3)) * 8    # big-endian: byte 0 → bits 31:24
        words.setdefault(waddr, [0, 0])   # [value, byte_mask]
        words[waddr][0] |= (bval & 0xFF) << shift
        words[waddr][1] |= 1 << (baddr & 3)

    lines = []
    prev = -2
    for waddr in sorted(words):
        val, _ = words[waddr]
        if waddr != prev + 1:
            lines.append(f'@{waddr:06x}')
        lines.append(f'{val:08x}')
        prev = waddr
    return '\n'.join(lines) + '\n'


def gen_hex(test):
    """Return the hex file string for a test case."""
    patches, _ = build_patches(test)
    return patches_to_hex(patches)


def can_run(test):
    """
    Return (ok: bool, reason: str).
    Filters test cases the current harness cannot handle correctly.
    """
    ini   = test['initial']
    final = test['final']
    opcode = ini['prefetch'][0]

    # Sanity-check instruction length (final.pc - ini.pc).  68k instructions
    # are at most 22 bytes (opcode + 5 extension words × 2 + 2 imm words × 2).
    # A wild final.pc (e.g. exception handler PC from the 68000 sim) would make
    # build_patches() try to allocate a billion-byte bytearray and hang.
    instr_len = final['pc'] - ini['pc']
    if instr_len <= 0 or instr_len > 24:
        return False, f'bad instruction length {instr_len} (final.pc={final["pc"]:#010x})'

    # PC-relative source EA (mode=111, reg=2 or reg=3): address depends on
    # original PC; instruction remapping to 0x0080 breaks the offset.
    ea_mode = (opcode >> 3) & 0x7
    ea_reg  = opcode & 0x7
    if ea_mode == 7 and ea_reg in (2, 3):
        return False, 'PC-relative source EA'

    # Indexed EA (mode=6): the 68030 reads bits[10:9] as scale (×1/×2/×4/×8).
    # The 68000 ignores those bits (always ×1).  Any test with scale≠0 would
    # compute a different EA on the 68030 DUT vs the 68000 reference — skip it.
    #
    # For most instructions the brief extension is at prefetch[1] (directly
    # after the opcode word).  For group-0 immediate instructions (ADDI/SUBI/
    # ORI/ANDI/EORI to indexed EA), an immediate word precedes the brief
    # extension, so prefetch[1] is the immediate and the brief extension lives
    # in the RAM at instr_src+4 (byte/word imm) or instr_src+6 (long imm).
    if ea_mode == 6:
        f_group = (opcode >> 12) & 0xF
        f_ss    = (opcode >>  6) & 0x3
        f_dn    = (opcode >>  9) & 0x7
        if f_group == 0 and (f_dn not in (4, 7)) and f_ss != 3:
            # ADDI/SUBI/ORI/ANDI/EORI to indexed EA: get brief ext from RAM
            instr_src_for_scale = ini['pc'] - 4
            brief_offset = 6 if f_ss == 2 else 4   # long imm = 2 words, else 1
            ram_map_scale = {a: v for a, v in ini['ram']}
            bhi = ram_map_scale.get(instr_src_for_scale + brief_offset,     0)
            blo = ram_map_scale.get(instr_src_for_scale + brief_offset + 1, 0)
            brief_ext = (bhi << 8) | blo
            scale = (brief_ext >> 9) & 0x3
            if scale != 0:
                return False, f'indexed EA with non-zero scale={scale} (68000/68030 mismatch)'
        elif len(ini['prefetch']) > 1:
            # Brief extension is the second prefetch word (immediately after opcode)
            ext_word = ini['prefetch'][1]
            scale = (ext_word >> 9) & 0x3
            if scale != 0:
                return False, f'indexed EA with non-zero scale={scale} (68000/68030 mismatch)'

    # Instruction at original address would land in our init region
    instr_src = ini['pc'] - 4
    instr_len = final['pc'] - ini['pc']
    if instr_src < 0x000090:
        return False, f'instruction at {instr_src:#x} overlaps init region'

    # Skip tests where the instruction reads or writes into our init code region
    # (0x000000-0x00008F).  We place init code there, not test data, so any
    # data access to that range produces wrong values and can't be compared.
    ini_map24  = {a & 0xFFFFFF: v for a, v in ini['ram']}
    fin_map24  = {a & 0xFFFFFF: v for a, v in final['ram']}
    init_range = range(0x000000, 0x000090)
    for a24, fin_v in fin_map24.items():
        if a24 in init_range and ini_map24.get(a24) != fin_v:
            return False, f'instruction writes to init region {a24:#06x}'

    # Check for aliasing: two different byte addresses collide when folded
    # to 16-bit word index ((byte_addr >> 2) & 0xFFFF).
    try:
        patches, _ = build_patches(test)
    except Exception:
        return True, 'ok'   # let it try and fail at run time
    word_owners = {}
    for baddr in patches:
        waddr = (baddr >> 2) & 0xFFFF
        if waddr in word_owners and (baddr >> 2) != (word_owners[waddr] >> 2):
            return False, (f'address alias: {baddr:#x} and '
                           f'{word_owners[waddr]:#x} fold to same word {waddr:#06x}')
        word_owners[waddr] = baddr

    return True, 'ok'


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    import sys
    import json
    sys.path.insert(0, str(Path(__file__).parent))
    from parse_harte import decode_file

    if len(sys.argv) < 2:
        print("usage: gen_harte_hex.py <.json.bin> [test_index]")
        sys.exit(1)

    tests = decode_file(sys.argv[1])
    idx   = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    test  = tests[idx]

    ok, reason = can_run(test)
    if not ok:
        print(f"# SKIP: {reason}", file=sys.stderr)
        sys.exit(1)

    print(gen_hex(test), end='')


if __name__ == '__main__':
    main()
