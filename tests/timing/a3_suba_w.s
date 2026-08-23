; tests/timing/a3_suba_w.s -- Phase 161 Part A Stage A3: ALU 'SUBA.W Rn,An'
; MC68030UM.pdf 11-40/41/42: SUBA.W Rn,An NCC=4(0/1/0)
;
;   suba.w  d1,a2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #5,d1
        movea.l #$10,a2
        clr.l   d2
        bra.w   target

        org     $200
target:
        suba.w  d1,a2
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
