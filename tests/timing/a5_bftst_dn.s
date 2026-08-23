; tests/timing/a5_bftst_dn.s -- Phase 161 Part A Stage A5: BIT_FIELD 'BFTST Dn'
; MC68030UM.pdf 11-45/46/47: BFTST Dn NCC=8(0/1/0)
;
;   bftst   d2{0:8}
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #0,d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        bftst   d2{0:8}
        seq     d3
after:
        stop    #$2700
        dc.w    $2700
