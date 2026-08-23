; tests/timing/a7_trapv_notrap.s -- Phase 161 Part A Stage A7: TRAPV (No Trap)
; MC68030UM.pdf 11-50: TRAPV (No Trap) NCC=4(0/1/0)
;
;   trapv     (V=0, no trap)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #0,ccr
        clr.l   d2
        bra.w   target

        org     $200
target:
        trapv
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700
