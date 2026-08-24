; tests/timing/a4_tst_dn.s -- Phase 161 Part A Stage A4: SINGLE_OP 'TST Dn'
; MC68030UM.pdf 11-43/11-44: TST Dn NCC=2(0/1/0)
; Cycle-accuracy-closing plan.md, item 3: watches CCR directly
; (watch_kind=2), no marker needed. CCR baseline $14 (X=1,N=0,Z=1,V=0,
; C=0) before target; TST.L of D2=5 (positive, nonzero) gives N=0,
; Z=0,V=0,C=0,X unaffected(=1) -> CCR=$10, a genuine Z:1->0 transition.
;
;   tst.l   d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d2
        move.w  #$14,ccr
        bra.w   target

        org     $200
target:
        tst.l   d2
after:
        stop    #$2700
        dc.w    $2700
