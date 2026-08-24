; tests/timing/a3_addq_postinc.s -- Cycle-accuracy-closing plan.md,
; item 5: ADDQ #(data),Mem combined with the (An)+ addressing mode
; (untested combination -- the existing a3_addq_mem only ever used
; plain (An)).
; MC68030UM.pdf 11-40/41/42/11-26: ADDQ #(data),Mem NCC=4(0/1/1) +
; fea((An)+)=3(1/0/0).
;
;   addq.l  #1,(a0)+
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #$10,($3000)
        clr.l   d2
        bra.w   target

        org     $200
target:
        addq.l  #1,(a0)+
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
