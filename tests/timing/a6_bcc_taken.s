; tests/timing/a6_bcc_taken.s -- Phase 161 Part A Stage A6: COND_BRANCH 'Bcc (Taken)'
; MC68030UM.pdf 11-48/49: Bcc (Taken) NCC=8(0/2/0)
;
;   beq.w   skip
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #4,ccr
        bra.w   target

        org     $200
target:
        beq.w   skip
        move.l  #$deadbeef,d2
skip:
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
