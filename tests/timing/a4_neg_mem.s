; tests/timing/a4_neg_mem.s -- Phase 161 Part A Stage A4: SINGLE_OP '*NEG Mem'
; MC68030UM.pdf 11-43/11-44: NEG Mem NCC=4(0/1/1) + fea((An))=3(1/0/0)
;
;   neg.l   (a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #5,($3000)
        clr.l   d2
        bra.w   target

        org     $200
target:
        neg.l   (a0)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
