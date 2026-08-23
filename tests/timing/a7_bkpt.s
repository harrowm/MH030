; tests/timing/a7_bkpt.s -- Phase 161 Part A Stage A7: BKPT
; MC68030UM.pdf 11-50: BKPT NCC=9(1/0/0)
;
;   bkpt      #0
        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        bkpt    #0
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
