; tests/timing/seq2_asl_imm_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). ASL #1,Dn x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #1,d2
        bra.w   target

        org     $200
target:
        asl.l   #1,d2
        asl.l   #1,d2
after:
        stop    #$2700
        dc.w    $2700
