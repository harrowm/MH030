; tests/timing/seq2_bfchg_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). BFCHG Dn{0:8} x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #0,d2
        bra.w   target

        org     $200
target:
        bfchg   d2{0:8}
        bfchg   d2{0:8}
after:
        stop    #$2700
        dc.w    $2700
