; tests/timing/a6_jmp.s -- Phase 161 Part A Stage A6: CONTROL_INSTR '%JMP'
; MC68030UM.pdf 11-48/49: JMP NCC=6(0/2/0) + jea((An))=2(0/0/0)
;
;   jmp     (a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #land_jmp,a0
        bra.w   target

        org     $200
target:
        jmp     (a0)
        move.l  #$deadbeef,d2
land_jmp:
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
