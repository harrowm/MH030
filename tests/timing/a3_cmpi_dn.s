; tests/timing/a3_cmpi_dn.s -- Phase 161 Part A Stage A3: ALU_IMM '**CMPI #(data),Dn'
; MC68030UM.pdf 11-40/41/42: CMPI #(data),Dn NCC=2(0/1/0) + FIEA(#imm.L,Dn)=2(0/1/0)
;
;   cmpi.l  #5,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        cmpi.l  #5,d2
        move.l  #$cafebabe,d3
after:
        stop    #$2700
        dc.w    $2700
