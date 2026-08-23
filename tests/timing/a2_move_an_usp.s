; tests/timing/a2_move_an_usp.s -- Phase 161 Part A Stage A2: Special-Purpose
; MOVE table "MOVE An,USP" row. MC68030UM.pdf 11-39: Head=4,Tail=0,
; NCC=4(0/1/0). USP isn't directly watchable -- read it back into a Dn
; register via a 2-instruction marker after the tested instruction.
;
;   MOVE A1,USP

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$9abc,a1
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.l  a1,usp
        move.l  usp,a3
        move.l  a3,d2
        stop    #$2700
        dc.w    $2700
