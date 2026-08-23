; tests/timing/a5_lsl_dx_dy_le.s -- Phase 161 Part A Stage A5: SHIFT_ROTATE '%LSd Dx,Dy'
; MC68030UM.pdf 11-45/46/47: LSL.L Dx,Dy (count<=32) NCC=6(0/1/0)
;
;   lsl.l   d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #3,d1
        move.l  #1,d2
        bra.w   target

        org     $200
target:
        lsl.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
