; tests/timing/seq2_swap_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). SWAP Dn x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$12340000,d1
        bra.w   target

        org     $200
target:
        swap    d1
        swap    d1
after:
        stop    #$2700
        dc.w    $2700
