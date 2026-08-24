; tests/timing/a5_btst_dn_dn.s -- Phase 161 Part A Stage A5: BIT_MANIP 'BTST Dn,Dn'
; MC68030UM.pdf 11-45/46/47: BTST Dn,Dn NCC=4(0/1/0)
; Cycle-accuracy-closing plan.md, item 3: watches CCR directly
; (watch_kind=2), same $10->$14 transition as BTST #(data),Dn.
;
;   btst    d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d1
        move.l  #$FFFFFFDF,d2
        move.w  #$10,ccr
        bra.w   target

        org     $200
target:
        btst    d1,d2
after:
        stop    #$2700
        dc.w    $2700
