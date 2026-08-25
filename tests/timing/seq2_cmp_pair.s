; tests/timing/seq2_cmp_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). CMP Rn,Dn x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d1
        move.l  #$10,d2
        bra.w   target

        org     $200
target:
        cmp.l   d1,d2
        cmp.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
