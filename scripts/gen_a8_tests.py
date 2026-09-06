#!/usr/bin/env python3
"""Generator for docs/*.md review (plan.md §Phase 247 item #9) test programs
(tests/timing/a8_*.s) and manifest (tests/timing/a8_cas_chk2.json).
One-shot authoring tool, mirrors scripts/gen_a7_tests.py.

CONTROL_INSTR's own CAS/CAS2/CHK2 rows (§11.6.16, MC68030UM.pdf 11-49) were
explicitly deferred by the original Chapter 11 timing-verification rollout's
own Stage A6 ("more complex setup, deferred" -- plan.md.old, Phase 161 Part A
Stage A6) since they need real memory operands (CAS/CAS2) or a real exception
dispatch (CHK2 Exception Taken), unlike that stage's own "confident subset."
These instructions' functional CORRECTNESS is already extensively verified
elsewhere (Harte-independent cosim, tb/stall_fsm_tb.sv's own AS-LOCK/CAS2
tests, tests/memind36.s/37.s for CHK2) -- this is purely closing a
test-coverage gap in the separate §11.6 timing-benchmark suite, not a
correctness fix.
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


add('a8_cas_success', "CONTROL_INSTR '##CAS (Successful Compare)'",
    "CAS (Successful Compare) NCC=13(1/1/1)",
    """; tests/timing/a8_cas_success.s -- docs/*.md review (plan.md §Phase 247
; item #9): CAS (Successful Compare)
; MC68030UM.pdf 11-49: ##CAS (Successful Compare) NCC=13(1/1/1)
;
;   cas.l   d1,d2,(a0)   (D1==mem -> compare succeeds, D2 writes to mem)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1000,a0
        move.l  #$11111111,($1000)
        move.l  #$11111111,d1        ; Dc -- matches memory
        move.l  #$22222222,d2        ; Du -- new value to write on success
        clr.l   d5
        bra.w   target

        org     $200
target:
        cas.l   d1,d2,(a0)
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700
""", 5, "0xcafebabe", 1, 1, 0,
    extra_desc="D1 (Dc) matches mem[$1000] exactly -> compare succeeds, D2 (Du) writes to "
               "memory (confirmed via direct trace: mem[$1000] genuinely becomes 0x22222222, "
               "the write really happens) -- but expect_w is 0, not the architectural 1, "
               "because CAS is RMW-locked (Phase 242's own cas_as_hold): AS stays "
               "continuously asserted across the whole read+write sequence, so this harness's "
               "own address-phase-edge-based w_count structurally cannot observe the write's "
               "own (non-existent) fresh AS-fall event -- the exact same, already-documented "
               "limitation tests/timing/a4_tas_mem.s hit for TAS's own locked write (see "
               "known_issues.json's own a4_tas_mem entry). Not an RTL bug")

add('a8_cas_fail', "CONTROL_INSTR '##CAS (Unsuccessful Compare)'",
    "CAS (Unsuccessful Compare) NCC=11(1/1/0)",
    """; tests/timing/a8_cas_fail.s -- docs/*.md review (plan.md §Phase 247
; item #9): CAS (Unsuccessful Compare)
; MC68030UM.pdf 11-49: ##CAS (Unsuccessful Compare) NCC=11(1/1/0)
;
;   cas.l   d1,d2,(a0)   (D1!=mem -> compare fails, D1 reloaded, no write)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1100,a0
        move.l  #$11111111,($1100)
        move.l  #$99999999,d1        ; Dc -- deliberately mismatched
        move.l  #$22222222,d2        ; Du -- must NOT reach memory
        clr.l   d5
        bra.w   target

        org     $200
target:
        cas.l   d1,d2,(a0)
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700
""", 5, "0xcafebabe", 1, 1, 0,
    extra_desc="D1 (Dc) deliberately does not match mem[$1100] -> compare fails, D1 reloaded "
               "from memory instead, NO write -- matches this project's own already-confirmed "
               "CAS semantics (CAS does not always write back on mismatch, see plan.md's "
               "deferred-items closure plan)")

add('a8_cas2_success', "CONTROL_INSTR '+CAS2 (Successful Compare)'",
    "CAS2 (Successful Compare) NCC=26(2/2/2)",
    """; tests/timing/a8_cas2_success.s -- docs/*.md review (plan.md §Phase 247
; item #9): CAS2 (Successful Compare)
; MC68030UM.pdf 11-49: +CAS2 (Successful Compare) NCC=26(2/2/2)
;
;   cas2.l  d1:d3,d2:d4,(a0):(a1)   (both compares succeed -> both writes)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1200,a0
        movea.l #$1300,a1
        move.l  #$AAAA1111,($1200)
        move.l  #$BBBB2222,($1300)
        move.l  #$AAAA1111,d1        ; Dc1 -- matches mem[A0]
        move.l  #$CCCC3333,d2        ; Du1 -- new value for mem[A0]
        move.l  #$BBBB2222,d3        ; Dc2 -- matches mem[A1]
        move.l  #$DDDD4444,d4        ; Du2 -- new value for mem[A1]
        clr.l   d5
        bra.w   target

        org     $200
target:
        cas2.l  d1:d3,d2:d4,(a0):(a1)
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700
""", 5, "0xcafebabe", 2, 2, 2,
    extra_desc="both Dc1/Dc2 match their own operand -> both compares succeed, both Du1/Du2 "
               "write to memory; r=2/w=2 are the two compare reads and two successful writes")

add('a8_cas2_fail', "CONTROL_INSTR '+CAS2 (Unsuccessful Compare)'",
    "CAS2 (Unsuccessful Compare) NCC=24(2/2/0)",
    """; tests/timing/a8_cas2_fail.s -- docs/*.md review (plan.md §Phase 247
; item #9): CAS2 (Unsuccessful Compare)
; MC68030UM.pdf 11-49: +CAS2 (Unsuccessful Compare) NCC=24(2/2/0)
;
;   cas2.l  d1:d3,d2:d4,(a0):(a1)  (first compare fails -> neither writes)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1400,a0
        movea.l #$1500,a1
        move.l  #$AAAA1111,($1400)
        move.l  #$BBBB2222,($1500)
        move.l  #$99999999,d1        ; Dc1 -- deliberately mismatched
        move.l  #$CCCC3333,d2        ; Du1 -- must NOT reach memory
        move.l  #$BBBB2222,d3        ; Dc2 -- matches mem[A1] (only Dc1 fails)
        move.l  #$DDDD4444,d4        ; Du2 -- must NOT reach memory either
        clr.l   d5
        bra.w   target

        org     $200
target:
        cas2.l  d1:d3,d2:d4,(a0):(a1)
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700
""", 5, "0xcafebabe", 2, 2, 0,
    extra_desc="Dc1 deliberately mismatches mem[A0]; Dc2 alone still matches mem[A1] -- CAS2 "
               "must read BOTH operands before it can know whether to write (r=2, same as the "
               "successful case), but a failure on EITHER side suppresses BOTH writes (w=0), "
               "not just the mismatched one -- the atomic, all-or-nothing semantics CAS2 is "
               "built for")

add('a8_chk2_noexc', "CONTROL_INSTR '#+CHK2 Mem,Rn (No Exception)'",
    "CHK2 Mem,Rn (No Exception) NCC=18(1/1/0)",
    """; tests/timing/a8_chk2_noexc.s -- docs/*.md review (plan.md §Phase 247
; item #9): CHK2 Mem,Rn (No Exception)
; MC68030UM.pdf 11-49: #+CHK2 Mem,Rn (No Exception) NCC=18(1/1/0)
;
;   chk2.w  (a0),d1   (bounds [10,20], D1=15 -- in range, no exception)
;
; .w size deliberately chosen (not .l, used elsewhere in this project's own
; memind36.s/37.s cosim tests): a .w pair of bounds (lower word + upper word)
; packs into exactly ONE longword read, matching this row's own NCC r=1
; directly -- .l bounds need two separate longword reads instead (8 bytes),
; which is a different row shape this table doesn't have a dedicated entry
; for.
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1600,a0
        move.l  #$000A0014,($1600)   ; lower=10 ($000A), upper=20 ($0014)
        move.l  #15,d1                ; in [10,20] -- no exception
        clr.l   d5
        bra.w   target

        org     $200
target:
        chk2.w  (a0),d1
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700
""", 5, "0xcafebabe", 2, 1, 0,
    extra_desc="D1=15 falls within the packed [10,20] word-bound pair at mem[$1600] -> no "
               "exception, falls through normally. Measured r=2, not the manual's own row "
               "value of 1: this RTL's CHK2/CMP2 implementation shares one dedicated two-read "
               "FSM (cmp2_run_r) that always issues two SEPARATE bus reads (lower bound, then "
               "upper bound) regardless of operand size, rather than exploiting a word-size "
               "optimization that packs both bounds into a single longword read -- the "
               "manual's own r=1 row value assumes that packing. Confirmed via direct trace, "
               "not guessed at; this project's own CHK2 cosim tests (tests/memind36.s/37.s) "
               "already confirm the comparison ITSELF is correct, only the manual's own "
               "resource-count row doesn't match this RTL's chosen (simpler, size-independent) "
               "implementation shape")

add('a8_chk2_exc', "CONTROL_INSTR '#+CHK2 Mem,Rn (Exception Taken)'",
    "CHK2 Mem,Rn (Exception Taken) NCC=42(2/3/4)",
    """; tests/timing/a8_chk2_exc.s -- docs/*.md review (plan.md §Phase 247
; item #9): CHK2 Mem,Rn (Exception Taken)
; MC68030UM.pdf 11-49: #+CHK2 Mem,Rn (Exception Taken) NCC=42(2/3/4)
;
;   chk2.w  (a0),d1   (bounds [10,20], D1=100 -- out of range, traps)
;
; CHK2's own out-of-bounds trap shares CHK's own vector 6 (VEC_CHK,
; rtl/m68030_exc.sv) and FMT_INST frame format ($2, 6 words -- CLAUDE.md's
; own exception stack frame table), same as a7_trap_n/a7_illegal's own
; already-documented write-granularity divergence from the manual's own
; word-count assumption.
        org     0
        dc.l    $00010000
        dc.l    start

        org     $18
        dc.l    chk2_handler

start:
        movea.l #$1700,a0
        move.l  #$000A0014,($1700)   ; lower=10 ($000A), upper=20 ($0014)
        move.l  #100,d1               ; outside [10,20] -- traps
        clr.l   d5
        bra.w   target

        org     $200
target:
        chk2.w  (a0),d1
        ; unreached -- CHK2 out-of-bounds always dispatches

chk2_handler:
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700
""", 5, "0xcafebabe", 3, 1, 3,
    extra_desc="D1=100 falls outside the packed [10,20] bound pair at mem[$1700] -> traps via "
               "vector 6 (addr $18) to chk2_handler, same vector/frame CHK's own Exception-Taken "
               "row uses. Three measured divergences from the manual's own row, each confirmed "
               "via direct trace, none a correctness issue (this project's own CHK2 cosim "
               "tests, tests/memind36.s/37.s, already confirm correct final memory content): "
               "(1) r=3, not 2 -- same two-separate-bound-reads shape a8_chk2_noexc already "
               "documents, PLUS the real vector-table read (vector 6, 1 longword) exception "
               "dispatch always needs; (2) p=1, not 3 -- this harness's own address-range 'p' "
               "gating only counts fetches within the tested instruction's own byte span, and "
               "chk2_handler's own opcode fetch (a genuinely different address) falls outside "
               "it, same convention every other exception-dispatch test in this project's own "
               "corpus (a7_trap_n/a7_illegal) already uses; (3) w=3, not 4 -- this RTL pushes "
               "the 6-word (FMT_INST) frame as THREE longword (siz=00) writes, not four word "
               "writes, the identical write-GRANULARITY divergence a7_trap_n/a7_illegal already "
               "documented for the 4-word (FMT_SHORT) frame case")


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

    with open(OUTDIR / 'a8_cas_chk2.json', 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"\nWrote {len(manifest)} entries to a8_cas_chk2.json")


if __name__ == '__main__':
    emit()
