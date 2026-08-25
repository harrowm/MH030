; tests/timing/a6_nop.s -- Phase 161 Part A Stage A6: CONTROL_INSTR 'NOP'
; MC68030UM.pdf 11-48/49: NOP NCC=2(0/1/0)
;
; watch_kind=3 (retirement-pulse tracking, reliable-baseline plan): NOP has
; no observable Dn/An/CCR/memory effect at all, so no trailing marker is
; needed -- completion is detected directly via NOP's own EX->WB retirement.
;
;   nop
        org     0
        dc.l    $00010000
        dc.l    start

start:
        bra.w   target

        org     $200
target:
        nop
after:
        stop    #$2700
        dc.w    $2700
