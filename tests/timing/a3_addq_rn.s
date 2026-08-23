; tests/timing/a3_addq_rn.s -- Phase 161 Part A Stage A3: ALU_IMM 'ADDQ #(data),Rn'
; MC68030UM.pdf 11-40/41/42: ADDQ #(data),Rn NCC=2(0/1/0)
;
;   addq.l  #1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$10,d2
        bra.w   target

        org     $200
target:
        addq.l  #1,d2
after:
        stop    #$2700
        dc.w    $2700
