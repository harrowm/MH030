; tests/timing/a5_bfchg_dn.s -- Phase 161 Part A Stage A5: BIT_FIELD 'BFCHG Dn'
; MC68030UM.pdf 11-45/46/47: BFCHG Dn NCC=14(0/1/0)
;
;   bfchg   d2{0:8}
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #0,d2
        bra.w   target

        org     $200
target:
        bfchg   d2{0:8}
after:
        stop    #$2700
        dc.w    $2700
