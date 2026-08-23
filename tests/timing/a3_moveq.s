; tests/timing/a3_moveq.s -- Phase 161 Part A Stage A3: ALU_IMM 'MOVEQ #(data),Dn'
; MC68030UM.pdf 11-40/41/42: MOVEQ #(data),Dn NCC=2(0/1/0)
;
;   moveq   #5,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$FFFFFFFF,d2
        bra.w   target

        org     $200
target:
        moveq   #5,d2
after:
        stop    #$2700
        dc.w    $2700
