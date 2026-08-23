; tests/timing/a4_abcd_dn.s -- Phase 161 Part A Stage A4: BCD_EXT 'ABCD Dn,Dn'
; MC68030UM.pdf 11-43/11-44: ABCD Dn,Dn NCC=4(0/1/0)
;
;   abcd    d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #0,ccr
        move.l  #$12,d1
        move.l  #$34,d2
        bra.w   target

        org     $200
target:
        abcd    d1,d2
after:
        stop    #$2700
        dc.w    $2700
