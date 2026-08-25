; tests/timing/seq2_hot_add_x8.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). ADD Rn,Dn x8 unrolled
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #1,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        add.l   d1,d2
        add.l   d1,d2
        add.l   d1,d2
        add.l   d1,d2
        add.l   d1,d2
        add.l   d1,d2
        add.l   d1,d2
        add.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
