; tests/timing/a7_trap_n.s -- Phase 161 Part A Stage A7: TRAP #n
; MC68030UM.pdf 11-50: TRAP #n NCC=20(1/2/4)
;
;   trap      #0
        org     0
        dc.l    $00010000
        dc.l    start

        org     $80
        dc.l    trap_handler

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        trap    #0
        ; unreached -- TRAP always dispatches

trap_handler:
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
