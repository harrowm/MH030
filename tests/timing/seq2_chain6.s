; tests/timing/seq2_chain6.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). 6 mixed instructions: ALU/RMW/shift/MOVE
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #5,($3000)
        move.l  #$10,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        add.l   d1,d2
        and.l   d1,d2
        neg.l   (a0)
        asl.l   #1,d2
        move.l  d2,d3
        clr.l   (a0)
after:
        stop    #$2700
        dc.w    $2700
