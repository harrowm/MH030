; tests/timing/d0_lsl_cnt30.s -- Phase 162 (clock-cycle-accuracy plan) Stage D0:
; same as d0_lsl_cnt1.s but count=30 (still "<=32" bucket) -- if this RTL's
; own measured clock count matches d0_lsl_cnt1.s exactly, the gap is flat
; per instruction class, not scaling with the runtime count.
;
;   lsl.l   d1,d2     -- count=30
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #30,d1
        move.l  #1,d2
        bra.w   target

        org     $200
target:
        lsl.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
