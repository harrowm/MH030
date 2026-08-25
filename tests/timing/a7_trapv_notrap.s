; tests/timing/a7_trapv_notrap.s -- Phase 161 Part A Stage A7: TRAPV (No Trap)
; MC68030UM.pdf 11-50: TRAPV (No Trap) NCC=4(0/1/0)
;
; watch_kind=3 (retirement-pulse tracking, reliable-baseline plan): TRAPV
; with V=0 writes no register/CCR, so no trailing marker is needed --
; completion is detected directly via TRAPV's own EX->WB retirement.
;
;   trapv     (V=0, no trap)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #0,ccr
        bra.w   target

        org     $200
target:
        trapv
after:
        stop    #$2700
        dc.w    $2700
