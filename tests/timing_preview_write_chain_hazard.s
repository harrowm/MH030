; tests/timing_preview_write_chain_hazard.s -- companion to
; timing_preview_write_chain.s: MOVE.L D0,-(A1) (write, predecrements
; A1) immediately followed by MOVE.L D2,(A1) (write, using the
; just-decremented A1 as its own EA base) -- a genuine hazard. Confirms
; the pre-existing generic hazard_ex mechanism (no new dedicated hazard
; signal was added for the write-as-CURRENT case) correctly blocks
; preview here, matching Musashi's own end-state exactly regardless.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3014,a1
        move.l  #$11111111,d0
        move.l  #$22222222,d2
        bra.w   target

        org     $200
target:
        move.l  d0,-(a1)        ; <-- instruction under test #1 (write, predecrement A1 to $3010)
        move.l  d2,(a1)         ; <-- instruction under test #2 (write, using the just-decremented A1)
        stop    #$2700
        dc.w    $2700
