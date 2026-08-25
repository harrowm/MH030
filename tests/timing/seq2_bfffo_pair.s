; tests/timing/seq2_bfffo_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). BFFFO Dn,Dm x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$00800000,d2
        bra.w   target

        org     $200
target:
        bfffo   d2{0:8},d3
        bfffo   d2{0:8},d3
after:
        stop    #$2700
        dc.w    $2700
