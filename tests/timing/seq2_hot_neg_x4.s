; tests/timing/seq2_hot_neg_x4.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). NEG.L (An) x4 at 4 distinct addresses, unrolled
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        movea.l #$3010,a1
        movea.l #$3020,a2
        movea.l #$3030,a3
        move.l  #5,($3000)
        move.l  #5,($3010)
        move.l  #5,($3020)
        move.l  #5,($3030)
        bra.w   target

        org     $200
target:
        neg.l   (a0)
        neg.l   (a1)
        neg.l   (a2)
        neg.l   (a3)
after:
        stop    #$2700
        dc.w    $2700
