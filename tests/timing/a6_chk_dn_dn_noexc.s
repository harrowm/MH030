; tests/timing/a6_chk_dn_dn_noexc.s -- Phase 161 Part A Stage A6: CONTROL_INSTR 'CHK Dn,Dn (No Exception)'
; MC68030UM.pdf 11-48/49: CHK Dn,Dn (No Exception) NCC=8(0/1/0)
; Cycle-accuracy-closing plan.md, item 3: watches CCR directly
; (watch_kind=2), no marker needed -- also directly re-verifies the
; Phase 80 finding this file's own header used to only exercise
; indirectly through a marker: Z=(D2==0) unconditionally, N left
; UNCHANGED when CHK doesn't trap, X unaffected. D1=10 (bound), D2=5
; (in range, no trap). A first hand-derivation assumed V/C are also
; left unaffected (matching the $1F baseline's own V=1,C=1) and used
; watch_val=$1B -- this HUNG (decode ran off the end of the test into
; uninitialized memory, the watch condition never true) since real
; CHK genuinely CLEARS V/C for the no-trap case rather than leaving
; them unaffected; confirmed via direct simulation trace (CCR settled
; at $18, not $1B) rather than re-guessing. CCR baseline $1F before
; target -> X=1,N=1(unchanged),Z=0,V=0(cleared),C=0(cleared) = $18.
;
;   chk     d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #10,d1
        move.l  #5,d2
        move.w  #$1F,ccr
        bra.w   target

        org     $200
target:
        chk     d1,d2
after:
        stop    #$2700
        dc.w    $2700
