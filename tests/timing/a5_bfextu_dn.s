; tests/timing/a5_bfextu_dn.s -- Phase 161 Part A Stage A5: BIT_FIELD 'BFEXTU Dn'
; MC68030UM.pdf 11-45/46/47: BFEXTU Dn,Dx NCC=10(0/1/0)
;
;   bfextu  d2{0:8},d3
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$FF000000,d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        bfextu  d2{0:8},d3
after:
        stop    #$2700
        dc.w    $2700
