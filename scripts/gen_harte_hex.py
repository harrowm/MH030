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

    # ── Scale remap: copy bytes EA_68000 → EA_68030 for non-zero scale ────────
    # When scale≠0, the 68030 computes a different indexed EA than the 68000.
    # Pre-place the same source bytes at EA_68030 so the DUT reads correct data.
    remap = get_scale_remap(test)
    if remap:
        ini_ram_map = {(a & 0xFFFFFF): v for a, v in ini['ram']}
        ea0, ea1, nb = remap['ea_68000'], remap['ea_68030'], remap['siz_bytes']
        for i in range(nb):
            patches[(ea1 + i) & 0xFFFFFF] = ini_ram_map.get((ea0 + i) & 0xFFFFFF, 0)

    return patches, instr_len


def get_scale_remap(test):
    """
    If the opcode has an indexed EA (mode=6) with non-zero scale, return a dict:
      {'ea_68000': int, 'ea_68030': int, 'siz_bytes': int}
    The 68000 ignores scale bits (always ×1); the 68030 applies ×1/×2/×4/×8.
    build_patches() uses this to copy source bytes from EA_68000 to EA_68030 so
    the DUT reads the expected data; compare() uses it to redirect expected memory
    writes from EA_68000 to EA_68030 (for RMW-destination instructions).
    Returns None when scale=0 or the opcode is not an indexed EA.
    """
    ini    = test['initial']
    opcode = ini['prefetch'][0]

    if (opcode >> 3) & 7 != 6:
        return None

    f_group = (opcode >> 12) & 0xF
    f_ss    = (opcode >>  6) & 0x3
    f_dn    = (opcode >>  9) & 0x7
    f_reg   =  opcode        & 0x7

    # Locate brief extension word (same logic as can_run() scale check)
    if f_group == 0 and (f_dn not in (4, 7)) and f_ss != 3:
        instr_src = ini['pc'] - 4
        off       = 6 if f_ss == 2 else 4
        rm        = {a: v for a, v in ini['ram']}
        brief_ext = (rm.get(instr_src + off, 0) << 8) | rm.get(instr_src + off + 1, 0)
    elif len(ini['prefetch']) > 1:
        brief_ext = ini['prefetch'][1]
    else:
        return None

    scale = (brief_ext >> 9) & 3
    if scale == 0:
        return None

    xn_da  = (brief_ext >> 15) & 1
    xn_reg = (brief_ext >> 12) & 7
    xn_wl  = (brief_ext >> 11) & 1
    d8     = brief_ext & 0xFF
    if d8 >= 0x80:
        d8 -= 0x100

    def _get_an(reg):
        if reg == 7:
            return (ini['ssp'] if (ini['sr'] & 0x2000) else ini['usp']) & 0xFFFFFFFF
        return ini[f'a{reg}'] & 0xFFFFFFFF

    an_val  = _get_an(f_reg)
    xn_val  = _get_an(xn_reg) if xn_da else ini[f'd{xn_reg}'] & 0xFFFFFFFF
    if not xn_wl:                       # word Xn: sign-extend 16→32
        xn_val &= 0xFFFF
        if xn_val >= 0x8000:
            xn_val -= 0x10000
    # longword Xn stays as-is; Python arithmetic + 24-bit mask handles overflow

    ea_68000 = (an_val + xn_val            + d8) & 0xFFFFFF
    ea_68030 = (an_val + xn_val * (1 << scale) + d8) & 0xFFFFFF

    siz_bytes = {0: 1, 1: 2, 2: 4}.get(f_ss, 1)

    return {'ea_68000': ea_68000, 'ea_68030': ea_68030, 'siz_bytes': siz_bytes}


def get_operand_ea(test):
    """
    Compute the 68030 effective address for the memory operand of the instruction.
    Returns (ea_byte_addr: int, siz_bytes: int) or None if no memory access or
    the mode is too complex to evaluate statically.

    Reads instruction bytes directly from ini['ram'] at ini['pc']-4 so that
    group-0 immediate ops (where extension words are offset past the immediate)
    are handled correctly without depending on prefetch[] content.
    """
    ini       = test['initial']
    instr_src = ini['pc'] - 4
    rm        = {a: v for a, v in ini['ram']}

    def rw(off):    # read one big-endian instruction word from RAM
        return (rm.get(instr_src + off, 0) << 8) | rm.get(instr_src + off + 1, 0)

    opcode  = rw(0)
    f_group = (opcode >> 12) & 0xF
    f_dn    = (opcode >>  9) & 0x7
    f_dir   = (opcode >>  8) & 0x1
    f_ss    = (opcode >>  6) & 0x3
    ea_mode = (opcode >>  3) & 0x7
    ea_reg  =  opcode        & 0x7

    # No memory operand for register-direct or immediate EA
    if ea_mode in (0, 1):
        return None
    if ea_mode == 7 and ea_reg in (2, 3, 4):   # PC-relative or #imm
        return None

    # Transfer size in bytes.
    # f_ss=3 signals ADDA: word (f_dir=0) or long (f_dir=1).
    if f_ss == 3:
        siz_bytes = 4 if f_dir else 2
    else:
        siz_bytes = {0: 1, 1: 2, 2: 4}[f_ss]

    # Byte offset within the instruction to the first EA extension word.
    # Group-0 immediate ops (ADDI/SUBI/ORI/ANDI/EORI) have an immediate word
    # (byte/word size) or longword (long size) before the EA extension words.
    if f_group == 0 and f_dn not in (4, 7) and f_ss != 3:
        ea_off = 2 + (4 if f_ss == 2 else 2)
    elif f_group == 0 and f_dn in (4, 7):
        return None     # bit-ops / MOVES: non-trivial layout, skip
    else:
        ea_off = 2      # EA exts follow the opcode word directly

    def get_an(reg):
        if reg == 7:
            return (ini['ssp'] if (ini['sr'] & 0x2000) else ini['usp']) & 0xFFFFFFFF
        return ini[f'a{reg}'] & 0xFFFFFFFF

    an = get_an(ea_reg)

    if ea_mode == 2:        # (An)
        ea = an
    elif ea_mode == 3:      # (An)+
        ea = an
    elif ea_mode == 4:      # -(An)  — A7 byte uses step=2 to stay word-aligned
        step = 2 if (ea_reg == 7 and f_ss == 0) else siz_bytes
        ea   = (an - step) & 0xFFFFFFFF
    elif ea_mode == 5:      # (d16,An)
        d16 = rw(ea_off)
        if d16 >= 0x8000: d16 -= 0x10000
        ea = (an + d16) & 0xFFFFFFFF
    elif ea_mode == 6:      # (d8,An,Xn) — use get_scale_remap for scale≠0
        remap = get_scale_remap(test)
        if remap:
            ea = remap['ea_68030']
        else:
            brief  = rw(ea_off)
            xn_da  = (brief >> 15) & 1
            xn_reg = (brief >> 12) & 7
            xn_wl  = (brief >> 11) & 1
            d8     =  brief & 0xFF
            if d8 >= 0x80: d8 -= 0x100
            xn_sel = get_an(xn_reg) if xn_da else ini[f'd{xn_reg}'] & 0xFFFFFFFF
            if not xn_wl:
                xn_sel &= 0xFFFF
                if xn_sel >= 0x8000: xn_sel -= 0x10000
            ea = (an + xn_sel + d8) & 0xFFFFFFFF
    elif ea_mode == 7:
        if ea_reg == 0:     # (xxx).W
            w  = rw(ea_off)
            ea = ((w - 0x10000) if w >= 0x8000 else w) & 0xFFFFFFFF
        elif ea_reg == 1:   # (xxx).L
            ea = (rw(ea_off) << 16) | rw(ea_off + 2)
        else:
            return None
    else:
        return None

    return ea & 0xFFFFFF, siz_bytes


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

    # Misaligned EA: word or longword access to an odd address causes a 68000/68030
    # address error.  The reference sim then runs the exception handler, landing
    # final.pc at a random location — the test cannot be replayed in our harness.
    ea_info = get_operand_ea(test)
    if ea_info is not None:
        ea, ea_siz = ea_info
        if ea_siz >= 2 and (ea & 1):
            return False, 'misaligned EA'

    # PC-relative source EA (mode=111, reg=2 or reg=3): address depends on
    # original PC; instruction remapping to 0x0080 breaks the offset.
    ea_mode = (opcode >> 3) & 0x7
    ea_reg  = opcode & 0x7
    if ea_mode == 7 and ea_reg in (2, 3):
        return False, 'PC-relative source EA'

    # Indexed EA (mode=6) with non-zero scale: the 68030 computes a different EA
    # than the 68000 reference.  get_scale_remap() handles the remapping so these
    # tests can run — skip only when EA_68030 is problematic.
    if ea_mode == 6:
        remap = get_scale_remap(test)
        if remap:
            ea1, nb = remap['ea_68030'], remap['siz_bytes']
            # Odd-address word/longword → 68030 address error; skip.
            if nb >= 2 and (ea1 & 1):
                return False, f'EA_68030 {ea1:#08x} misaligned (would be addr error)'
            # EA_68030 in our init code region → data conflict.
            if any((ea1 + i) & 0xFFFFFF in range(0x000000, 0x000090) for i in range(nb)):
                return False, f'EA_68030 {ea1:#08x} in init region (scale remap)'

    # Instruction at original address would land in our init region
    instr_src = ini['pc'] - 4
    instr_len = final['pc'] - ini['pc']

    # Backstop for complex EA modes that get_operand_ea() returns None for:
    # if instr_len is still wild, the reference took an exception (almost certainly
    # a misaligned EA that we couldn't compute statically).
    if not (1 <= instr_len <= 24):
        return False, 'misaligned EA'

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
