; tests/timing/seq2_chain4.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). ADD / NEG.L(An) / MOVE / SUB, 4 mixed instructions
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #5,($3000)
        move.l  #$10,d1
        clr.l   d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        add.l   d1,d2
        neg.l   (a0)
        move.l  d2,d3
        sub.l   d1,d3
after:
        stop    #$2700
        dc.w    $2700
