; tests/timing/a5_btst_imm_dn.s -- Phase 161 Part A Stage A5: BIT_MANIP 'BTST #(data),Dn'
; MC68030UM.pdf 11-45/46/47: BTST #(data),Dn NCC=4(0/1/0)
;
;   btst    #5,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$FFFFFFDF,d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        btst    #5,d2
        seq     d3
after:
        stop    #$2700
        dc.w    $2700
