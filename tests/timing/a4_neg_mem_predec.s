; tests/timing/a4_neg_mem_predec.s -- Cycle-accuracy-closing plan.md,
; item 5: NEG Mem combined with the -(An) addressing mode (untested
; combination -- the existing a4_neg_mem only ever used plain (An)).
; MC68030UM.pdf 11-43/11-44: NEG Mem NCC=4(0/1/1) + fea(-(An))=4(1/0/0).
;
;   neg.l   -(a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3004,a0
        move.l  #5,($3000)
        clr.l   d2
        bra.w   target

        org     $200
target:
        neg.l   -(a0)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
