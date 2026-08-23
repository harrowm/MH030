; tests/timing/a4_subx_dn.s -- Phase 161 Part A Stage A4: BCD_EXT 'SUBX Dn,Dn'
; MC68030UM.pdf 11-43/11-44: SUBX Dn,Dn NCC=2(0/1/0)
;
;   subx.l  d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #0,ccr
        move.l  #$10,d1
        move.l  #$30,d2
        bra.w   target

        org     $200
target:
        subx.l  d1,d2
after:
        stop    #$2700
        dc.w    $2700
