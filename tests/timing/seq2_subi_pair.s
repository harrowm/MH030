; tests/timing/seq2_subi_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). SUBI.L #20,Dn x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #100,d2
        bra.w   target

        org     $200
target:
        subi.l  #20,d2
        subi.l  #20,d2
after:
        stop    #$2700
        dc.w    $2700
