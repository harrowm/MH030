; tests/timing/a6_jsr.s -- Phase 161 Part A Stage A6: CONTROL_INSTR '%JSR'
; MC68030UM.pdf 11-48/49: JSR NCC=7(0/2/1) + jea((An))=2(0/0/0)
;
;   jsr     (a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #land_jsr,a0
        bra.w   target

        org     $200
target:
        jsr     (a0)
        move.l  #$deadbeef,d2
land_jsr:
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
