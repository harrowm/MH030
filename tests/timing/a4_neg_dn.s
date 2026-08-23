; tests/timing/a4_neg_dn.s -- Phase 161 Part A Stage A4: SINGLE_OP 'NEG Dn'
; MC68030UM.pdf 11-43/11-44: NEG Dn NCC=2(0/1/0)
;
;   neg.l   d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d2
        bra.w   target

        org     $200
target:
        neg.l   d2
after:
        stop    #$2700
        dc.w    $2700
