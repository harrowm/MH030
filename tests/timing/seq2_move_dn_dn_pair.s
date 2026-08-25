; tests/timing/seq2_move_dn_dn_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). MOVE.L Dn,Dn x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d1
        bra.w   target

        org     $200
target:
        move.l  d1,d2
        move.l  d1,d2
after:
        stop    #$2700
        dc.w    $2700
