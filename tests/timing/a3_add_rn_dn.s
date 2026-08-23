; tests/timing/a3_add_rn_dn.s -- Phase 161 Part A Stage A3: ALU 'ADD Rn,Dn'
; MC68030UM.pdf 11-40/41/42: ADD Rn,Dn NCC=2(0/1/0)
;
;   add.l   d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$10,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        add.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
