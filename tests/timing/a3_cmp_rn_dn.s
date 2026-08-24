; tests/timing/a3_cmp_rn_dn.s -- Phase 161 Part A Stage A3: ALU 'CMP Rn,Dn'
; MC68030UM.pdf 11-40/41/42: CMP Rn,Dn NCC=2(0/1/0)
; Cycle-accuracy-closing plan.md, item 3: watches CCR directly
; (watch_kind=2), no marker needed. CCR baseline set to $1F (all 5
; flags set) before target so CMP's own result (Z=1, N/V/C=0, X
; unaffected=1 -> $14) is a genuine, detectable transition.
;
;   cmp.l   d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d1
        move.l  #5,d2
        move.w  #$1F,ccr
        bra.w   target

        org     $200
target:
        cmp.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
