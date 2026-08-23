; tests/timing/a5_bchg_dn_dn.s -- Phase 161 Part A Stage A5: BIT_MANIP 'BCHG Dn,Dn'
; MC68030UM.pdf 11-45/46/47: BCHG Dn,Dn NCC=6(0/1/0)
;
;   bchg    d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #0,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        bchg    d1,d2
after:
        stop    #$2700
        dc.w    $2700
