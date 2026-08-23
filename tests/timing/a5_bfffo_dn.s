; tests/timing/a5_bfffo_dn.s -- Phase 161 Part A Stage A5: BIT_FIELD 'BFFFO Dn'
; MC68030UM.pdf 11-45/46/47: BFFFO Dn,Dx NCC=20(0/1/0)
;
;   bfffo   d2{0:8},d3
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$00800000,d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        bfffo   d2{0:8},d3
after:
        stop    #$2700
        dc.w    $2700
