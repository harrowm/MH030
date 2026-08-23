; tests/timing/a3_ori_dn.s -- Phase 161 Part A Stage A3: ALU_IMM '**ORI #(data),Dn'
; MC68030UM.pdf 11-40/41/42: ORI #(data),Dn NCC=2(0/1/0) + FIEA(#imm.L,Dn)=2(0/1/0)
;
;   ori.l   #$0F,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$F0,d2
        bra.w   target

        org     $200
target:
        ori.l   #$0F,d2
after:
        stop    #$2700
        dc.w    $2700
