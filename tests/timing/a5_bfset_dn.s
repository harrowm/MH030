; tests/timing/a5_bfset_dn.s -- Phase 161 Part A Stage A5: BIT_FIELD 'BFSET Dn'
; MC68030UM.pdf 11-45/46/47: BFSET Dn NCC=14(0/1/0)
;
;   bfset   d2{0:8}
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #0,d2
        bra.w   target

        org     $200
target:
        bfset   d2{0:8}
after:
        stop    #$2700
        dc.w    $2700
