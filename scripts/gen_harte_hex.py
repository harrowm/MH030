#!/usr/bin/env python3
"""
gen_harte_hex.py — generate a sparse $readmemh hex file from a Tom Harte test case.

Memory layout (all byte addresses, indexed as 32-bit words via addr[23:2]):
  0x000000  reset SSP (= test.initial.ssp or .usp)
  0x000004  reset PC  = RESET_PC (0x000008)
  0x000008  init code: MOVE.L #Dn x8, MOVEA.L #An x7, MOVEA.L #A7, MOVE.W #SR,
                       NOP (SR pipeline guard), JMP.L #instr_src
  instr_src  instruction under test at its original address (initial.pc - 4)
  instr_src+N  STOP #$2700  (N = final.pc - initial.pc = instruction byte length)
  instr_src+N+4+  NOP padding (IFU prefetch runway)
  <data addrs>  initial.ram entries at their natural 24-bit addresses

The instruction runs at its original PC so PC-relative EAs (mode 7, reg 2/3)
compute correctly without any displacement adjustment.

  - Always runs in supervisor mode (SR forced | 0x2000) so STOP can execute.
  - Only the 24-bit portion of addresses is used (ext_a[23:2] in the testbench).
"""

import struct
import sys
from pathlib import Path

RESET_PC      = 0x000008   # init code start byte address
INIT_CODE_END = 0x000090   # conservative upper bound on init code + JMP.L (~0x007a actual)


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


def _jmp_l(addr):
    """JMP (xxx).L — opcode 0x4EF9 + 32-bit absolute address"""
    return _word(0x4EF9) + _long(addr)


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
    code += _nop()              # pipeline guard: no SR-forwarding after MOVE.W #SR
    # Init USP: we always run in supervisor mode, so USP is separate from A7/SSP.
    # Temporarily load ini['usp'] into A7, MOVE A7→USP, then restore A7 to a7_val.
    usp_val = ini['usp'] if (ini['sr'] & 0x2000) else ini['usp']
    code += _movea_l_imm_a7(usp_val)   # A7 = usp (temp borrow)
    code += _word(0x4E67)               # MOVE A7, USP  (supervisor-only)
    code += _movea_l_imm_a7(a7_val)    # restore A7 = ssp / original value
    code += _jmp_l(instr_src)  # jump to instruction at its original address

    assert RESET_PC + len(code) <= INIT_CODE_END, (
        f"init code overflows: ends at {RESET_PC + len(code):#x}")

    patch(RESET_PC, bytes(code))

    # ── Prefetch words → memory ───────────────────────────────────────────────
    # The Harte format stores ini['prefetch'] = words already in the IFU queue.
    # When the instruction word is only in the prefetch queue (not in ini['ram'],
    # e.g. pure-register SUBQ.b #2,D3) we still need to write those bytes to
    # memory so the DUT's IFU can fetch them from the hex file.  Write both
    # prefetch words at their natural addresses before ini['ram'] and STOP; the
    # STOP runway placed last will overwrite any overlap.
    our_code_range = range(0x000000, INIT_CODE_END)
    for pf_idx, pf_word in enumerate(ini['prefetch'][:2]):
        pf_addr = (instr_src + pf_idx * 2) & 0xFFFFFF
        for byte_off, byte_val in enumerate([(pf_word >> 8) & 0xFF, pf_word & 0xFF]):
            ba = (pf_addr + byte_off) & 0xFFFFFF
            if ba not in our_code_range:
                patches[ba] = byte_val

    # ── Test data from initial.ram ────────────────────────────────────────────
    # Place ini['ram'] after prefetch so it wins over prefetch for overlapping
    # addresses; STOP runway below wins over both.
    for addr, val in ini['ram']:
        addr24 = addr & 0xFFFFFF
        if addr24 in our_code_range:
            continue   # our init code wins; don't let test data clobber it
        patches[addr24] = val

    # ── Scale remap: copy bytes EA_68000 → EA_68030 for non-zero scale ────────
    for remap in get_scale_remap(test):
        ini_ram_map = {(a & 0xFFFFFF): v for a, v in ini['ram']}
        ea0, ea1, nb = remap['ea_68000'], remap['ea_68030'], remap['siz_bytes']
        for i in range(nb):
            patches[(ea1 + i) & 0xFFFFFF] = ini_ram_map.get((ea0 + i) & 0xFFFFFF, 0)

    # ── Full extension word masking: bit8=1 → force to brief (68000 behaviour) ─
    # The 68000 ignores bit 8 and scale (bits 10:9); the 68030 interprets bit8=1
    # as a full extension word with a completely different EA formula.  Patch the
    # instruction bytes in memory so the DUT sees bits[10:8]=0 (a brief extension
    # with scale=0), which produces exactly the same EA as the 68000 reference.
    # The test data is already at the 68000 EA in ini['ram'], so no remap needed.
    opcode_w = ini['prefetch'][0]
    ea_mode_w = (opcode_w >> 3) & 7
    ea_reg_w  =  opcode_w        & 7
    if ea_mode_w == 6 or (ea_mode_w == 7 and ea_reg_w == 3):
        f_group_w = (opcode_w >> 12) & 0xF
        f_dir_w   = (opcode_w >>  8) & 0x1
        f_ss_w    = (opcode_w >>  6) & 0x3
        f_dn_w    = (opcode_w >>  9) & 0x7
        # f_dir=0 required: CHK ea,Dn (f_dir=1 always) uses f_dn as the tested
        # register (any value 0-7) and collides with MOVEM's f_dn∈{4,6} marker
        # when testing D4/D6 at word size — see get_operand_ea()'s comment.
        is_movem_w = (f_group_w == 4 and not f_dir_w and f_dn_w in (4, 6) and f_ss_w >= 2)
        # Group-0 immediate ALU ops (ORI/ANDI/SUBI/ADDI/EORI/CMPI) always have
        # f_dir=0 (bit8=0) — the immediate word precedes the EA extension word(s).
        # Dynamic bit-ops (BTST/BCHG/BCLR/BSET Dn,ea) share the f_group==0 + mode-6
        # encoding but have f_dir=1 (Dn is the bit-count register, no immediate
        # word at all) — f_dn alone can't disambiguate since it's the bit-count
        # register 0-7 for dynamic forms, not a fixed marker. Must check f_dir too.
        if f_group_w == 0 and not f_dir_w and f_dn_w not in (4, 7) and f_ss_w != 3:
            ea_off_w = 6 if f_ss_w == 2 else 4
        elif f_group_w == 0 and not f_dir_w and f_dn_w == 4:
            # Static BTST/BCHG/BCLR/BSET #n,ea: bit-number word precedes the EA's
            # own extension word (we're already known mode6/pc_idx here) — see
            # matching comment in get_scale_remap().
            ea_off_w = 4
        elif is_movem_w:
            ea_off_w = 4  # skip opcode + register-mask word
        else:
            ea_off_w = 2
        ext_hi_addr = (instr_src + ea_off_w) & 0xFFFFFF
        ext_hi = patches.get(ext_hi_addr, 0)
        if ext_hi & 0x01:           # bit 8 of the 16-bit extension word is set
            patches[ext_hi_addr] = ext_hi & 0xF8   # clear bit8 + scale[1:0]

    # ── MOVE group: also mask the DESTINATION extension word if indexed ──────────
    # MOVE (groups 1,2,3) encodes the destination mode in bits[8:6].  When the
    # destination is mode-6 (indexed), the DUT's 68030 may see bit8=1 in the
    # destination extension word and compute a full-extension-word EA instead of
    # a brief-extension EA.  Mask bit8 and scale so the DUT's EA matches 68000.
    f_grp_dst = (opcode_w >> 12) & 0xF
    dst_mode_msk = (opcode_w >>  6) & 0x7
    if f_grp_dst in (1, 2, 3) and dst_mode_msk == 6:
        src_mode_msk = (opcode_w >> 3) & 7
        src_reg_msk  =  opcode_w       & 7
        if src_mode_msk == 7 and src_reg_msk == 1:
            src_ext_msk = 2
        elif src_mode_msk == 7 and src_reg_msk == 4:
            src_ext_msk = 2 if f_grp_dst == 2 else 1
        elif src_mode_msk == 5 or src_mode_msk == 7:
            src_ext_msk = 1
        elif src_mode_msk == 6:
            src_ext_msk = 1  # source brief ext word
        else:
            src_ext_msk = 0  # modes 0–4
        dst_ext_msk_addr = (instr_src + 2 + src_ext_msk * 2) & 0xFFFFFF
        dst_hi = patches.get(dst_ext_msk_addr, 0)
        if dst_hi & 0x01:
            patches[dst_ext_msk_addr] = dst_hi & 0xF8  # clear bit8 + scale[1:0]

    # ── STOP + NOP runway (placed last so they always win over ini['ram'] data) ─
    stop_addr = instr_src + instr_len
    patch(stop_addr, _stop_2700())
    for i in range(8):
        patch(stop_addr + 4 + i * 2, _nop())

    return patches, instr_len


def _dst_indexed_remap(test):
    """
    MOVE groups (1,2,3) encode the destination mode in bits[8:6]. When the
    destination is mode-6 (indexed) with non-zero scale, compute its own
    ea_68000/ea_68030 remap — independent of whether the SOURCE is also
    indexed. Returns None if the destination isn't indexed, has scale=0, or
    has bit8=1 (full extension word).
    """
    ini    = test['initial']
    opcode = ini['prefetch'][0]
    instr_src = ini['pc'] - 4
    rm        = {a: v for a, v in ini['ram']}

    ea_mode_r = (opcode >> 3) & 7
    ea_reg_r  =  opcode        & 7

    f_group_d = (opcode >> 12) & 0xF
    dst_mode  = (opcode >>  6) & 0x7
    if not (f_group_d in (1, 2, 3) and dst_mode == 6):
        return None

    # Source extension-word count by mode (determines where the destination's
    # own extension word starts):
    #   0–4 (register/register-indirect simple): 0 ext words
    #   5   (d16,An):                            1 ext word
    #   6   (d8,An,Xn):                          1 ext word (source itself indexed)
    #   7,0 (abs.w):                             1 ext word
    #   7,1 (abs.l):                             2 ext words
    #   7,2 (d16,PC):                            1 ext word
    #   7,3 (d8,PC,Xn):                          1 ext word
    #   7,4 (#imm): 1 word for byte/word, 2 words for longword (group 2)
    if ea_mode_r == 5:
        src_ext = 1
    elif ea_mode_r == 6:
        src_ext = 1
    elif ea_mode_r == 7:
        if ea_reg_r == 1:
            src_ext = 2
        elif ea_reg_r == 4:
            src_ext = 2 if f_group_d == 2 else 1  # .l imm = 2 words
        else:
            src_ext = 1
    else:
        src_ext = 0   # modes 0–4

    dst_ext_off = 2 + src_ext * 2   # byte offset from instr_src
    dst_ext_idx = 1 + src_ext       # index in ini['prefetch']
    if len(ini['prefetch']) > dst_ext_idx:
        dst_brief = ini['prefetch'][dst_ext_idx]
    else:
        dst_brief = (rm.get(instr_src + dst_ext_off, 0) << 8) | \
                     rm.get(instr_src + dst_ext_off + 1, 0)

    if (dst_brief >> 8) & 1:
        return None   # full extension word

    dst_scale = (dst_brief >> 9) & 3
    if dst_scale == 0:
        return None   # no scale difference

    def _get_an_d(reg):
        if reg == 7:
            return (ini['ssp'] if (ini['sr'] & 0x2000) else ini['usp']) & 0xFFFFFFFF
        return ini[f'a{reg}'] & 0xFFFFFFFF

    dst_xn_da  = (dst_brief >> 15) & 1
    dst_xn_reg = (dst_brief >> 12) & 7
    dst_xn_wl  = (dst_brief >> 11) & 1
    dst_d8     = dst_brief & 0xFF
    if dst_d8 >= 0x80: dst_d8 -= 0x100

    dst_xn_val = _get_an_d(dst_xn_reg) if dst_xn_da else ini[f'd{dst_xn_reg}'] & 0xFFFFFFFF

    dst_reg    = (opcode >> 9) & 7
    dst_an_val = _get_an_d(dst_reg)
    siz_bytes  = {1: 1, 2: 4, 3: 2}[f_group_d]

    # Same-register An conflict: src (An)+/-(An) on the same An as dst_An
    # and/or dst_Xn. The source auto-increment/decrement is applied — as
    # part of evaluating the source operand — before the destination EA is
    # computed, so the indexed-dst EA must use the *updated* An, not the
    # initial value, wherever that An also appears as dst_An or dst_Xn.
    if ea_mode_r in (3, 4):
        step = 2 if (siz_bytes == 1 and ea_reg_r == 7) else siz_bytes
        delta = step if ea_mode_r == 3 else -step
        if ea_reg_r == dst_reg:
            dst_an_val = (dst_an_val + delta) & 0xFFFFFFFF
        if dst_xn_da and ea_reg_r == dst_xn_reg:
            dst_xn_val = (dst_xn_val + delta) & 0xFFFFFFFF

    if not dst_xn_wl:
        dst_xn_val &= 0xFFFF
        if dst_xn_val >= 0x8000: dst_xn_val -= 0x10000

    ea_68000 = (dst_an_val + dst_xn_val                       + dst_d8) & 0xFFFFFF
    ea_68030 = (dst_an_val + dst_xn_val * (1 << dst_scale)    + dst_d8) & 0xFFFFFF
    return {'ea_68000': ea_68000, 'ea_68030': ea_68030, 'siz_bytes': siz_bytes}


def get_scale_remap(test):
    """
    Return a list of 0-2 remap dicts: {'ea_68000': int, 'ea_68030': int, 'siz_bytes': int}
    The 68000 ignores scale bits (always ×1); the 68030 applies ×1/×2/×4/×8.
    build_patches() uses this to copy source bytes from EA_68000 to EA_68030 so
    the DUT reads the expected data; compare() uses it to redirect expected memory
    writes from EA_68000 to EA_68030 (for RMW-destination instructions).

    Source (opcode's own mode=6/mode=7,reg=3 EA field) and, for MOVE groups,
    destination (bits[8:6]==6) are independently indexed EAs — either, both, or
    neither may need a remap (non-zero scale, brief extension word). Both are
    checked and any that apply are returned together.
    """
    ini    = test['initial']
    opcode = ini['prefetch'][0]

    ea_mode_r  = (opcode >> 3) & 7
    ea_reg_r   =  opcode        & 7
    is_mode6   = ea_mode_r == 6
    is_pc_idx  = ea_mode_r == 7 and ea_reg_r == 3

    instr_src = ini['pc'] - 4
    rm        = {a: v for a, v in ini['ram']}

    dst_remap = _dst_indexed_remap(test)

    if not (is_mode6 or is_pc_idx):
        return [dst_remap] if dst_remap else []

    f_group = (opcode >> 12) & 0xF
    f_dir   = (opcode >>  8) & 0x1
    f_ss    = (opcode >>  6) & 0x3
    f_dn    = (opcode >>  9) & 0x7
    f_reg   =  opcode        & 0x7

    # MOVEM (group 4, f_dn=4 store/6 load, f_ss>=2): the register-mask word precedes
    # the brief extension word, so the brief is at opcode+4, not opcode+2.
    # f_dir=0 required: CHK ea,Dn (f_group==4, f_dir=1 always) uses f_dn as the
    # *tested register* (any value 0-7) — CHK D4/D6 with word size collides with
    # MOVEM's f_dn∈{4,6} marker unless f_dir disambiguates them (MOVEM: f_dir=0
    # always; see the matching comment in get_operand_ea()).
    is_movem = (f_group == 4 and not f_dir and f_dn in (4, 6) and f_ss >= 2)

    # Locate brief extension word
    # (instr_src and rm already computed above)
    # f_dir=0 required: dynamic bit-ops (BTST/BCHG/BCLR/BSET Dn,ea) share the
    # f_group==0 + mode-6 encoding but have f_dir=1 and no immediate word — see
    # the matching comment in build_patches() above.
    if f_group == 0 and not f_dir and (f_dn not in (4, 7)) and f_ss != 3:
        ea_off    = 6 if f_ss == 2 else 4
        brief_ext = (rm.get(instr_src + ea_off, 0) << 8) | rm.get(instr_src + ea_off + 1, 0)
    elif f_group == 0 and not f_dir and f_dn == 4:
        # Static BTST/BCHG/BCLR/BSET #n,ea (f_dn=4 is the "static" marker, not a
        # bit-count register). A bit-number word precedes the EA's own extension
        # word here (we already know we're mode6/pc_idx to have reached this
        # function), so the brief ext is the *second* extension word, not the
        # first — read it from RAM at +4, never from prefetch[1] (that's the
        # bit-number word).
        ea_off    = 4
        brief_ext = (rm.get(instr_src + ea_off, 0) << 8) | rm.get(instr_src + ea_off + 1, 0)
    elif is_movem:
        ea_off    = 4  # skip opcode + register-mask word
        if len(ini['prefetch']) > 2:
            brief_ext = ini['prefetch'][2]
        else:
            # Harte format has only 2 prefetch words; brief ext is at instr_src+4 in ram
            brief_ext = (rm.get(instr_src + ea_off, 0) << 8) | rm.get(instr_src + ea_off + 1, 0)
    elif len(ini['prefetch']) > 1:
        ea_off    = 2
        brief_ext = ini['prefetch'][1]
    else:
        return [dst_remap] if dst_remap else []

    # Full extension word (bit 8 = 1): 68030 computes different EA; can't remap
    if (brief_ext >> 8) & 1:
        return [dst_remap] if dst_remap else []

    scale = (brief_ext >> 9) & 3
    if scale == 0:
        return [dst_remap] if dst_remap else []

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

    xn_val  = _get_an(xn_reg) if xn_da else ini[f'd{xn_reg}'] & 0xFFFFFFFF
    if not xn_wl:
        xn_val &= 0xFFFF
        if xn_val >= 0x8000:
            xn_val -= 0x10000

    # Determine transfer size.  Each instruction family encodes size differently:
    #   ADDA/SUBA/CMPA (groups 9,D,B): f_ss==3; bit 8 selects word(0) vs long(1).
    #   MOVEM (group 4):               f_ss==2 → word, f_ss==3 → long.
    #   MOVE (groups 1,2,3):           group encodes size (1=byte, 2=long, 3=word).
    #   Memory-mode shifts (group E):  always word (bit 8 is direction, not size).
    #   MULU/MULS/DIVU/DIVS (groups 8,C): f_ss==3 is their own signature bit
    #     pattern (not a size field) — operand is always a 16-bit word.
    #   All others:                    f_ss=0→byte, 1→word, 2→long.
    #   Group 4, f_ss==3: MOVE SR/CCR to/from memory — SR/CCR are always 16-bit.
    if f_group in (0x9, 0xD, 0xB) and f_ss == 3:
        siz_bytes = 4 if (opcode >> 8) & 1 else 2
    elif f_group == 4 and f_ss == 3:
        siz_bytes = 2   # MOVE SR/CCR ↔ ea: SR and CCR are 16-bit
    elif is_movem:
        # siz_bytes = total transfer: bytes-per-reg × number of set bits in register mask
        siz_bytes = (4 if f_ss == 3 else 2) * bin(ini['prefetch'][1]).count('1')
    elif f_group in (1, 2, 3):
        siz_bytes = {1: 1, 2: 4, 3: 2}[f_group]
    elif f_group == 0xE:
        siz_bytes = 2  # memory-mode shifts always operate on word
    elif f_group in (0x8, 0xC) and f_ss == 3:
        siz_bytes = 2  # MULU/MULS/DIVU/DIVS: always word, f_ss==3 isn't a size field
    else:
        siz_bytes = {0: 1, 1: 2, 2: 4}.get(f_ss, 1)

    if is_mode6:
        an_val = _get_an(f_reg)
    else:  # (d8,PC,Xn): base is PC at the extension word
        an_val = (instr_src + ea_off) & 0xFFFFFFFF

    ea_68000 = (an_val + xn_val            + d8) & 0xFFFFFF
    ea_68030 = (an_val + xn_val * (1 << scale) + d8) & 0xFFFFFF

    src_remap = {'ea_68000': ea_68000, 'ea_68030': ea_68030, 'siz_bytes': siz_bytes}
    return [src_remap, dst_remap] if dst_remap else [src_remap]


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

    pf = ini.get('prefetch', [])

    def rw(off):
        # Read one big-endian instruction word from RAM.  Fall back to ini['prefetch']
        # for offsets 0 and 2 (first two words) when they are absent from ini['ram'],
        # which is normal for json.gz tests where those words were in the CPU pipeline.
        hi = rm.get(instr_src + off, None)
        lo = rm.get(instr_src + off + 1, None)
        if hi is not None and lo is not None:
            return (hi << 8) | lo
        if off == 0 and pf:         return pf[0]
        if off == 2 and len(pf) > 1: return pf[1]
        return 0

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
    if ea_mode == 7 and ea_reg == 4:   # #imm — no memory access
        return None

    # Transfer size in bytes.
    # MOVEM: f_ss encodes per-register size (2=word, 3=long); total = size × num_regs.
    # ADDA/SUBA/CMPA (f_ss==3): bit 8 (f_dir) selects word vs long.
    # f_dir=0 required: MOVEM's f_dn∈{4,6} marker is bits[11:9]="1,d,0"/"1,d,1" with
    # bit8(f_dir) always 0 — but CHK ea,Dn (f_group==4, f_dir=1 always) uses f_dn as
    # the *tested register* (any value 0-7), so CHK D4/D6 with word size collides
    # with this pattern unless f_dir disambiguates them.
    if f_group == 4 and not f_dir and f_dn in (4, 6) and f_ss >= 2:
        mask = pf[1] if len(pf) > 1 else rw(2)
        siz_bytes = (4 if f_ss == 3 else 2) * bin(mask).count('1')
    elif f_group in (0x8, 0xC) and f_ss == 3:
        # MULU/MULS/DIVU/DIVS: f_ss==3 is their own signature bit pattern,
        # not a size field (f_dir here selects signed/unsigned, not word/long)
        # — the memory operand is always a 16-bit word.
        siz_bytes = 2
    elif f_ss == 3:
        siz_bytes = 4 if f_dir else 2
    else:
        siz_bytes = {0: 1, 1: 2, 2: 4}[f_ss]

    # Byte offset within the instruction to the first EA extension word.
    # Group-0 immediate ops (ADDI/SUBI/ORI/ANDI/EORI) have an immediate word
    # (byte/word size) or longword (long size) before the EA extension words —
    # but only when f_dir=0; dynamic bit-ops (BTST/BCHG/BCLR/BSET Dn,ea) share
    # the f_group==0 encoding with f_dir=1 and have no immediate word at all.
    if f_group == 0 and not f_dir and f_dn not in (4, 7) and f_ss != 3:
        ea_off = 2 + (4 if f_ss == 2 else 2)
    elif f_group == 0 and not f_dir and f_dn in (4, 7):
        return None     # static #n bit-ops / MOVES: non-trivial layout, skip
    elif f_group == 4 and not f_dir and f_dn in (4, 6) and f_ss >= 2:
        ea_off = 4      # MOVEM: opcode word + register-mask word before EA extension
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
        remap_list = get_scale_remap(test)
        if remap_list:
            ea = remap_list[0]['ea_68030']
        else:
            brief  = rw(ea_off)
            xn_da  = (brief >> 15) & 1
            xn_reg = (brief >> 12) & 7
            xn_wl  = (brief >> 11) & 1
            scale  = 0 if (brief >> 8) & 1 else (brief >> 9) & 3
            d8     =  brief & 0xFF
            if d8 >= 0x80: d8 -= 0x100
            xn_sel = get_an(xn_reg) if xn_da else ini[f'd{xn_reg}'] & 0xFFFFFFFF
            if not xn_wl:
                xn_sel &= 0xFFFF
                if xn_sel >= 0x8000: xn_sel -= 0x10000
            ea = (an + xn_sel * (1 << scale) + d8) & 0xFFFFFFFF
    elif ea_mode == 7:
        # PC value used for EA computation = address of the extension word
        pc_for_ea = instr_src + ea_off
        if ea_reg == 0:     # (xxx).W
            w  = rw(ea_off)
            ea = ((w - 0x10000) if w >= 0x8000 else w) & 0xFFFFFFFF
        elif ea_reg == 1:   # (xxx).L
            ea = (rw(ea_off) << 16) | rw(ea_off + 2)
        elif ea_reg == 2:   # (d16,PC)
            d16 = rw(ea_off)
            if d16 >= 0x8000: d16 -= 0x10000
            ea = (pc_for_ea + d16) & 0xFFFFFFFF
        elif ea_reg == 3:   # (d8,PC,Xn) brief extension
            remap_list = get_scale_remap(test)
            if remap_list:
                ea = remap_list[0]['ea_68030']
            else:
                brief  = rw(ea_off)
                xn_da  = (brief >> 15) & 1
                xn_reg = (brief >> 12) & 7
                xn_wl  = (brief >> 11) & 1
                # If bit8=1 (full extension word), we patch scale to 0 in the
                # instruction bytes so the DUT matches the 68000 reference.
                scale  = 0 if (brief >> 8) & 1 else (brief >> 9) & 3
                d8     =  brief & 0xFF
                if d8 >= 0x80: d8 -= 0x100
                xn_sel = get_an(xn_reg) if xn_da else ini[f'd{xn_reg}'] & 0xFFFFFFFF
                if not xn_wl:
                    xn_sel &= 0xFFFF
                    if xn_sel >= 0x8000: xn_sel -= 0x10000
                ea = (pc_for_ea + xn_sel * (1 << scale) + d8) & 0xFFFFFFFF
        else:
            return None
    else:
        return None

    return ea & 0xFFFFFF, siz_bytes


def patches_to_hex(patches):
    """
    Convert a {byte_addr: byte_val} dict to $readmemh format.
    Groups consecutive bytes into 32-bit words and emits @word_addr entries.
    Addresses use the full 22-bit word index (matching testbench mem_idx = ext_a[23:2])
    so all entries map correctly in the 4M-word / 16 MB memory model.
    """
    if not patches:
        return ''

    # Group bytes into 32-bit words: word_addr = (byte_addr >> 2) & 0x3FFFFF
    words = {}
    for baddr, bval in patches.items():
        waddr = (baddr >> 2) & 0x3FFFFF   # 22-bit word index for 24-bit space
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

    # Bcc/BRA/BSR with 0xFF byte displacement: 68000 treats as -1 (branch to PC+1 =
    # odd address → address error). 68030 treats 0xFF as 32-bit displacement follows.
    # These are structurally incompatible; skip.
    if ((opcode >> 12) == 0b0110) and ((opcode & 0xFF) == 0xFF):
        return False, 'Bcc 0xFF byte disp (68000/68030 incompatibility)'

    # ANDI/ORI/EORI to SR where the result clears S (bit 13): after the instruction
    # the CPU enters user mode, then STOP #$2700 triggers a privilege violation →
    # the testbench loops. Skip when initial S=1 and operation clears it.
    if opcode in (0x027C, 0x007C, 0x0A7C):   # ANDItoSR, ORItoSR, EORItoSR
        ini_sr    = ini['sr'] & 0xFFFF
        pf1       = ini['prefetch'][1]         # immediate word
        if opcode == 0x027C:    # ANDI: clears if mask bit 13 = 0
            result_s = (ini_sr >> 13 & 1) and (pf1 >> 13 & 1)
        elif opcode == 0x007C:  # ORI: always sets S
            result_s = 1
        else:                   # EORI: flips S bit
            result_s = ((ini_sr >> 13) ^ (pf1 >> 13)) & 1
        if (ini_sr >> 13 & 1) and not result_s:
            return False, 'xRItoSR clears S bit (privilege mode change causes STOP privilege violation)'

    # MOVE EA, SR (0x46C0–0x46FE) and MOVE #imm, SR (0x46FC) that switch to user
    # mode (final S bit = 0): after the instruction STOP #$2700 is a privilege
    # violation → testbench loops.  Skip these.
    if (opcode & 0xFFC0) == 0x46C0:          # MOVE EA, SR family
        if not (final['sr'] & 0x2000):
            return False, 'MOVE EA,SR clears S bit (user mode, STOP privilege violation)'

    # Misaligned EA: word or longword access to an odd address causes a 68000/68030
    # address error.  The reference sim then runs the exception handler, landing
    # final.pc at a random location — the test cannot be replayed in our harness.
    ea_info = get_operand_ea(test)
    if ea_info is not None:
        ea, ea_siz = ea_info
        if ea_siz >= 2 and (ea & 1):
            return False, 'misaligned EA'
        # Check all addresses in the range (handles 24-bit wrap-around for MOVEM)
        if any(((ea + off) & 0xFFFFFF) < INIT_CODE_END
               for off in range(0, max(ea_siz, 1), 2 if ea_siz >= 2 else 1)):
            return False, f'EA {ea:#08x} in init region'

    # Indexed EA (mode=6) with non-zero scale: the 68030 computes a different EA
    # than the 68000 reference.  get_scale_remap() handles the remapping so these
    # tests can run — skip only when EA_68030 is problematic.
    for remap in get_scale_remap(test):
        ea1, nb = remap['ea_68030'], remap['siz_bytes']
        # Odd-address word/longword → 68030 address error; skip.
        if nb >= 2 and (ea1 & 1):
            return False, f'EA_68030 {ea1:#08x} misaligned (would be addr error)'
        # EA_68030 in our init code region → data conflict.
        if any((ea1 + i) & 0xFFFFFF in range(0x000000, INIT_CODE_END) for i in range(nb)):
            return False, f'EA_68030 {ea1:#08x} in init region (scale remap)'

    # Instruction at original address would land in our init region
    instr_src = ini['pc'] - 4
    instr_len = final['pc'] - ini['pc']

    # EA range must not overlap the STOP+NOP runway placed immediately after the instruction.
    # Applies to loads (e.g. MOVEM (d16,PC)) whose EA lands inside the runway.
    #
    # JMP/JSR are exempt: get_operand_ea() returns their *jump target* as "ea", and
    # for those two instructions build_patches() deliberately places the STOP+NOP
    # runway starting AT that target (instr_len = final_pc - ini_pc reduces to
    # final_pc - 4 = the jump target for any control-transfer instruction, so
    # stop_start always numerically equals ea here) — so execution halts the instant
    # the jump lands. That's the intended design, not a data conflict: JMP/JSR never
    # read or write memory at their EA, so there is no operand data to protect.
    # Without this exemption every JMP/JSR test trivially "overlaps" itself and the
    # suite skips 100% of the time.
    f_dn_jj  = (opcode >> 9) & 7
    f_dir_jj = (opcode >> 8) & 1
    f_ss_jj  = (opcode >> 6) & 3
    is_jmp_jsr = (not f_dir_jj) and f_dn_jj == 7 and f_ss_jj in (2, 3) and \
                 ((opcode >> 12) & 0xF) == 4
    if ea_info is not None and not is_jmp_jsr:
        ea, ea_siz = ea_info
        stop_start = (instr_src + instr_len) & 0xFFFFFF
        stop_end   = (stop_start + 4 + 8 * 2) & 0xFFFFFF  # STOP(4) + 8 NOPs(2 each)
        if any(stop_start <= ((ea + off) & 0xFFFFFF) < stop_end
               for off in range(0, max(ea_siz, 1), 2 if ea_siz >= 2 else 1)):
            return False, f'EA {ea:#08x} overlaps STOP runway'

    # Backstop for complex EA modes that get_operand_ea() returns None for:
    # if instr_len is still wild, the reference took an exception (almost certainly
    # a misaligned EA that we couldn't compute statically). Only applies when
    # ea_info is None — when get_operand_ea() DID return a concrete EA (e.g. JMP/JSR,
    # whose "ea" is the jump target), its own misalignment was already checked above,
    # and instr_len = final_pc - ini_pc is *expected* to be "wild" for any
    # control-transfer instruction (PC legitimately jumps elsewhere) — that's not a
    # signal of an exception, so this backstop must not re-fire on it.
    if ea_info is None and not (1 <= instr_len <= 24):
        return False, 'misaligned EA'

    if instr_src < INIT_CODE_END:
        return False, f'instruction at {instr_src:#x} overlaps init region'

    # Skip tests where the instruction writes into our init code region.
    ini_map24  = {a & 0xFFFFFF: v for a, v in ini['ram']}
    fin_map24  = {a & 0xFFFFFF: v for a, v in final['ram']}
    init_range = range(0x000000, INIT_CODE_END)
    for a24, fin_v in fin_map24.items():
        if a24 in init_range and ini_map24.get(a24) != fin_v:
            return False, f'instruction writes to init region {a24:#06x}'

    # Check for aliasing: two byte addresses from different 32-bit aligned words
    # must not share the same 22-bit word index (testbench uses ext_a[23:2]).
    # All patch addresses are already in 24-bit space so genuine conflicts are
    # extremely rare; this catches the edge case where init code and test data
    # share bits [23:2] — i.e. fall within the same 4-byte aligned word.
    try:
        patches, _ = build_patches(test)
    except Exception:
        return True, 'ok'   # let it try and fail at run time
    word_owners = {}
    for baddr in patches:
        waddr = (baddr >> 2) & 0x3FFFFF   # 22-bit word index for 24-bit space
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
