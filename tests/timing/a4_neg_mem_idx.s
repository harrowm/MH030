; tests/timing/a4_neg_mem_idx.s -- Cycle-accuracy-closing plan.md,
; item 5: NEG Mem combined with the (d8,An,Xn) brief-format indexed
; addressing mode (untested combination -- the existing a4_neg_mem
; only ever used plain (An)). Same EA-computation shape as the
; already-proven a1_fea_briefidx test (A0=$2000, D1.L=4, d8=4 -> EA=
; $2008).
; MC68030UM.pdf 11-43/11-44/11-27: NEG Mem NCC=4(0/1/1) +
; fea(d8,An,Xn)=6(1/1/0).
;
;   neg.l   (4,a0,d1.l)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #4,d1
        move.l  #5,($2008)
        clr.l   d2
        bra.w   target

        org     $200
target:
        neg.l   (4,a0,d1.l)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
