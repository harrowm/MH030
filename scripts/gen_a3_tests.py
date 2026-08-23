#!/usr/bin/env python3
"""Generator for Phase 161 Part A Stage A3 test programs (tests/timing/a3_*.s)
and manifest (tests/timing/a3_alu.json). Not part of the regular Makefile
flow -- a one-shot authoring tool, kept for reference/regeneration.

Each entry: name, setup lines, target instruction line(s) (list, first is
the one under test), watch_reg, watch_val, expect_r/p/w, desc.
instr_len is auto-computed via a vasm listing (address of the label right
after the tested instruction), matching the technique established in
Stage A2.
"""
import subprocess
import json
import re
from pathlib import Path

REPO = Path(__file__).parent.parent
OUTDIR = REPO / 'tests' / 'timing'

TEMPLATE = """; tests/timing/{name}.s -- Phase 161 Part A Stage A3: {desc_short}
; MC68030UM.pdf 11-40/41/42: {row_desc}
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


# ── Register-direct rows (self-contained NCC as printed) ───────────────────
add('a3_add_rn_dn', "ALU 'ADD Rn,Dn'", "ADD Rn,Dn NCC=2(0/1/0)",
    ["move.l  #$10,d1", "clr.l   d2"], ["add.l   d1,d2"], 2, "0x10", 0, 1, 0)

add('a3_adda_w', "ALU 'ADDA.W Rn,An'", "ADDA.W Rn,An NCC=4(0/1/0)",
    ["move.w  #$10,d1", "movea.l #0,a2", "clr.l   d2"],
    ["adda.w  d1,a2", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 0, 1, 0)

add('a3_adda_l', "ALU 'ADDA.L Rn,An'", "ADDA.L Rn,An NCC=2(0/1/0)",
    ["move.l  #$10,d1", "movea.l #0,a2", "clr.l   d2"],
    ["adda.l  d1,a2", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 0, 1, 0)

add('a3_and_dn_dn', "ALU 'AND Dn,Dn'", "AND Dn,Dn NCC=2(0/1/0)",
    ["move.l  #$0F0F0F0F,d1", "move.l  #$FFFFFFFF,d2"],
    ["and.l   d1,d2"], 2, "0x0F0F0F0F", 0, 1, 0)

add('a3_eor_dn_dn', "ALU 'EOR Dn,Dn'", "EOR Dn,Dn NCC=2(0/1/0)",
    ["move.l  #$FFFFFFFF,d1", "move.l  #$0F0F0F0F,d2"],
    ["eor.l   d1,d2"], 2, "0xF0F0F0F0", 0, 1, 0)

add('a3_or_dn_dn', "ALU 'OR Dn,Dn'", "OR Dn,Dn NCC=2(0/1/0)",
    ["move.l  #$0F0F0F0F,d1", "move.l  #$F0000000,d2"],
    ["or.l    d1,d2"], 2, "0xFF0F0F0F", 0, 1, 0)

add('a3_sub_rn_dn', "ALU 'SUB Rn,Dn'", "SUB Rn,Dn NCC=2(0/1/0)",
    ["move.l  #5,d1", "move.l  #$10,d2"],
    ["sub.l   d1,d2"], 2, "0xB", 0, 1, 0)

add('a3_suba_w', "ALU 'SUBA.W Rn,An'", "SUBA.W Rn,An NCC=4(0/1/0)",
    ["move.w  #5,d1", "movea.l #$10,a2", "clr.l   d2"],
    ["suba.w  d1,a2", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 0, 1, 0)

add('a3_suba_l', "ALU 'SUBA.L Rn,An'", "SUBA.L Rn,An NCC=2(0/1/0)",
    ["move.l  #5,d1", "movea.l #$10,a2", "clr.l   d2"],
    ["suba.l  d1,a2", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 0, 1, 0)

add('a3_cmp_rn_dn', "ALU 'CMP Rn,Dn'", "CMP Rn,Dn NCC=2(0/1/0)",
    ["move.l  #5,d1", "move.l  #5,d2", "clr.l   d3"],
    ["cmp.l   d1,d2", "move.l  #$cafebabe,d3"], 3, "0xcafebabe", 0, 1, 0)

add('a3_cmpa_w', "ALU 'CMPA.W Rn,An'", "CMPA.W Rn,An NCC=4(0/1/0)",
    ["move.w  #5,d1", "movea.l #5,a2", "clr.l   d3"],
    ["cmpa.w  d1,a2", "move.l  #$cafebabe,d3"], 3, "0xcafebabe", 0, 1, 0)

add('a3_moveq', "ALU_IMM 'MOVEQ #(data),Dn'", "MOVEQ #(data),Dn NCC=2(0/1/0)",
    ["move.l  #$FFFFFFFF,d2"], ["moveq   #5,d2"], 2, "0x5", 0, 1, 0)

add('a3_addq_rn', "ALU_IMM 'ADDQ #(data),Rn'", "ADDQ #(data),Rn NCC=2(0/1/0)",
    ["move.l  #$10,d2"], ["addq.l  #1,d2"], 2, "0x11", 0, 1, 0)

add('a3_subq_rn', "ALU_IMM 'SUBQ #(data),Rn'", "SUBQ #(data),Rn NCC=2(0/1/0)",
    ["move.l  #$10,d2"], ["subq.l  #1,d2"], 2, "0xF", 0, 1, 0)

add('a3_addi_dn', "ALU_IMM '**ADDI #(data),Dn'", "ADDI #(data),Dn NCC=2(0/1/0) + FIEA(#imm.L,Dn)=2(0/1/0)",
    ["move.l  #$10,d2"], ["addi.l  #20,d2"], 2, "0x24", 0, 2, 0,
    extra_desc="imm=20 (not 5) deliberately outside ADDQ's 1-8 quick-immediate range -- "
               "vasm's default optimizer (the Makefile's shared tests/%.bin rule doesn't "
               "pass -no-opt) silently folds ADDI #imm,Dn into ADDQ when imm is quick-eligible, "
               "changing the actually-assembled instruction underneath this test. '**' means "
               "Add Fetch Immediate EA Time (FIEA), not self-contained -- total is FIEA(0,1,0) "
               "+ row(0,1,0) = (0,2,0), confirmed by RTL after fixing the folding issue above")

add('a3_andi_dn', "ALU_IMM 'ANDI #(data),Dn'", "ANDI #(data),Dn NCC=2(0/1/0) + FIEA(#imm.L,Dn)=2(0/1/0)",
    ["move.l  #$FF,d2"], ["andi.l  #$0F,d2"], 2, "0xF", 0, 2, 0,
    extra_desc="ANDI's own row has no '**' printed in the manual table's OCR, but AND/immediate-to-Dn "
               "still needs a real 4-byte immediate fetch -- same FIEA(0,1,0)+row(0,1,0)=(0,2,0) as "
               "the other five group-0 immediate-to-Dn ops, confirmed empirically")

add('a3_eori_dn', "ALU_IMM '**EORI #(data),Dn'", "EORI #(data),Dn NCC=2(0/1/0) + FIEA(#imm.L,Dn)=2(0/1/0)",
    ["move.l  #$0F,d2"], ["eori.l  #$FF,d2"], 2, "0xF0", 0, 2, 0)

add('a3_ori_dn', "ALU_IMM '**ORI #(data),Dn'", "ORI #(data),Dn NCC=2(0/1/0) + FIEA(#imm.L,Dn)=2(0/1/0)",
    ["move.l  #$F0,d2"], ["ori.l   #$0F,d2"], 2, "0xFF", 0, 2, 0)

add('a3_subi_dn', "ALU_IMM '**SUBI #(data),Dn'", "SUBI #(data),Dn NCC=2(0/1/0) + FIEA(#imm.L,Dn)=2(0/1/0)",
    ["move.l  #$10,d2"], ["subi.l  #20,d2"], 2, "0xFFFFFFFC", 0, 2, 0,
    extra_desc="imm=20 (not 5), same ADDQ/SUBQ quick-immediate-folding avoidance as a3_addi_dn; "
               "same FIEA(0,1,0)+row(0,1,0)=(0,2,0) composition as a3_addi_dn")

add('a3_cmpi_dn', "ALU_IMM '**CMPI #(data),Dn'", "CMPI #(data),Dn NCC=2(0/1/0) + FIEA(#imm.L,Dn)=2(0/1/0)",
    ["move.l  #5,d2", "clr.l   d3"], ["cmpi.l  #5,d2", "move.l  #$cafebabe,d3"],
    3, "0xcafebabe", 0, 2, 0)

# ── Memory-EA rows (need the footnoted fea/fiea addition; verified empirically) ──
add('a3_add_dn_ea', "ALU '*ADD Dn,EA'", "ADD Dn,EA NCC=4(0/1/1) + fea((An))=3(1/0/0)",
    ["movea.l #$3000,a0", "move.l  #0,($3000)", "move.l  #$10,d1", "clr.l   d2"],
    ["add.l   d1,(a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 1, 1,
    extra_desc="marker is register-only (not a (a0) readback) -- r/w counting is chronological-"
               "window not address-range-gated (Stage A1's own documented design), so a marker "
               "that itself reads the just-written memory would inflate r_count")

add('a3_and_dn_ea', "ALU '*AND Dn,EA'", "AND Dn,EA NCC=4(0/1/1) + fea((An))=3(1/0/0)",
    ["movea.l #$3000,a0", "move.l  #$FFFFFFFF,($3000)", "move.l  #$0F0F0F0F,d1", "clr.l   d2"],
    ["and.l   d1,(a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 1, 1,
    extra_desc="marker is register-only, same rationale as a3_add_dn_ea")

add('a3_addq_mem', "ALU_IMM '*ADDQ #(data),Mem'", "ADDQ #(data),Mem NCC=4(0/1/1) + fea((An))=3(1/0/0)",
    ["movea.l #$3000,a0", "move.l  #$10,($3000)", "clr.l   d2"],
    ["addq.l  #1,(a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 1, 1,
    extra_desc="marker is register-only, same rationale as a3_add_dn_ea")

add('a3_addi_mem', "ALU_IMM '**ADDI #(data),Mem'", "ADDI #(data),Mem NCC=4(0/1/1) + FIEA(#imm.L,(An))=5(1/1/0)",
    ["movea.l #$3000,a0", "move.l  #$10,($3000)", "clr.l   d2"],
    ["addi.l  #20,(a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 2, 1,
    extra_desc="imm=20 (not 5), same ADDQ quick-immediate-folding avoidance as a3_addi_dn; '**' "
               "means FIEA not fea (unlike ADDQ's single '*') -- total is FIEA(1,1,0)+row(0,1,1) "
               "= (1,2,1), NOT fea((An))+row as originally (incorrectly) modeled; marker is "
               "register-only, same rationale as a3_add_dn_ea")


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

        # Assemble + get listing to find instr_len (target..after)
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
        # instr_len must cover ONLY the tested instruction (instr_lines[0]),
        # never any marker instructions that follow it -- so always the
        # SECOND emitted address in section 01 minus the first, regardless
        # of how many marker lines come after.
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

    with open(OUTDIR / 'a3_alu.json', 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"\nWrote {len(manifest)} entries to a3_alu.json")


if __name__ == '__main__':
    emit()
