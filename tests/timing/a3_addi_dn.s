; tests/timing/a3_addi_dn.s -- Phase 161 Part A Stage A3: ALU_IMM '**ADDI #(data),Dn'
; MC68030UM.pdf 11-40/41/42: ADDI #(data),Dn NCC=2(0/1/0) + FIEA(#imm.L,Dn)=2(0/1/0)
;
;   addi.l  #20,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$10,d2
        bra.w   target

        org     $200
target:
        addi.l  #20,d2
after:
        stop    #$2700
        dc.w    $2700
