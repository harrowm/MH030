; tests/timing/a8_chk2_exc.s -- docs/*.md review (plan.md §Phase 247
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
