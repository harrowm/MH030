; tests/timing/a5_roxl_dn.s -- Phase 161 Part A Stage A5: SHIFT_ROTATE 'ROXd Dn'
; MC68030UM.pdf 11-45/46/47: ROXL.L #1,Dn NCC=12(0/1/0)
;
;   roxl.l  #1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #0,ccr
        move.l  #1,d2
        bra.w   target

        org     $200
target:
        roxl.l  #1,d2
after:
        stop    #$2700
        dc.w    $2700
