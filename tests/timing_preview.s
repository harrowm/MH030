; tests/timing_preview.s — Stage 2c verification (temporary, not part of
; the permanent §11.6 timing sweep): two back-to-back plain register-
; indirect reads, MOVE.L (A0),D0 then MOVE.L (A1),D1, isolated the same
; way tests/timing0.s is (taken branch landing directly on the pair, far
; enough away the IFU's own readahead can't have reached it first).
;
; Purpose: measure whether the second read's own bus request begins the
; instant the first read's own ack arrives (the EU-side preview fast
; path, `~/.claude/plans/wobbly-honking-cascade.md` Stage 2) or one
; cycle later (the pre-fix behavior).

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3000,a0
        movea.l #$3010,a1
        move.l  #$11111111,d4
        move.l  d4,(a0)
        move.l  #$22222222,d4
        move.l  d4,(a1)
        bra.w   target

        org     $200
target:
        move.l  (a0),d0         ; <-- instruction under test #1
        move.l  (a1),d1         ; <-- instruction under test #2 (immediately follows)
        stop    #$2700
        dc.w    $2700
