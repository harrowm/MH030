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


def _movec_a7_vbr():
    """MOVEC A7, VBR (opcode 0x4E7B + ext word: A/D=1,reg=111,Rc=0x801)"""
    return _word(0x4E7B) + _word(0xF801)


def _movec_a7_msp():
    """MOVEC A7, MSP (opcode 0x4E7B + ext word: A/D=1,reg=111,Rc=0x803)"""
    return _word(0x4E7B) + _word(0xF803)


# Relocated VBR base for RTS/RTE/RTR tests (see is_ret_taken in build_patches())
# and for causes_priv_mode_drop() tests (vector 8, Privilege Violation).
# Sits safely between our init code (< INIT_CODE_END) and the typical test
# instruction address (~0xC00 across the whole Harte corpus).
RELOC_VBR = 0x000100

PRIV_VEC_OFFSET   = 32            # vector 8 * 4 bytes
PRIV_HANDLER_ADDR = RELOC_VBR + 0x40


def causes_priv_mode_drop(test):
    """True if the *tested instruction itself* writes a new SR with S=0,
    ending OUR harness (which always force-starts supervisor regardless of
    ini['sr']) in user mode. See build_patches()'s vector-8 handler install
    and run_harte.compare()'s A7 compensation."""
    ini    = test['initial']
    final  = test['final']
    opcode = ini['prefetch'][0]

    if opcode in (0x027C, 0x007C, 0x0A7C):   # ANDI/ORI/EORI to SR
        ini_sr = ini['sr'] & 0xFFFF
        pf1    = ini['prefetch'][1]
        if opcode == 0x027C:
            result_s = (ini_sr >> 13 & 1) and (pf1 >> 13 & 1)
        elif opcode == 0x007C:
            result_s = 1
        else:
            result_s = ((ini_sr >> 13) ^ (pf1 >> 13)) & 1
        return bool((ini_sr >> 13 & 1) and not result_s)

    if (opcode & 0xFFC0) == 0x46C0:          # MOVE EA,SR family
        return not (final['sr'] & 0x2000)

    if opcode == 0x4E73:                      # RTE
        return not (final['sr'] & 0x2000)

    return False


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

    # RTE (0x4E73) needs a synthesized frame-format word ahead of the Harte
    # test's own stack data. The Harte corpus is captured on 68000 hardware,
    # whose RTE frame is just {SR, PC} (3 words, no format field — a 68010+
    # concept). Our 68030 RTL's RTE unconditionally reads a leading longword
    # as {format/vector nibble, SR} first (m68030_exc.sv / eu_seq.sv's
    # eu_is_rte handling), so replaying 68000 stack bytes as-is would have the
    # 68030 misinterpret the top SR byte as a format code and misparse
    # everything after. Since we control the initial stack contents entirely
    # (via build_patches(), not the reference), we can make this replayable:
    # place a format-$0 word (0x0000 — valid, 0 extra bytes per
    # rte_frame_extra()) immediately below the test's own {SR,PC} bytes, and
    # start the CPU's SSP 2 bytes lower so RTE reads {0x0000, SR} as its first
    # longword exactly where the format word now lives, then continues into
    # the unmodified SR/PC bytes already placed by the "test data" patch pass
    # below. Final SSP naturally comes out matching the reference's
    # ini_ssp+6 (68000: SR+PC popped) once shifted by this same 2-byte offset,
    # since our frame is 2 bytes longer (format word + SR + PC = 8 bytes vs.
    # the reference's SR + PC = 6) — no extra final-SSP adjustment needed.
    is_rte = ini['prefetch'][0] == 0x4E73
    a7_init_val = (a7_val - 2) & 0xFFFFFFFF if is_rte else a7_val

    # RTS/RTE/RTR (is_ret_taken, see can_run()'s matching definition): these
    # can restore an odd PC, which a real 68030 correctly Address-Error-traps
    # on (unlike misaligned *data* access — see feedback_harte_68000_vs_68030.md).
    # The trap reads the vector-3 table entry at VBR+12, which at VBR=0
    # (the reset default) is address 0xC — squarely inside our own init code
    # (RESET_PC=8 onward), so the read would return corrupted garbage (part of
    # our own D0-load instruction's immediate bytes) instead of a real vector.
    # Relocate VBR via MOVEC to a safe, empty region (RELOC_VBR) so the vector-3
    # entry can be placed somewhere real, harmless when no address error fires.
    is_ret_taken = ini['prefetch'][0] in (0x4E73, 0x4E75, 0x4E77)

    priv_drop = causes_priv_mode_drop(test)

    # ── Reset vectors ────────────────────────────────────────────────────────
    patch(0x000000, _long(a7_init_val))
    patch(0x000004, _long(RESET_PC))

    # ── Init code ────────────────────────────────────────────────────────────
    code = bytearray()
    for n in range(8):
        code += _move_l_imm_dn(n, ini[f'd{n}'])
    for n in range(7):
        code += _movea_l_imm_an(n, ini[f'a{n}'])
    code += _movea_l_imm_a7(a7_init_val)
    # Also seed MSP with the same value as ISP (which the line above just set,
    # since M=0 is the reset default and stays 0 until our own SR force
    # below). The Harte corpus is captured on 68000 hardware, which has no
    # M/ISP/MSP concept at all (a real 68020+ feature) -- so a test's own
    # immediate/SR value can carry an M-bit setting the reference never
    # exercised (e.g. EORI #imm,SR with the immediate's bit 12 set). Our
    # correctly-68030-accurate RTL DOES toggle M in that case, and without
    # this, MSP would be left at its power-on-reset value of 0 -- garbage
    # that corrupts any subsequent exception's frame push (confirmed via
    # direct trace: master_mode read 1 mid-test though M was never meant to
    # change, exc_ssp_in read msp_out=0, and the pushed frame landed at
    # 0xFFFFFC, wrapping down from address 0). Unconditional, not just for
    # priv_drop cases below -- an M-bit flip that leaves S=1 (supervisor
    # mode throughout) would corrupt ordinary A7 reads the same way, not
    # just crash a Privilege Violation handler.
    code += _movec_a7_msp()
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
    if is_ret_taken or priv_drop:
        code += _movea_l_imm_a7(RELOC_VBR)  # A7 = new VBR (temp borrow)
        code += _movec_a7_vbr()             # MOVEC A7, VBR
    code += _movea_l_imm_a7(a7_init_val)  # restore A7 = ssp / original value
    code += _jmp_l(instr_src)  # jump to instruction at its original address

    assert RESET_PC + len(code) <= INIT_CODE_END, (
        f"init code overflows: ends at {RESET_PC + len(code):#x}")

    # ── Vector-3 (Address Error) table entry, relocated ───────────────────────
    # Points at the same target our own STOP+NOP runway already lands on
    # (instr_src + instr_len == final.pc - 4 for any control-transfer
    # instruction, including the reference's own address-error redirect) — so
    # if the DUT correctly takes the trap, it lands exactly where every other
    # passing control-transfer test already expects execution to stop.
    if is_ret_taken:
        patch(RELOC_VBR + 12, _long(instr_src + instr_len))

    # ── Vector-8 (Privilege Violation) table entry + handler ──────────────────
    if priv_drop:
        patch(RELOC_VBR + PRIV_VEC_OFFSET, _long(PRIV_HANDLER_ADDR))
        patch(PRIV_HANDLER_ADDR, _word(0x4E72) + _word(0x2700))  # STOP #$2700

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
    # Fixed-encoding no-operand opcodes alias ea_mode=6 — see the matching guard
    # in get_operand_ea()/get_scale_remap(). Without this exclusion the block
    # below would read the *next*, unrelated instruction's opcode byte (whatever
    # happens to follow in the stream) as if it were this instruction's own
    # extension word, and potentially corrupt it.
    is_misc_no_ea_w = opcode_w in (0x4E70, 0x4E71, 0x4E73, 0x4E75, 0x4E76, 0x4E77)
    if not is_misc_no_ea_w and (ea_mode_w == 6 or (ea_mode_w == 7 and ea_reg_w == 3)):
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

    # ── RTE synthesized format word (see a7_init_val comment above) ──────────
    # Placed after the ini['ram'] test-data pass so it always wins; a7_val-2
    # is outside the range the reference test itself ever populates (its own
    # stack data starts at a7_val), so this can't collide with real test bytes.
    if is_rte:
        patch(a7_init_val, _word(0x0000))

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

    # Fixed-encoding no-operand opcodes (RESET/NOP/RTE/RTS/TRAPV/RTR) alias
    # ea_mode=6/ea_reg=3 in their low bits despite having no EA at all — see the
    # matching guard in get_operand_ea(). Without this exclusion, the mode6/
    # pc_idx branch below would read ini['prefetch'][1] (just the *next*,
    # unrelated instruction's opcode word, already in the pipeline) and
    # misinterpret its bits as a brief extension word's scale/index/displacement
    # fields, computing a bogus scale remap from essentially random data.
    if opcode in (0x4E70, 0x4E71, 0x4E73, 0x4E75, 0x4E76, 0x4E77):
        return []

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
    elif is_movem:
        # siz_bytes = total transfer: bytes-per-reg × number of set bits in register mask.
        # Must be checked before the group==4/f_ss==3 "MOVE SR/CCR" case below —
        # MOVEM.l's own encoding also has f_ss==3 (bits[7:6]=11 selects long size),
        # so without this ordering MOVEM.l was misclassified as MOVE SR/CCR and got
        # siz_bytes=2 instead of 4*popcount(mask), truncating the scale-remap byte
        # range to 2 bytes and leaving the rest of the transfer's expected-write
        # addresses un-redirected from EA_68000 to EA_68030 in compare().
        siz_bytes = (4 if f_ss == 3 else 2) * bin(ini['prefetch'][1]).count('1')
    elif f_group == 4 and f_ss == 3:
        siz_bytes = 2   # MOVE SR/CCR ↔ ea: SR and CCR are 16-bit
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

    # Fixed-encoding "miscellaneous" no-operand opcodes (0100 1110 0111 0xxx):
    # RESET/NOP/RTE/RTS/TRAPV/RTR. Their low 3 bits happen to alias the mode/reg
    # EA sub-field used by every other instruction in this decode table (e.g.
    # RTE=0x4E73 decodes as ea_mode=6,ea_reg=3 — a real indexed-EA encoding for
    # any *other* opcode), but these fixed opcodes have no EA operand at all.
    # Without this explicit exclusion they fell through to the generic EA
    # decode below and produced a bogus non-None "EA" computed from bits that
    # aren't actually a mode/reg field, corrupting can_run()'s skip logic.
    if opcode in (0x4E70, 0x4E71, 0x4E73, 0x4E75, 0x4E76, 0x4E77):
        return None

    # MOVEP (0000 ddd1 oo001 aaa, opmode oo: 00=word-read,01=long-read,
    # 10=word-write,11=long-write): its fixed bits[5:3]="001" alias ea_mode=1
    # ("An register direct, no memory operand") in the generic decode below,
    # despite MOVEP *always* being memory-referencing — its addressing is a
    # fixed (d16,An) form encoded outside the normal mode/reg field entirely.
    # Without this explicit case, MOVEP's EA (and thus the "lands in our init
    # code region" collision check) was never computed at all — found via a
    # full-corpus retest (Phase 102) turning up 1 residual failure each in
    # MOVEP.w/.l where the (d16,An) EA happened to land inside the harness's
    # own init-code region, silently returning corrupted data instead of the
    # test's own correctly-supplied bytes there (same shape as the Phase 99
    # TRAP-vector collision and Phase 100 Address-Error-vector collision —
    # this project's recurring "an operand address isn't range-checked
    # against our own low-address init code" bug class).
    if (opcode & 0xF138) == 0x0108:
        movep_an  = opcode & 0x7
        movep_d16 = rw(2)
        if movep_d16 >= 0x8000:
            movep_d16 -= 0x10000
        an_val = ((ini['ssp'] if (ini['sr'] & 0x2000) else ini['usp'])
                  if movep_an == 7 else ini[f'a{movep_an}']) & 0xFFFFFFFF
        movep_ea = (an_val + movep_d16) & 0xFFFFFFFF
        # Byte-interleaved footprint: word touches [ea, ea+2], long touches
        # [ea, ea+6] — both step by 2, matching the range(0,siz,2) convention
        # can_run()'s overlap checks already use for word/long-sized EAs.
        movep_is_long = (opcode >> 6) & 1
        return movep_ea & 0xFFFFFF, (7 if movep_is_long else 3)

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

    # ANDI/ORI/EORI to SR, MOVE <ea>,SR, and RTE that drop S to 0 (switch OUR
    # execution to user mode) used to be skipped here, since our runway's own
    # STOP -- itself supervisor-only -- faults instead of completing once the
    # tested instruction drops S to 0. Fixed via a vector-8 (Privilege
    # Violation) handler installed by build_patches() when
    # causes_priv_mode_drop() is true -- see that function and the vector-8
    # block in build_patches() for the mechanism (also needs MSP seeded,
    # see the "Also seed MSP" comment in build_patches()'s init code -- the
    # real root cause here turned out to be a missing register-bank seed,
    # not just a missing exception handler).

    # Misaligned EA: word or longword access to an odd address causes a 68000/68030
    # address error.  The reference sim then runs the exception handler, landing
    # final.pc at a random location — the test cannot be replayed in our harness.
    #
    # MOVEP is exempt: unlike a normal word/long transfer, it's semantically a
    # sequence of individual BYTE accesses at EA, EA+2, EA+4, EA+6 — each one
    # inherently byte-aligned, so an odd EA is completely legal and never
    # faults (get_operand_ea() returns siz_bytes=3/7 for MOVEP purely to
    # describe its footprint span for the init-region/runway overlap checks
    # below, not as a real word/long access size).
    is_movep = (opcode & 0xF138) == 0x0108
    ea_info = get_operand_ea(test)
    if ea_info is not None:
        ea, ea_siz = ea_info
        if ea_siz >= 2 and (ea & 1) and not is_movep:
            return False, 'misaligned EA'
        # Check all addresses in the range (handles 24-bit wrap-around for MOVEM)
        if any(((ea + off) & 0xFFFFFF) < INIT_CODE_END
               for off in range(0, max(ea_siz, 1), 2 if ea_siz >= 2 else 1)):
            return False, f'EA {ea:#08x} in init region'

    # JMP/JSR: opcode signature, computed early so the scale-remap check below
    # can special-case it.
    f_dn_jj  = (opcode >> 9) & 7
    f_dir_jj = (opcode >> 8) & 1
    f_ss_jj  = (opcode >> 6) & 3
    is_jmp_jsr = (not f_dir_jj) and f_dn_jj == 7 and f_ss_jj in (2, 3) and \
                 ((opcode >> 12) & 0xF) == 4

    # LEA (0100 aaa 111 mmm rrr: group 4, f_dir=1, f_ss=11) / PEA (0100 1000 01
    # mmm rrr: group 4, f_dir=0, f_dn=100, f_ss=01) — same issue as JMP/JSR:
    # the *result* (the address itself, loaded into An or pushed to the stack)
    # is the EA, not a value read from it, so a scale mismatch changes the
    # result directly and unreplicably rather than just changing which byte
    # gets touched.
    is_lea = (opcode >> 12) == 0x4 and f_dir_jj and f_ss_jj == 3
    is_pea = (opcode >> 12) == 0x4 and not f_dir_jj and f_dn_jj == 4 and f_ss_jj == 1

    # Indexed EA (mode=6) with non-zero scale: the 68030 computes a different EA
    # than the 68000 reference.  get_scale_remap() handles the remapping so these
    # tests can run — skip only when EA_68030 is problematic.
    #
    # JMP/JSR/LEA/PEA are a special case: their "EA" *is* the instruction's own
    # result (new PC, or the loaded/pushed address itself), not an operand to
    # patch/redirect. For JMP/JSR, build_patches() places the STOP+NOP runway at
    # final.pc (the 68000 reference's own, *unscaled* landing address) — for
    # any scale!=0 JMP/JSR, our correctly-68030-scaled RTL computes a genuinely
    # different jump target (ea_68030 != ea_68000) and lands somewhere the
    # runway was never placed, walking off into whatever uninitialized memory
    # happens to be there and hanging (this is the JMP/JSR indexed-EA TIMEOUT
    # investigated in Phase 94/95 — confirmed via $display trace: RTL correctly
    # computes ea_68030 per the scale field, e.g. 0x4d5e9ede for a scale=4 case,
    # then issues zero further bus requests because that address is unmapped
    # test-harness territory). LEA/PEA don't touch the bus at their EA at all —
    # they just materialize it (into An, or onto the stack) — so the reference's
    # "expected" register/stack value is ea_68000, while our RTL, using correct
    # 68030 scale arithmetic, produces ea_68030: a genuine, permanent value
    # mismatch whenever scale != 0, confirmed via LEA test #116 (`LEA
    # (d8,A0,Xn),A2`): DUT wrote ea_68030 (0x4315e2), reference expected
    # ea_68000 (0x48131e) — see Phase 97. Unlike MULS/MULU/DIVS/DIVU (Phase 94),
    # none of these four are limited to the odd-address/Address-Error subset —
    # ANY scale mismatch sends our RTL to a different address (or value) than
    # the one the reference used, so it's unreplicable whenever scale != 0.
    for remap in get_scale_remap(test):
        ea1, nb = remap['ea_68030'], remap['siz_bytes']
        if is_jmp_jsr:
            return False, f'JMP/JSR scale!=0: EA_68030 {ea1:#08x} != EA_68000 (unreplicable, see Phase 95)'
        if is_lea or is_pea:
            return False, f'LEA/PEA scale!=0: EA_68030 {ea1:#08x} != EA_68000 (unreplicable, see Phase 97)'
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
    if ea_info is not None and not is_jmp_jsr:
        ea, ea_siz = ea_info
        stop_start = (instr_src + instr_len) & 0xFFFFFF
        stop_end   = (stop_start + 4 + 8 * 2) & 0xFFFFFF  # STOP(4) + 8 NOPs(2 each)
        if any(stop_start <= ((ea + off) & 0xFFFFFF) < stop_end
               for off in range(0, max(ea_siz, 1), 2 if ea_siz >= 2 else 1)):
            return False, f'EA {ea:#08x} overlaps STOP runway'

    # ADDX/SUBX memory form (-(Ay),-(Ax)): two independent predecrement
    # addresses, neither exposed via the single-EA-field get_operand_ea()
    # above (they come from separate address registers with their own
    # auto-decrement, not a standard mode/reg EA), so the destination address
    # was never checked against the STOP+NOP runway at all. Found via a
    # full-corpus retest (Phase 102): 1/8065 ADDX.w tests happened to land
    # Ax's post-decrement address exactly inside the runway immediately after
    # a 2-byte instruction, corrupting the runway's NOP bytes with the ADDX
    # write and hanging/misbehaving downstream. Mirrors the ordinary EA
    # overlap check above, just computing both addresses by hand since
    # there's no single get_operand_ea() call that covers this shape.
    # f_ss==3 required: ADDX/SUBX's own size field is only ever byte/word/long
    # (0/1/2) — without this exclusion the mask alone coincidentally matches
    # some SUBA.l/ADDA.l register-direct opcodes too (e.g. `SUBA.l A2,A0` =
    # 0x91CA: group=9, bit8=1, and its An-direct source EA field happens to
    # supply bits[5:3]="001"/bit3=1, landing on the exact same bit pattern as
    # the ADDX/SUBX predecrement-memory-form marker purely by coincidence —
    # crashed with `KeyError: 3` in the `{0:1,1:2,2:4}` size lookup below when
    # first found via the Phase 102 full-corpus retest, since ADDA/SUBA's own
    # f_ss==3 has no entry there). Same recurring "fixed bits alias an
    # unrelated instruction family's EA field" shape as several earlier
    # phases, just introduced fresh in this phase's own new code.
    f_ss_addx = (opcode >> 6) & 3
    is_addx_mem = (opcode & 0xF138) == 0xD108 and f_ss_addx != 3
    is_subx_mem = (opcode & 0xF138) == 0x9108 and f_ss_addx != 3
    if is_addx_mem or is_subx_mem:
        ax_reg = (opcode >> 9) & 7
        ay_reg = opcode & 7
        siz_bytes = {0: 1, 1: 2, 2: 4}[f_ss_addx]

        def _get_an_val(reg):
            if reg == 7:
                return (ini['ssp'] if (ini['sr'] & 0x2000) else ini['usp']) & 0xFFFFFFFF
            return ini[f'a{reg}'] & 0xFFFFFFFF

        def _step(reg):
            return 2 if (reg == 7 and siz_bytes == 1) else siz_bytes

        ay_addr = (_get_an_val(ay_reg) - _step(ay_reg)) & 0xFFFFFFFF
        # Ax's predecrement compounds on Ay's already-decremented value when
        # the two registers are the same (same rule as Phase 91's ABCD/SBCD
        # same-register fix and Phase 82's MOVE fix).
        ax_base = ay_addr if ax_reg == ay_reg else _get_an_val(ax_reg)
        ax_addr = (ax_base - _step(ax_reg)) & 0xFFFFFF
        stop_start = (instr_src + instr_len) & 0xFFFFFF
        stop_end   = (stop_start + 4 + 8 * 2) & 0xFFFFFF
        if any(stop_start <= ((ax_addr + off) & 0xFFFFFF) < stop_end
               for off in range(siz_bytes)):
            return False, f'ADDX/SUBX dest {ax_addr:#08x} overlaps STOP runway'
        if any((ax_addr + off) & 0xFFFFFF < INIT_CODE_END for off in range(siz_bytes)):
            return False, f'ADDX/SUBX dest {ax_addr:#08x} in init region'

    # RTS/RTE/RTR: fixed-encoding return instructions with no EA operand at all
    # (get_operand_ea() returns None for all of them — see its own
    # opcode-exclusion guard). Each legitimately restores PC from a
    # test-supplied stack value that can be far from the instruction's own
    # address, so instr_len is *expected* to be wild here too, same reasoning
    # as JMP/JSR below — this must not be treated as a signal that the
    # reference took an unreplicable exception.
    #
    # TRAP/TRAPV are deliberately NOT included here, unlike RTS/RTE/RTR. They
    # look superficially identical (also fixed-encoding, also send PC far
    # away) but are architecturally different in a way that makes them
    # unfixable by this harness: TRAP/TRAPV/CHK/illegal/etc. all have the DUT
    # itself CONSTRUCT a brand-new exception stack frame, and our 68030 RTL
    # correctly always includes the format/vector word every 68010+ frame
    # requires (confirmed via m68030_exc.sv's FMT_SHORT=4 words / FMT_INST=6
    # words) — but the Harte corpus is captured on real 68000 silicon, which
    # has NO format word at all (TRAP's native 68000 frame is just {SR,PC},
    # 3 words). Tried exempting TRAP the same way as RTS/RTE/RTR: it let
    # every trap-taken test run, but ~94% then FAILED with the exact same
    # symptom (`A7: got 0x7f8, exp 0x7fa` — our correct 4-word push vs. the
    # reference's 3-word push), confirming this is the same permanent
    # 68000-vs-68030 divergence class as Phase 94/95/97's scale-field cases
    # (see feedback_harte_68000_vs_68030.md) — except here the DUT's *output*
    # diverges, not an input we control, so unlike RTE there is no way to
    # synthesize compatibility. Left skipped, as before.
    is_ret_taken = opcode in (0x4E73, 0x4E75, 0x4E77)

    # A restored PC that's odd causes a genuine Address Error on real 68030
    # silicon too (unlike misaligned *data* access, misaligned *instruction
    # fetch* is not a 68000-only quirk — see feedback_harte_68000_vs_68030.md's
    # caution note). Phase 100 root-caused and CONFIRMED our RTL's Address Error
    # mechanism (`m68030_ifu.sv`'s `addr_err` → `m68030_exc.sv`'s vector-3
    # redirect) is fully functional end-to-end: it was never exercised before
    # (the whole instruction family was 100% SKIP) because the vector-3 table
    # read (fixed address VBR+12, and VBR defaults to 0 at reset) collided with
    # our OWN synthesized init code, which always occupies low addresses
    # starting at RESET_PC=8 — the read returned corrupted garbage (part of an
    # unrelated MOVE.L immediate operand) instead of a real vector, and the DUT
    # ran off decoding that garbage as instructions, hanging forever. Fixed by
    # relocating VBR (via a synthesized `MOVEC A7,VBR`, found+fixed a matching
    # missing-`ext_count`-entry gap in `m68030_seq.sv` along the way — MOVEC had
    # literally never been exercised through the IFU drain path before either,
    # only unit-tested directly bypassing the prefetch queue) to a safe, empty
    # region and placing the vector-3 entry there, pointing at the same target
    # our own STOP+NOP runway already lands on. Confirmed via direct repro (RTS
    # index 423): the DUT now correctly detects the odd PC, pushes its
    # exception frame, reads the *correct* relocated vector-3 entry, redirects
    # PC exactly where expected, and cleanly reaches STOP — no more hang.
    #
    # However, this does NOT mean the byte-level comparison passes: Address
    # Error's exception frame has the exact same width-divergence problem as
    # TRAP (see feedback_harte_68000_vs_68030.md's fourth+fifth-instance note)
    # — our 68030 correctly pushes FMT_ADDR (8 words) while the 68000 reference
    # pushes its native 7-word address-error frame, and since the DUT
    # constructs this frame as its own *output*, there's no input-side fix
    # available (unlike RTE's format-word synthesis). Confirmed via the same
    # repro: `A7: got 0x7f0, exp 0x7f6` plus a cascade of stack-byte mismatches,
    # while SR/CCR (unaffected by the frame width) matched exactly. So: the
    # underlying mechanism is now proven correct, but these specific vectors
    # remain permanently unable to PASS the byte-for-byte Harte comparison —
    # skip them, same treatment as TRAP, now for a fully confirmed reason
    # instead of an unresolved unknown.
    if is_ret_taken:
        rm_ret = {a & 0xFFFFFF: v for a, v in ini['ram']}
        ssp = ini['ssp']
        # RTS: PC at [ssp, ssp+4). RTR: CCR word then PC at [ssp+2, ssp+6).
        # RTE: our synthesized frame's PC sits at the same [ssp+2, ssp+6)
        # offset as RTR (format word at ssp-2, SR at ssp, PC at ssp+2) since
        # a7_init_val = ssp-2 and the RTE frame is {fmt/vec, SR, PC}.
        pc_off = 0 if opcode == 0x4E75 else 2
        pc_addr = (ssp + pc_off) & 0xFFFFFF
        popped_pc = 0
        for i in range(4):
            popped_pc = (popped_pc << 8) | rm_ret.get((pc_addr + i) & 0xFFFFFF, 0)
        if popped_pc & 1:
            mnemonic = {0x4E75: 'RTS', 0x4E73: 'RTE', 0x4E77: 'RTR'}[opcode]
            return False, (f'{mnemonic} restores odd PC {popped_pc:#010x}: Address Error '
                            'frame width permanently incompatible with 68000 corpus '
                            '(mechanism confirmed working, see Phase 100)')

    # Backstop for complex EA modes that get_operand_ea() returns None for:
    # if instr_len is still wild, the reference took an exception (almost certainly
    # a misaligned EA that we couldn't compute statically). Only applies when
    # ea_info is None — when get_operand_ea() DID return a concrete EA (e.g. JMP/JSR,
    # whose "ea" is the jump target), its own misalignment was already checked above,
    # and instr_len = final_pc - ini_pc is *expected* to be "wild" for any
    # control-transfer instruction (PC legitimately jumps elsewhere) — that's not a
    # signal of an exception, so this backstop must not re-fire on it.
    if ea_info is None and not is_ret_taken and not (1 <= instr_len <= 24):
        return False, 'misaligned EA'

    # Second backstop, for the case ea_info IS resolvable (a normal data-referencing
    # instruction, not JMP/JSR): a wild instr_len here means the *reference* CPU
    # (real 68000 hardware) took an Address Error exception mid-instruction — most
    # commonly because indexed (d8,An,Xn) EAs on real 68000 silicon ignore the
    # 68020+ scale field entirely (scale is always 1), so an EA that our scale-aware
    # 68030 RTL computes as even/aligned lands on an *odd* address on the reference,
    # which faults there but not here. A 68030 legitimately does not fault on
    # misaligned *data* accesses (only misaligned PC/instruction fetch), so there is
    # no way to bit-replicate this specific reference behavior — but without this
    # skip, gen_harte_hex placed the STOP+NOP runway using the reference's huge
    # post-exception PC delta, so our non-faulting RTL runs straight past it into
    # never-initialized memory, decodes garbage, and can hang the simulation
    # (TIMEOUT) instead of cleanly failing. Root-caused via MULS.w indexed-EA
    # cases #75/#87/#170: reference final SR unchanged but PC jumps to the address
    # in the vector-3 (address error) table entry, with the classic 68000 7-word
    # address-error frame on the stack (opcode capture word + odd access address
    # split across two words + SR + PC). See plan.md for the full writeup.
    if ea_info is not None and not is_jmp_jsr and not (1 <= instr_len <= 24):
        return False, f'ea resolved but instr_len={instr_len} wild (reference took an exception we cannot replicate)'

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
