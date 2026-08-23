; tests/timing/a2_move_usp_an.s -- Phase 161 Part A Stage A2: Special-Purpose
; MOVE table "MOVE USP,An" row. MC68030UM.pdf 11-39: Head=4,Tail=0,
; NCC=4(0/1/0). An isn't directly watchable -- marker MOVE #imm,D2 follows.
;
;   MOVE USP,A1   (after USP set to $5678 in setup)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$5678,a2
        move.l  a2,usp
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.l  usp,a1
        move.l  #$cafebabe,d2
        stop    #$2700
        dc.w    $2700
