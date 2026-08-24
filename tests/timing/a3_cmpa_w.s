; tests/timing/a3_cmpa_w.s -- Phase 161 Part A Stage A3: ALU 'CMPA.W Rn,An'
; MC68030UM.pdf 11-40/41/42: CMPA.W Rn,An NCC=4(0/1/0)
; Cycle-accuracy-closing plan.md, item 3: watches CCR directly
; (watch_kind=2), same $1F->$14 transition as CMP Rn,Dn.
;
;   cmpa.w  d1,a2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #5,d1
        movea.l #5,a2
        move.w  #$1F,ccr
        bra.w   target

        org     $200
target:
        cmpa.w  d1,a2
after:
        stop    #$2700
        dc.w    $2700
