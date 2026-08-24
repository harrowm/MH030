; tests/timing/a5_bftst_dn.s -- Phase 161 Part A Stage A5: BIT_FIELD 'BFTST Dn'
; MC68030UM.pdf 11-45/46/47: BFTST Dn NCC=8(0/1/0)
; Cycle-accuracy-closing plan.md, item 3: watches CCR directly
; (watch_kind=2), no marker needed -- also closes a known blind spot
; (Stage A6/Phase 163 Stage 1's own writeup: "a5_bftst_dn has the
; identical marker-overcounting blind spot... not caught by the
; classifier"). BFTST: Z=set if field all-zero, N=MSB of field,
; V/C always cleared, X unaffected (standard bit-field-op semantics).
; D2=0, field={0:8} all-zero -> Z=1,N=0,V=0,C=0,X unaffected. CCR
; baseline $10 (Z=0) before target -> result $14, a genuine transition.
;
;   bftst   d2{0:8}
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #0,d2
        move.w  #$10,ccr
        bra.w   target

        org     $200
target:
        bftst   d2{0:8}
after:
        stop    #$2700
        dc.w    $2700
