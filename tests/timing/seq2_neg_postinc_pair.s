; tests/timing/seq2_neg_postinc_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). NEG.L (An)+ x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #5,($3000)
        move.l  #5,($3004)
        bra.w   target

        org     $200
target:
        neg.l   (a0)+
        neg.l   (a0)+
after:
        stop    #$2700
        dc.w    $2700
