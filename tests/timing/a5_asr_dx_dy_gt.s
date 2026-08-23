; tests/timing/a5_asr_dx_dy_gt.s -- Phase 161 Part A Stage A5: SHIFT_ROTATE '+ASR Dx,Dy'
; MC68030UM.pdf 11-45/46/47: ASR.L Dx,Dy (count>32) NCC=10(0/1/0)
;
;   asr.l   d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #40,d1
        move.l  #$80000000,d2
        bra.w   target

        org     $200
target:
        asr.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
