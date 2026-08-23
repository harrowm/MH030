; tests/timing/a4_pack_dn.s -- Phase 161 Part A Stage A4: BCD_EXT 'PACK Dn,Dn,#(data)'
; MC68030UM.pdf 11-43/11-44: PACK Dn,Dn,#(data) NCC=6(0/1/0)
;
;   pack    d1,d2,#0
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$0102,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        pack    d1,d2,#0
after:
        stop    #$2700
        dc.w    $2700
