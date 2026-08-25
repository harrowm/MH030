; tests/timing/seq2_jsr_rts_pair.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). JSR (An) / RTS / ADD Rn,Dn
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #sub,a0
        move.l  #$10,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        jsr     (a0)
        add.l   d1,d2
after:
        stop    #$2700
        dc.w    $2700

        org     $300
sub:
        rts