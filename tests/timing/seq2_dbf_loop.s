; tests/timing/seq2_dbf_loop.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). ADDQ.L #1,Dn / DBF loop, 4 passes
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #3,d0
        clr.l   d2
        bra.w   target

        org     $200
target:
loop:
        addq.l  #1,d2
        dbf     d0,loop
after:
        stop    #$2700
        dc.w    $2700
