; tests/timing/a4_nbcd_dn.s -- Phase 161 Part A Stage A4: SINGLE_OP 'NBCD Dn'
; MC68030UM.pdf 11-43/11-44: NBCD Dn NCC=6(0/1/0)
;
;   nbcd    d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #0,ccr
        move.l  #$12,d2
        bra.w   target

        org     $200
target:
        nbcd    d2
after:
        stop    #$2700
        dc.w    $2700
