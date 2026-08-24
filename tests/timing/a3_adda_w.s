; tests/timing/a3_adda_w.s -- Phase 161 Part A Stage A3: ALU 'ADDA.W Rn,An'
; MC68030UM.pdf 11-40/41/42: ADDA.W Rn,An NCC=4(0/1/0)
; Cycle-accuracy-closing plan.md, item 3: watches A2 directly
; (watch_kind=1), no marker needed.
;
;   adda.w  d1,a2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #$10,d1
        movea.l #0,a2
        bra.w   target

        org     $200
target:
        adda.w  d1,a2
after:
        stop    #$2700
        dc.w    $2700
