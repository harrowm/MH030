; tests/timing/a7_illegal.s -- Phase 161 Part A Stage A7: Illegal Instruction
; MC68030UM.pdf 11-50: Illegal Instruction NCC=20(1/2/4)
;
;   dc.w      $4AFC   (real 68k ILLEGAL opcode)
        org     0
        dc.l    $00010000
        dc.l    start

        org     $10
        dc.l    illegal_handler

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        dc.w    $4AFC
        ; unreached -- ILLEGAL always dispatches

illegal_handler:
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
