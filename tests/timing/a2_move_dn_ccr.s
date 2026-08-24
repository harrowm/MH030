; tests/timing/a2_move_dn_ccr.s -- Phase 161 Part A Stage A2: Special-Purpose
; MOVE table "MOVE Dn,CCR" row. MC68030UM.pdf 11-39: Head=4,Tail=0,
; NCC=4(0/1/0). Cycle-accuracy-closing plan.md, item 3: watches CCR
; directly (tb/timing_tb.sv's new watch_kind=2), no marker needed. CCR
; starts at 0 (distinct from the $1F result) so the watch mechanism's
; own prev!=new edge-detection sees a genuine transition.
;
;   MOVE D1,CCR

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$1F,d1
        move.w  #0,ccr
        bra.w   target

        org     $200
target:
        move.w  d1,ccr
        stop    #$2700
        dc.w    $2700
