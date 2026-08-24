; tests/timing/a2_move_usp_an.s -- Phase 161 Part A Stage A2: Special-Purpose
; MOVE table "MOVE USP,An" row. MC68030UM.pdf 11-39: Head=4,Tail=0,
; NCC=4(0/1/0). Cycle-accuracy-closing plan.md, item 3: watches A1
; directly (watch_kind=1), no marker needed.
;
;   MOVE USP,A1   (after USP set to $5678 in setup)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$5678,a2
        move.l  a2,usp
        bra.w   target

        org     $200
target:
        move.l  usp,a1
        stop    #$2700
        dc.w    $2700
