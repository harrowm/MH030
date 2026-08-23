; tests/timing/a2_move_dn_ccr.s -- Phase 161 Part A Stage A2: Special-Purpose
; MOVE table "MOVE Dn,CCR" row. MC68030UM.pdf 11-39: Head=4,Tail=0,
; NCC=4(0/1/0). CCR isn't directly watchable -- marker MOVE #imm,D2 follows.
;
;   MOVE D1,CCR

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$1F,d1
        move.w  #0,ccr
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.w  d1,ccr
        move.l  #$cafebabe,d2
        stop    #$2700
        dc.w    $2700
