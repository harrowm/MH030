; tests/timing/a6_bcc_w_not_taken.s -- Phase 161 Part A Stage A6: COND_BRANCH 'Bcc.W (Not Taken)'
; MC68030UM.pdf 11-48/49: Bcc.W (Not Taken) NCC=6(0/1/0)
;
;   bne.w   skip
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #4,ccr
        bra.w   target

        org     $200
target:
        bne.w   skip
        move.l  #$cafebabe,d2
skip:
after:
        stop    #$2700
        dc.w    $2700
