; tests/timing/a2_move_sr_dn.s -- Phase 161 Part A Stage A2: Special-Purpose
; MOVE table "MOVE SR,Dn" row. MC68030UM.pdf 11-39: Head=2,Tail=0,
; NCC=4(0/1/0). SR is word-size; D1 pre-cleared.
;
;   MOVE SR,D1   (after SR set to $2000 in setup)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d1
        move.w  #$2000,sr
        bra.w   target

        org     $200
target:
        move.w  sr,d1
        stop    #$2700
        dc.w    $2700
