; tests/timing/seq2_neg_idx_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). NEG.L (d8,An,Xn) x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #0,d1
        move.l  #5,($3000)
        move.l  #5,($3004)
        bra.w   target

        org     $200
target:
        neg.l   (0,a0,d1.l)
        neg.l   (4,a0,d1.l)
after:
        stop    #$2700
        dc.w    $2700
