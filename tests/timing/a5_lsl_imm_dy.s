; tests/timing/a5_lsl_imm_dy.s -- Phase 161 Part A Stage A5: SHIFT_ROTATE 'LSd #(data),Dy'
; MC68030UM.pdf 11-45/46/47: LSL.L #1,Dy NCC=4(0/1/0)
;
;   lsl.l   #1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #1,d2
        bra.w   target

        org     $200
target:
        lsl.l   #1,d2
after:
        stop    #$2700
        dc.w    $2700
