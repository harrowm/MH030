#!/usr/bin/env python3
"""Generator for Phase 161 Part A Stage A5 test programs (tests/timing/a5_*.s)
and manifest (tests/timing/a5_shift_bit.json). One-shot authoring tool,
mirrors scripts/gen_a4_tests.py.
"""
import subprocess
import json
import re
from pathlib import Path

REPO = Path(__file__).parent.parent
OUTDIR = REPO / 'tests' / 'timing'

TEMPLATE = """; tests/timing/{name}.s -- Phase 161 Part A Stage A5: {desc_short}
; MC68030UM.pdf 11-45/46/47: {row_desc}
;
{setup_comment}
        org     0
        dc.l    $00010000
        dc.l    start

start:
{setup}
        bra.w   target

        org     $200
target:
{instr}
after:
        stop    #$2700
        dc.w    $2700
"""

TESTS = []


def add(name, desc_short, row_desc, setup_lines, instr_lines, watch_reg, watch_val,
        expect_r, expect_p, expect_w, extra_desc=""):
    TESTS.append(dict(name=name, desc_short=desc_short, row_desc=row_desc,
                       setup_lines=setup_lines, instr_lines=instr_lines,
                       watch_reg=watch_reg, watch_val=watch_val,
                       expect_r=expect_r, expect_p=expect_p, expect_w=expect_w,
                       extra_desc=extra_desc))


# ── SHIFT_ROTATE (§11.6.12) ─────────────────────────────────────────────
add('a5_lsl_imm_dy', "SHIFT_ROTATE 'LSd #(data),Dy'", "LSL.L #1,Dy NCC=4(0/1/0)",
    ["move.l  #1,d2"], ["lsl.l   #1,d2"], 2, "0x2", 0, 1, 0)

add('a5_lsl_dx_dy_le', "SHIFT_ROTATE '%LSd Dx,Dy'", "LSL.L Dx,Dy (count<=32) NCC=6(0/1/0)",
    ["move.l  #3,d1", "move.l  #1,d2"], ["lsl.l   d1,d2"], 2, "0x8", 0, 1, 0)

add('a5_lsl_mem', "SHIFT_ROTATE '*LSd Mem by 1'", "LSL Mem by 1 NCC=4(0/1/1) + fea((An))=3(1/0/0)",
    ["movea.l #$3000,a0", "move.w  #1,($3000)", "clr.l   d2"],
    ["lsl.w   (a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 1, 1,
    extra_desc="marker is register-only, doesn't affect the tested instruction's own r/p/w")

add('a5_asl_dx_dy', "SHIFT_ROTATE 'ASL Dx,Dy'", "ASL.L Dx,Dy NCC=8(0/1/0)",
    ["move.l  #3,d1", "move.l  #1,d2"], ["asl.l   d1,d2"], 2, "0x8", 0, 1, 0)

add('a5_asr_dx_dy_gt', "SHIFT_ROTATE '+ASR Dx,Dy'", "ASR.L Dx,Dy (count>32) NCC=10(0/1/0)",
    ["move.l  #40,d1", "move.l  #$80000000,d2"], ["asr.l   d1,d2"], 2, "0xFFFFFFFF", 0, 1, 0,
    extra_desc="count=40 (>32=data size) exercises the '+' row; D2 starts negative but != the "
               "expected result so a real transition is observable (any count>=31 arithmetic-"
               "shifts a negative value to all-1s, sign-extended forever)")

add('a5_rol_imm_dy', "SHIFT_ROTATE 'ROd #(data),Dy'", "ROL.L #1,Dy NCC=6(0/1/0)",
    ["move.l  #1,d2"], ["rol.l   #1,d2"], 2, "0x2", 0, 1, 0)

add('a5_ror_dx_dy', "SHIFT_ROTATE 'ROd Dx,Dy'", "ROR.L Dx,Dy NCC=8(0/1/0)",
    ["move.l  #8,d1", "move.l  #$FF,d2"], ["ror.l   d1,d2"], 2, "0xFF000000", 0, 1, 0)

add('a5_roxl_dn', "SHIFT_ROTATE 'ROXd Dn'", "ROXL.L #1,Dn NCC=12(0/1/0)",
    ["move.w  #0,ccr", "move.l  #1,d2"], ["roxl.l  #1,d2"], 2, "0x2", 0, 1, 0)

# ── BIT_MANIP (§11.6.13) ─────────────────────────────────────────────────
add('a5_btst_imm_dn', "BIT_MANIP 'BTST #(data),Dn'", "BTST #(data),Dn NCC=4(0/1/0)",
    ["move.l  #$FFFFFFDF,d2", "clr.l   d3"],
    ["btst    #5,d2", "seq     d3"], 3, "0xFF", 0, 1, 0,
    extra_desc="D2's bit5=0 (rest set) -> BTST finds it clear -> Z=1 -> marker SEQ D3 writes $FF "
               "to D3's low byte (D3 pre-cleared to 0, a real detectable transition)")

add('a5_btst_dn_dn', "BIT_MANIP 'BTST Dn,Dn'", "BTST Dn,Dn NCC=4(0/1/0)",
    ["move.l  #5,d1", "move.l  #$FFFFFFDF,d2", "clr.l   d3"],
    ["btst    d1,d2", "seq     d3"], 3, "0xFF", 0, 1, 0,
    extra_desc="D2's bit5=0 (rest set) -> BTST finds it clear -> Z=1 -> marker SEQ D3 writes $FF")

add('a5_bchg_imm_dn', "BIT_MANIP 'BCHG #(data),Dn'", "BCHG #(data),Dn NCC=6(0/1/0)",
    ["clr.l   d2"], ["bchg    #0,d2"], 2, "0x1", 0, 1, 0)

add('a5_bchg_dn_dn', "BIT_MANIP 'BCHG Dn,Dn'", "BCHG Dn,Dn NCC=6(0/1/0)",
    ["move.l  #0,d1", "clr.l   d2"], ["bchg    d1,d2"], 2, "0x1", 0, 1, 0)

add('a5_bchg_dn_mem', "BIT_MANIP '*BCHG Dn,Mem'", "BCHG Dn,Mem NCC=6(0/1/1) + fea((An))=3(1/0/0)",
    ["movea.l #$3000,a0", "move.l  #0,($3000)", "move.l  #0,d1", "clr.l   d2"],
    ["bchg    d1,(a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 1, 1,
    extra_desc="marker is register-only")

add('a5_bclr_dn_dn', "BIT_MANIP 'BCLR Dn,Dn'", "BCLR Dn,Dn NCC=6(0/1/0)",
    ["move.l  #0,d1", "move.l  #$FFFFFFFF,d2"], ["bclr    d1,d2"], 2, "0xFFFFFFFE", 0, 1, 0)

add('a5_bset_dn_dn', "BIT_MANIP 'BSET Dn,Dn'", "BSET Dn,Dn NCC=6(0/1/0)",
    ["move.l  #0,d1", "clr.l   d2"], ["bset    d1,d2"], 2, "0x1", 0, 1, 0)

add('a5_bset_dn_mem', "BIT_MANIP '*BSET Dn,Mem'", "BSET Dn,Mem NCC=6(0/1/1) + fea((An))=3(1/0/0)",
    ["movea.l #$3000,a0", "move.l  #0,($3000)", "move.l  #0,d1", "clr.l   d2"],
    ["bset    d1,(a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 1, 1,
    extra_desc="marker is register-only")

# ── BIT_FIELD (§11.6.14), register-only forms ────────────────────────────
add('a5_bftst_dn', "BIT_FIELD 'BFTST Dn'", "BFTST Dn NCC=8(0/1/0)",
    ["move.l  #0,d2", "clr.l   d3"],
    ["bftst   d2{0:8}", "seq     d3"], 3, "0xFF", 0, 1, 0,
    extra_desc="D2{0:8}=0 -> Z=1 -> SEQ D3 writes $FF")

add('a5_bfchg_dn', "BIT_FIELD 'BFCHG Dn'", "BFCHG Dn NCC=14(0/1/0)",
    ["move.l  #0,d2"], ["bfchg   d2{0:8}"], 2, "0xFF000000", 0, 1, 0)

add('a5_bfclr_dn', "BIT_FIELD 'BFCLR Dn'", "BFCLR Dn NCC=14(0/1/0)",
    ["move.l  #$FFFFFFFF,d2"], ["bfclr   d2{0:8}"], 2, "0x00FFFFFF", 0, 1, 0)

add('a5_bfset_dn', "BIT_FIELD 'BFSET Dn'", "BFSET Dn NCC=14(0/1/0)",
    ["move.l  #0,d2"], ["bfset   d2{0:8}"], 2, "0xFF000000", 0, 1, 0)

add('a5_bfexts_dn', "BIT_FIELD 'BFEXTS Dn'", "BFEXTS Dn,Dx NCC=10(0/1/0)",
    ["move.l  #$FF000000,d2", "clr.l   d3"],
    ["bfexts  d2{0:8},d3"], 3, "0xFFFFFFFF", 0, 1, 0,
    extra_desc="D2{0:8}=0xFF (top bit set) sign-extends to -1")

add('a5_bfextu_dn', "BIT_FIELD 'BFEXTU Dn'", "BFEXTU Dn,Dx NCC=10(0/1/0)",
    ["move.l  #$FF000000,d2", "clr.l   d3"],
    ["bfextu  d2{0:8},d3"], 3, "0xFF", 0, 1, 0)

add('a5_bfins_dn', "BIT_FIELD 'BFINS Dn'", "BFINS Dx,Dn NCC=12(0/1/0)",
    ["move.l  #$AB,d3", "clr.l   d2"],
    ["bfins   d3,d2{0:8}"], 2, "0xAB000000", 0, 1, 0)

add('a5_bfffo_dn', "BIT_FIELD 'BFFFO Dn'", "BFFFO Dn,Dx NCC=20(0/1/0)",
    ["move.l  #$00800000,d2", "clr.l   d3"],
    ["bfffo   d2{0:8},d3"], 3, "0x8", 0, 1, 0,
    extra_desc="D2{0:8}'s first set bit is at offset 8 from the field's own start")


def emit():
    manifest = []
    for t in TESTS:
        setup = "\n".join("        " + l for l in t['setup_lines'])
        instr = "\n".join("        " + l for l in t['instr_lines'])
        setup_comment = f";   {t['instr_lines'][0]}"
        src = TEMPLATE.format(name=t['name'], desc_short=t['desc_short'],
                               row_desc=t['row_desc'], setup_comment=setup_comment,
                               setup=setup, instr=instr)
        spath = OUTDIR / f"{t['name']}.s"
        spath.write_text(src)

        bpath = OUTDIR / f"{t['name']}.bin"
        lpath = OUTDIR / f"{t['name']}.lst"
        r = subprocess.run(['vasmm68k_mot', '-Fbin', '-m68030', '-no-opt',
                             '-L', str(lpath), '-o', str(bpath), str(spath)],
                            capture_output=True, text=True)
        if r.returncode != 0:
            print(f"ASSEMBLE FAIL {t['name']}:\n{r.stdout}\n{r.stderr}")
            continue

        lst = lpath.read_text()
        addrs = [int(m.group(1), 16) for m in re.finditer(r'^01:([0-9A-F]{8})\s', lst, re.M)]
        if len(addrs) < 2:
            print(f"WARN {t['name']}: could not locate a second address, addrs={addrs}")
            instr_len = None
        else:
            instr_len = addrs[1] - addrs[0]
        bpath.unlink()
        lpath.unlink()

        manifest.append({
            "name": t['name'],
            "hex": f"tests/timing/{t['name']}.hex",
            "target_pc": "0x200",
            "instr_len": instr_len,
            "watch_reg": t['watch_reg'],
            "watch_val": t['watch_val'],
            "expect_r": t['expect_r'],
            "expect_p": t['expect_p'],
            "expect_w": t['expect_w'],
            "desc": f"{t['desc_short']}: {t['row_desc']}" + (
                f" -- {t['extra_desc']}" if t['extra_desc'] else "")
        })
        print(f"{t['name']}: instr_len={instr_len}")

    with open(OUTDIR / 'a5_shift_bit.json', 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"\nWrote {len(manifest)} entries to a5_shift_bit.json")


if __name__ == '__main__':
    emit()
