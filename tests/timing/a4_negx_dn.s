; tests/timing/a4_negx_dn.s -- Phase 161 Part A Stage A4: SINGLE_OP 'NEGX Dn'
; MC68030UM.pdf 11-43/11-44: NEGX Dn NCC=2(0/1/0)
;
;   negx.l  d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #0,ccr
        move.l  #5,d2
        bra.w   target

        org     $200
target:
        negx.l  d2
after:
        stop    #$2700
        dc.w    $2700
