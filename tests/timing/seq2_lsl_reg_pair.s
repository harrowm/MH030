; tests/timing/seq2_lsl_reg_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). LSL Dx,Dy x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #3,d1
        move.l  #1,d2
        bra.w   target

        org     $200
target:
        lsl.l   d1,d2
        lsl.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700
