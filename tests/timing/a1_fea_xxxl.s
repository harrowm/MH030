; tests/timing/a1_fea_xxxl.s — Phase 161 Part A Stage A1: fea "(xxx).L" row.
; MC68030UM.pdf 11-26: (xxx).L Head=1,Tail=0, NCC=5(1/1/0) -- note the extra
; "p" here (the second, high-order address word of the abs.L operand itself)
; relative to (xxx).W's own NCC=4(1/0/0).
; Combined with MOVE EA,Dn op-table: total r/p/w=1/2/0.
;
;   MOVE.L $3000.L,D2   (explicit .L suffix forces abs.L encoding even
;                        though the value itself would fit in abs.W --
;                        kept within this testbench's own 16KB memory
;                        window, unlike an address that genuinely needs
;                        the full 32 bits)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$DEADBEEF,d1
        movea.l #$3000,a0
        move.l  d1,(a0)
        bra.w   target

        org     $200
target:
        move.l  $3000.l,d2
        stop    #$2700
        dc.w    $2700
