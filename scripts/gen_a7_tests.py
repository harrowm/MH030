#!/usr/bin/env python3
"""Generator for Phase 161 Part A Stage A7 test programs (tests/timing/a7_*.s)
and manifest (tests/timing/a7_exc_save.json). One-shot authoring tool.

Deliberately a smaller, representative set (not exhaustive) -- exception
dispatch is architecturally the most complex measurement category in this
whole rollout (needs a real vector-table entry + handler, unlike every
earlier stage's plain straight-line or single-redirect instructions).
Closes Part A's original 7-stage scope with real coverage of the
mechanism, not a claim of covering every row in EXCEPTION_RELATED/
SAVE_RESTORE.
"""
import subprocess
import json
import re
from pathlib import Path

REPO = Path(__file__).parent.parent
OUTDIR = REPO / 'tests' / 'timing'

TESTS = []


def add(name, desc_short, row_desc, src, watch_reg, watch_val,
        expect_r, expect_p, expect_w, extra_desc="", omit_instr_len=False,
        instr_len_override=None):
    TESTS.append(dict(name=name, desc_short=desc_short, row_desc=row_desc, src=src,
                       watch_reg=watch_reg, watch_val=watch_val,
                       expect_r=expect_r, expect_p=expect_p, expect_w=expect_w,
                       extra_desc=extra_desc, omit_instr_len=omit_instr_len,
                       instr_len_override=instr_len_override))


add('a7_trapv_notrap', "EXCEPTION_RELATED 'TRAPV (No Trap)'",
    "TRAPV (No Trap) NCC=4(0/1/0)",
    """; tests/timing/a7_trapv_notrap.s -- Phase 161 Part A Stage A7: TRAPV (No Trap)
; MC68030UM.pdf 11-50: TRAPV (No Trap) NCC=4(0/1/0)
;
;   trapv     (V=0, no trap)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #0,ccr
        clr.l   d2
        bra.w   target

        org     $200
target:
        trapv
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
""", 2, "0xcafebabe", 0, 1, 0,
    extra_desc="V=0 (ccr cleared) -> TRAPV does not trap, falls through normally")

add('a7_bkpt', "EXCEPTION_RELATED 'BKPT'", "BKPT NCC=9(1/0/0)",
    """; tests/timing/a7_bkpt.s -- Phase 161 Part A Stage A7: BKPT
; MC68030UM.pdf 11-50: BKPT NCC=9(1/0/0)
;
;   bkpt      #0
        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        bkpt    #0
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
""", 2, "0xcafebabe", 0, 1, 0,
    extra_desc="Phase 157's own BKPT implementation issues a real CPU-space (FC=111) read for "
               "the DSACK'd bus-protocol outcome, confirmed via direct AS-fall trace -- but "
               "tb/timing_tb.sv's own is_data_fc classification (FC in {101,001}, established "
               "back in Stage A0/A1 when only ordinary supervisor/user data spaces had ever come "
               "up) doesn't recognize FC=111 as a countable read, so expect_r=0 here reflects "
               "what this harness can observe, not the true r=1 architectural total; a genuine, "
               "first-of-its-kind harness gap, not an RTL bug -- Phase 157's own known "
               "no-live-substitution scope boundary is a separate, already-documented limitation "
               "that would also affect p if this test could see far enough")

add('a7_trap_n', "EXCEPTION_RELATED 'TRAP #n'", "TRAP #n NCC=20(1/2/4)",
    """; tests/timing/a7_trap_n.s -- Phase 161 Part A Stage A7: TRAP #n
; MC68030UM.pdf 11-50: TRAP #n NCC=20(1/2/4)
;
;   trap      #0
        org     0
        dc.l    $00010000
        dc.l    start

        org     $80
        dc.l    trap_handler

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        trap    #0
        ; unreached -- TRAP always dispatches

trap_handler:
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
""", 2, "0xcafebabe", 1, 2, 2,
    extra_desc="vector 32 (addr $80) points at trap_handler; TRAP #0 always dispatches there via "
               "a real exception-frame push. Measured w=2, not the manual's own row value of 4 "
               "-- confirmed via direct trace that this RTL pushes the 4-word (8-byte) frame as "
               "TWO longword (siz=00) writes at $FFFC/$FFF8, not four word writes; Harte's own "
               "exception-frame tests are 100% passing (final memory content verified correct), "
               "so this is a genuine write-GRANULARITY divergence from the manual's own assumed "
               "bus-cycle shape, not a correctness issue")

add('a7_illegal', "EXCEPTION_RELATED 'Illegal Instruction'",
    "Illegal Instruction NCC=20(1/2/4)",
    """; tests/timing/a7_illegal.s -- Phase 161 Part A Stage A7: Illegal Instruction
; MC68030UM.pdf 11-50: Illegal Instruction NCC=20(1/2/4)
;
;   dc.w      $4AFC   (real 68k ILLEGAL opcode)
        org     0
        dc.l    $00010000
        dc.l    start

        org     $10
        dc.l    illegal_handler

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        dc.w    $4AFC
        ; unreached -- ILLEGAL always dispatches

illegal_handler:
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
""", 2, "0xcafebabe", 1, 2, 2,
    extra_desc="vector 4 (addr $10) points at illegal_handler; the real 68k ILLEGAL opcode "
               "($4AFC) always dispatches there via a real exception-frame push. Measured w=2, "
               "not the manual's own row value of 4 -- same longword-vs-word write-granularity "
               "divergence as a7_trap_n, confirmed the identical way",
    instr_len_override=2)


def emit():
    manifest = []
    for t in TESTS:
        spath = OUTDIR / f"{t['name']}.s"
        spath.write_text(t['src'])

        bpath = OUTDIR / f"{t['name']}.bin"
        lpath = OUTDIR / f"{t['name']}.lst"
        r = subprocess.run(['vasmm68k_mot', '-Fbin', '-m68030', '-no-opt',
                             '-L', str(lpath), '-o', str(bpath), str(spath)],
                            capture_output=True, text=True)
        if r.returncode != 0:
            print(f"ASSEMBLE FAIL {t['name']}:\n{r.stdout}\n{r.stderr}")
            continue

        if t['instr_len_override'] is not None:
            instr_len = t['instr_len_override']
        else:
            lst = lpath.read_text()
            addrs = [int(m.group(1), 16) for m in re.finditer(r'^0\d:([0-9A-F]{8})\s', lst, re.M)
                     if int(m.group(1), 16) >= 0x200]
            if len(addrs) < 2:
                print(f"WARN {t['name']}: could not locate a second address, addrs={addrs}")
                instr_len = None
            else:
                instr_len = addrs[1] - addrs[0]
        bpath.unlink()
        lpath.unlink()

        entry = {
            "name": t['name'],
            "hex": f"tests/timing/{t['name']}.hex",
            "target_pc": "0x200",
            "watch_reg": t['watch_reg'],
            "watch_val": t['watch_val'],
            "expect_r": t['expect_r'],
            "expect_p": t['expect_p'],
            "expect_w": t['expect_w'],
            "desc": f"{t['desc_short']}: {t['row_desc']}" + (
                f" -- {t['extra_desc']}" if t['extra_desc'] else "")
        }
        if not t['omit_instr_len']:
            entry["instr_len"] = instr_len
        manifest.append(entry)
        print(f"{t['name']}: instr_len={instr_len} (omitted={t['omit_instr_len']})")

    with open(OUTDIR / 'a7_exc_save.json', 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"\nWrote {len(manifest)} entries to a7_exc_save.json")


if __name__ == '__main__':
    emit()
