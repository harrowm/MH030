; tests/timing_preview_write_chain.s -- post-Track-3 gap closure
; (wobbly-honking-cascade.md): confirms preview_ok now engages when
; CURRENT is an ordinary WRITE, not just a read. MOVE.L D0,(A0)
; immediately followed by MOVE.L D2,(A1) (plain, non-indexed writes to
; two independent registers, no hazard between them) -- proves preview
; fires for a genuine write->write pair with the correct previewed
; address, matching Musashi exactly.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3010,a0
        movea.l #$3020,a1
        move.l  #$11111111,d0
        move.l  #$22222222,d2
        bra.w   target

        org     $200
target:
        move.l  d0,(a0)         ; <-- instruction under test #1 (write)
        move.l  d2,(a1)         ; <-- instruction under test #2 (write, independent register)
        stop    #$2700
        dc.w    $2700
