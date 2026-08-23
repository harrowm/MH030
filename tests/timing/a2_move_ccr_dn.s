; tests/timing/a2_move_ccr_dn.s -- Phase 161 Part A Stage A2: Special-Purpose
; MOVE table "MOVE CCR,Dn" row. MC68030UM.pdf 11-39: Head=2,Tail=0,
; NCC=4(0/1/0). CCR is word-size; D1 pre-cleared so only the low word
; changes.
;
;   MOVE CCR,D1   (after CCR set to all flags: $1F)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d1
        move.w  #$001F,ccr
        bra.w   target

        org     $200
target:
        move.w  ccr,d1
        stop    #$2700
        dc.w    $2700
