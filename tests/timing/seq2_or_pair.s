; tests/timing/seq2_or_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). OR Dn,Dn x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$0F0F0F0F,d1
        move.l  #$F0000000,d2
        bra.w   target

        org     $200
target:
        or.l    d1,d2
        or.l    d1,d2
after:
        stop    #$2700
        dc.w    $2700
