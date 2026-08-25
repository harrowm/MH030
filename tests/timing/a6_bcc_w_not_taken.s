; tests/timing/a6_bcc_w_not_taken.s -- Phase 161 Part A Stage A6: COND_BRANCH 'Bcc.W (Not Taken)'
; MC68030UM.pdf 11-48/49: Bcc.W (Not Taken) NCC=6(0/1/0)
;
; watch_kind=3 (retirement-pulse tracking, reliable-baseline plan): Bcc
; not-taken writes no register/CCR (Bcc never writes CCR), so no trailing
; marker is needed -- completion is detected directly via Bcc's own
; EX->WB retirement.
;
;   bne.w   skip
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #4,ccr
        bra.w   target

        org     $200
target:
        bne.w   skip
skip:
after:
        stop    #$2700
        dc.w    $2700
