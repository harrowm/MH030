; tests/timing/a6_pea.s -- Phase 161 Part A Stage A6: CONTROL_INSTR '**PEA'
; MC68030UM.pdf 11-48/49: PEA NCC=4(0/1/1) + cea((An))=2(0/0/0)
;
;   pea     (a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        clr.l   d2
        bra.w   target

        org     $200
target:
        pea     (a0)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
