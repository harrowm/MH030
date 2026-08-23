; tests/timing/a4_scc_dn.s -- Phase 161 Part A Stage A4: SINGLE_OP 'Scc Dn'
; MC68030UM.pdf 11-43/11-44: Scc Dn NCC=4(0/1/0)
;
;   seq     d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #4,ccr
        clr.l   d2
        bra.w   target

        org     $200
target:
        seq     d2
after:
        stop    #$2700
        dc.w    $2700
