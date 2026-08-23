; tests/timing/a3_and_dn_ea.s -- Phase 161 Part A Stage A3: ALU '*AND Dn,EA'
; MC68030UM.pdf 11-40/41/42: AND Dn,EA NCC=4(0/1/1) + fea((An))=3(1/0/0)
;
;   and.l   d1,(a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #$FFFFFFFF,($3000)
        move.l  #$0F0F0F0F,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        and.l   d1,(a0)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
