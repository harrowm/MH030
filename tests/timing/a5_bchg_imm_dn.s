; tests/timing/a5_bchg_imm_dn.s -- Phase 161 Part A Stage A5: BIT_MANIP 'BCHG #(data),Dn'
; MC68030UM.pdf 11-45/46/47: BCHG #(data),Dn NCC=6(0/1/0)
;
;   bchg    #0,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        bchg    #0,d2
after:
        stop    #$2700
        dc.w    $2700
