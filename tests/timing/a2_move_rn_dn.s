; tests/timing/a2_move_rn_dn.s -- Phase 161 Part A Stage A2: MOVE table
; "Rn,Dn" row. MC68030UM.pdf 11-37: Head=2,Tail=0, NCC=2(0/1/0).
;
;   MOVE.L D1,D2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.l  d1,d2
        stop    #$2700
        dc.w    $2700
