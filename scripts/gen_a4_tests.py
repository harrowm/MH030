#!/usr/bin/env python3
"""Generator for Phase 161 Part A Stage A4 test programs (tests/timing/a4_*.s)
and manifest (tests/timing/a4_bcd_single.json). One-shot authoring tool,
mirrors scripts/gen_a3_tests.py.

Lessons carried forward from Stage A3: (1) don't rely on quick-immediate
values that vasm's default optimizer (the Makefile's shared tests/%.bin
rule has no -no-opt) could fold into a shorter opcode -- N/A here, none of
these instructions have a quick-immediate alternate encoding; (2) memory-
destination tests use a register-only marker (never a (An) readback), since
r/w counting is chronological-window not address-range-gated.
"""
import subprocess
import json
import re
from pathlib import Path

REPO = Path(__file__).parent.parent
OUTDIR = REPO / 'tests' / 'timing'

TEMPLATE = """; tests/timing/{name}.s -- Phase 161 Part A Stage A4: {desc_short}
; MC68030UM.pdf 11-43/11-44: {row_desc}
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


# ── BCD_EXT (§11.6.10), all self-contained rows, no footnote ───────────────
add('a4_abcd_dn', "BCD_EXT 'ABCD Dn,Dn'", "ABCD Dn,Dn NCC=4(0/1/0)",
    ["move.w  #0,ccr", "move.l  #$12,d1", "move.l  #$34,d2"],
    ["abcd    d1,d2"], 2, "0x46", 0, 1, 0)

add('a4_sbcd_dn', "BCD_EXT 'SBCD Dn,Dn'", "SBCD Dn,Dn NCC=4(0/1/0)",
    ["move.w  #0,ccr", "move.l  #$12,d1", "move.l  #$34,d2"],
    ["sbcd    d1,d2"], 2, "0x22", 0, 1, 0)

add('a4_addx_dn', "BCD_EXT 'ADDX Dn,Dn'", "ADDX Dn,Dn NCC=2(0/1/0)",
    ["move.w  #0,ccr", "move.l  #$10,d1", "move.l  #$20,d2"],
    ["addx.l  d1,d2"], 2, "0x30", 0, 1, 0)

add('a4_subx_dn', "BCD_EXT 'SUBX Dn,Dn'", "SUBX Dn,Dn NCC=2(0/1/0)",
    ["move.w  #0,ccr", "move.l  #$10,d1", "move.l  #$30,d2"],
    ["subx.l  d1,d2"], 2, "0x20", 0, 1, 0)

add('a4_cmpm', "BCD_EXT 'CMPM (An)+,(An)+'", "CMPM (An)+,(An)+ NCC=8(2/1/0)",
    ["movea.l #$3000,a0", "move.l  #1,($3000)", "movea.l #$3010,a1",
     "move.l  #1,($3010)", "clr.l   d2"],
    ["cmpm.l  (a0)+,(a1)+", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 2, 1, 0,
    extra_desc="marker is register-only, doesn't affect the tested instruction's own r/p/w")

add('a4_pack_dn', "BCD_EXT 'PACK Dn,Dn,#(data)'", "PACK Dn,Dn,#(data) NCC=6(0/1/0)",
    ["move.l  #$0102,d1", "clr.l   d2"],
    ["pack    d1,d2,#0"], 2, "0x12", 0, 1, 0)

add('a4_unpk_dn', "BCD_EXT 'UNPK Dn,Dn,#(data)'", "UNPK Dn,Dn,#(data) NCC=8(0/1/0)",
    ["move.l  #$12,d2", "clr.l   d3"],
    ["unpk    d2,d3,#0"], 3, "0x102", 0, 1, 0)

# ── SINGLE_OP (§11.6.11) ─────────────────────────────────────────────────
add('a4_clr_dn', "SINGLE_OP 'CLR Dn'", "CLR Dn NCC=2(0/1/0)",
    ["move.l  #$FFFFFFFF,d2"], ["clr.l   d2"], 2, "0x0", 0, 1, 0)

add('a4_clr_mem', "SINGLE_OP '**CLR Mem'", "CLR Mem NCC=4(0/1/1) + cea((An))=2(0/0/0)",
    ["movea.l #$3000,a0", "move.l  #$FFFFFFFF,($3000)", "clr.l   d2"],
    ["clr.l   (a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 0, 1, 1,
    extra_desc="'**' means Add Calculate EA Time (cea), not fiea, per this table's own footnote "
               "wording (confirmed by direct re-read) -- cea((An))=(0,0,0) so total is unchanged "
               "from the row itself; also directly re-validates Phase 139's CLR-to-memory fix "
               "(pure write, w=1, no phantom read)")

add('a4_neg_dn', "SINGLE_OP 'NEG Dn'", "NEG Dn NCC=2(0/1/0)",
    ["move.l  #5,d2"], ["neg.l   d2"], 2, "0xFFFFFFFB", 0, 1, 0)

add('a4_neg_mem', "SINGLE_OP '*NEG Mem'", "NEG Mem NCC=4(0/1/1) + fea((An))=3(1/0/0)",
    ["movea.l #$3000,a0", "move.l  #5,($3000)", "clr.l   d2"],
    ["neg.l   (a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 1, 1)

add('a4_negx_dn', "SINGLE_OP 'NEGX Dn'", "NEGX Dn NCC=2(0/1/0)",
    ["move.w  #0,ccr", "move.l  #5,d2"], ["negx.l  d2"], 2, "0xFFFFFFFB", 0, 1, 0)

add('a4_not_dn', "SINGLE_OP 'NOT Dn'", "NOT Dn NCC=2(0/1/0)",
    ["move.l  #$0F0F0F0F,d2"], ["not.l   d2"], 2, "0xF0F0F0F0", 0, 1, 0)

add('a4_ext_dn', "SINGLE_OP 'EXT Dn'", "EXT Dn NCC=4(0/1/0)",
    ["move.l  #$FFFF1234,d2"], ["ext.l   d2"], 2, "0x1234", 0, 1, 0)

add('a4_nbcd_dn', "SINGLE_OP 'NBCD Dn'", "NBCD Dn NCC=6(0/1/0)",
    ["move.w  #0,ccr", "move.l  #$12,d2"], ["nbcd    d2"], 2, "0x88", 0, 1, 0)

add('a4_scc_dn', "SINGLE_OP 'Scc Dn'", "Scc Dn NCC=4(0/1/0)",
    ["move.w  #4,ccr", "clr.l   d2"], ["seq     d2"], 2, "0xFF", 0, 1, 0,
    extra_desc="Z flag (ccr bit 2 = $4) pre-set true so SEQ writes $FF to D2's low byte")

add('a4_tas_dn', "SINGLE_OP 'TAS Dn'", "TAS Dn NCC=4(0/1/0)",
    ["clr.l   d2"], ["tas     d2"], 2, "0x80", 0, 1, 0)

add('a4_tas_mem', "SINGLE_OP '**TAS Mem'", "TAS Mem NCC=12(1/1/1) + cea((An))=2(0/0/0)",
    ["movea.l #$3000,a0", "move.l  #0,($3000)", "clr.l   d2"],
    ["tas     (a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 1, 0,
    extra_desc="architectural total per the manual is r=1,p=1,w=1 ('**'=cea((An))=(0,0,0), "
               "unchanged from the row) -- but expect_w is 1 not what this harness can measure: "
               "confirmed via direct AS-fall/AS-rise trace that TAS's own locked RMW write phase "
               "never produces a fresh as_fall event (AS stays asserted across the whole "
               "read-modify-write cycle, per this project's own documented RMW bus protocol in "
               "CLAUDE.md), so tb/timing_tb.sv's address-phase-edge-based w_count structurally "
               "cannot observe it -- the same class of limitation already documented (a different "
               "testbench) in Phase 116's own 'TAS hits a genuinely bus-locked-RMW logging gap' "
               "finding. Not an RTL bug; not fixed here, matching that precedent.")

add('a4_tst_dn', "SINGLE_OP 'TST Dn'", "TST Dn NCC=2(0/1/0)",
    ["move.l  #5,d2", "clr.l   d3"],
    ["tst.l   d2", "move.l  #$cafebabe,d3"], 3, "0xcafebabe", 0, 1, 0)

add('a4_tst_mem', "SINGLE_OP '*TST Mem'", "TST Mem NCC=2(0/1/0) + fea((An))=3(1/0/0)",
    ["movea.l #$3000,a0", "move.l  #5,($3000)", "clr.l   d2"],
    ["tst.l   (a0)", "move.l  #$cafebabe,d2"], 2, "0xcafebabe", 1, 1, 0)


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

    with open(OUTDIR / 'a4_bcd_single.json', 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"\nWrote {len(manifest)} entries to a4_bcd_single.json")


if __name__ == '__main__':
    emit()
