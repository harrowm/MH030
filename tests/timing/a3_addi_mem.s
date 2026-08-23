; tests/timing/a3_addi_mem.s -- Phase 161 Part A Stage A3: ALU_IMM '**ADDI #(data),Mem'
; MC68030UM.pdf 11-40/41/42: ADDI #(data),Mem NCC=4(0/1/1) + FIEA(#imm.L,(An))=5(1/1/0)
;
;   addi.l  #20,(a0)
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
        addi.l  #20,(a0)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
