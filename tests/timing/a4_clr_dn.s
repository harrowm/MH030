; tests/timing/a4_clr_dn.s -- Phase 161 Part A Stage A4: SINGLE_OP 'CLR Dn'
; MC68030UM.pdf 11-43/11-44: CLR Dn NCC=2(0/1/0)
;
;   clr.l   d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$FFFFFFFF,d2
        bra.w   target

        org     $200
target:
        clr.l   d2
after:
        stop    #$2700
        dc.w    $2700
