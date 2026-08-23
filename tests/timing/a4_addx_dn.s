; tests/timing/a4_addx_dn.s -- Phase 161 Part A Stage A4: BCD_EXT 'ADDX Dn,Dn'
; MC68030UM.pdf 11-43/11-44: ADDX Dn,Dn NCC=2(0/1/0)
;
;   addx.l  d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #0,ccr
        move.l  #$10,d1
        move.l  #$20,d2
        bra.w   target

        org     $200
target:
        addx.l  d1,d2
after:
        stop    #$2700
        dc.w    $2700
