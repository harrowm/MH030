; tests/timing/a5_bfins_dn.s -- Phase 161 Part A Stage A5: BIT_FIELD 'BFINS Dn'
; MC68030UM.pdf 11-45/46/47: BFINS Dx,Dn NCC=12(0/1/0)
;
;   bfins   d3,d2{0:8}
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$AB,d3
        clr.l   d2
        bra.w   target

        org     $200
target:
        bfins   d3,d2{0:8}
after:
        stop    #$2700
        dc.w    $2700
