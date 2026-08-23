; tests/timing/a3_and_dn_dn.s -- Phase 161 Part A Stage A3: ALU 'AND Dn,Dn'
; MC68030UM.pdf 11-40/41/42: AND Dn,Dn NCC=2(0/1/0)
;
;   and.l   d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$0F0F0F0F,d1
        move.l  #$FFFFFFFF,d2
        bra.w   target

        org     $200
target:
        and.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
