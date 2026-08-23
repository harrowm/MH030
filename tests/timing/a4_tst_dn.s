; tests/timing/a4_tst_dn.s -- Phase 161 Part A Stage A4: SINGLE_OP 'TST Dn'
; MC68030UM.pdf 11-43/11-44: TST Dn NCC=2(0/1/0)
;
;   tst.l   d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        tst.l   d2
        move.l  #$cafebabe,d3
after:
        stop    #$2700
        dc.w    $2700
