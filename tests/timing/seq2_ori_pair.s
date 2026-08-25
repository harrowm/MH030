; tests/timing/seq2_ori_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). ORI.L #imm,Dn x2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$F0F0F0F0,d2
        bra.w   target

        org     $200
target:
        ori.l   #$0F0F0F0F,d2
        ori.l   #$0F0F0F0F,d2
after:
        stop    #$2700
        dc.w    $2700
