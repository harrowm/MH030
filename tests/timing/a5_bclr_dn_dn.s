; tests/timing/a5_bclr_dn_dn.s -- Phase 161 Part A Stage A5: BIT_MANIP 'BCLR Dn,Dn'
; MC68030UM.pdf 11-45/46/47: BCLR Dn,Dn NCC=6(0/1/0)
;
;   bclr    d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #0,d1
        move.l  #$FFFFFFFF,d2
        bra.w   target

        org     $200
target:
        bclr    d1,d2
after:
        stop    #$2700
        dc.w    $2700
