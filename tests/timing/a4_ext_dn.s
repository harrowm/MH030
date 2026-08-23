; tests/timing/a4_ext_dn.s -- Phase 161 Part A Stage A4: SINGLE_OP 'EXT Dn'
; MC68030UM.pdf 11-43/11-44: EXT Dn NCC=4(0/1/0)
;
;   ext.l   d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$FFFF1234,d2
        bra.w   target

        org     $200
target:
        ext.l   d2
after:
        stop    #$2700
        dc.w    $2700
