; tests/timing/a5_lsl_mem.s -- Phase 161 Part A Stage A5: SHIFT_ROTATE '*LSd Mem by 1'
; MC68030UM.pdf 11-45/46/47: LSL Mem by 1 NCC=4(0/1/1) + fea((An))=3(1/0/0)
;
;   lsl.w   (a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.w  #1,($3000)
        clr.l   d2
        bra.w   target

        org     $200
target:
        lsl.w   (a0)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
