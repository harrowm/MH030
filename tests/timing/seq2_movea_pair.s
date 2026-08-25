; tests/timing/seq2_movea_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). MOVEA.L Dn,An x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d1
        bra.w   target

        org     $200
target:
        movea.l d1,a2
        movea.l d1,a2
after:
        stop    #$2700
        dc.w    $2700
