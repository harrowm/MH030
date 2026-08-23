; tests/timing/a4_unpk_dn.s -- Phase 161 Part A Stage A4: BCD_EXT 'UNPK Dn,Dn,#(data)'
; MC68030UM.pdf 11-43/11-44: UNPK Dn,Dn,#(data) NCC=8(0/1/0)
;
;   unpk    d2,d3,#0
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$12,d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        unpk    d2,d3,#0
after:
        stop    #$2700
        dc.w    $2700
