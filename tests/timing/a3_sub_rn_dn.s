; tests/timing/a3_sub_rn_dn.s -- Phase 161 Part A Stage A3: ALU 'SUB Rn,Dn'
; MC68030UM.pdf 11-40/41/42: SUB Rn,Dn NCC=2(0/1/0)
;
;   sub.l   d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d1
        move.l  #$10,d2
        bra.w   target

        org     $200
target:
        sub.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
