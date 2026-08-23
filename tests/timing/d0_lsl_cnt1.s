; tests/timing/d0_lsl_cnt1.s -- Phase 162 (clock-cycle-accuracy plan) Stage D0:
; confirm LSL.L Dx,Dy's own measured clock count is FLAT (does not scale
; with the register-supplied shift count) within the manual's own "count
; <= operand size" bucket. Paired with d0_lsl_cnt30.s (same bucket, count=30).
;
;   lsl.l   d1,d2     -- count=1
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #1,d1
        move.l  #1,d2
        bra.w   target

        org     $200
target:
        lsl.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
