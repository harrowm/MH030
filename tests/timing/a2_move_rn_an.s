; tests/timing/a2_move_rn_an.s -- Phase 161 Part A Stage A2: MOVE table
; "Rn,An" row (MOVEA). MC68030UM.pdf 11-37: Head=2,Tail=0, NCC=2(0/1/0).
; Cycle-accuracy-closing plan.md, item 3: watches A2 directly
; (tb/timing_tb.sv's new watch_kind=1) instead of needing a trailing
; marker instruction -- a genuinely isolated, marker-free measurement.
;
;   MOVE.L D1,A2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d1
        bra.w   target

        org     $200
target:
        movea.l d1,a2
        stop    #$2700
        dc.w    $2700
