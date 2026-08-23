; tests/timing/a4_tas_dn.s -- Phase 161 Part A Stage A4: SINGLE_OP 'TAS Dn'
; MC68030UM.pdf 11-43/11-44: TAS Dn NCC=4(0/1/0)
;
;   tas     d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        tas     d2
after:
        stop    #$2700
        dc.w    $2700
