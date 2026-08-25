; tests/timing/a2_move_an_usp.s -- Phase 161 Part A Stage A2: Special-Purpose
; MOVE table "MOVE An,USP" row. MC68030UM.pdf 11-39: Head=4,Tail=0,
; NCC=4(0/1/0).
;
; watch_kind=3 (retirement-pulse tracking, reliable-baseline plan): USP
; isn't directly watchable via any of watch_kind 0/1/2, and previously
; needed a 2-instruction marker chain to read it back into a Dn -- now
; detected directly via MOVE An,USP's own EX->WB retirement, no marker
; chain needed at all.
;
;   MOVE A1,USP

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$9abc,a1
        bra.w   target

        org     $200
target:
        move.l  a1,usp
after:
        stop    #$2700
        dc.w    $2700
