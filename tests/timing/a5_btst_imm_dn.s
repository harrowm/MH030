; tests/timing/a5_btst_imm_dn.s -- Phase 161 Part A Stage A5: BIT_MANIP 'BTST #(data),Dn'
; MC68030UM.pdf 11-45/46/47: BTST #(data),Dn NCC=4(0/1/0)
; Cycle-accuracy-closing plan.md, item 3: watches CCR directly
; (watch_kind=2), no marker needed. BTST only ever affects Z (N/V/C/X
; explicitly unaffected, standard 68k semantics); CCR baseline $10
; (Z=0) before target -- bit 5 of $FFFFFFDF is 0, so BTST sets Z=1 ->
; CCR=$14, a genuine Z:0->1 transition.
;
;   btst    #5,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$FFFFFFDF,d2
        move.w  #$10,ccr
        bra.w   target

        org     $200
target:
        btst    #5,d2
after:
        stop    #$2700
        dc.w    $2700
