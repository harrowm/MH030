; tests/timing/a6_nop.s -- Phase 161 Part A Stage A6: CONTROL_INSTR 'NOP'
; MC68030UM.pdf 11-48/49: NOP NCC=2(0/1/0)
;
;   nop
        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        nop
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
