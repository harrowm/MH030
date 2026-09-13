; tests/timing_preview_cas_mismatch_hazard2.s -- Track 3 #15 (CAS)
; verification, variant 2: forces preview_ok to actually FIRE live for
; CAS's own mismatch hazard case, using the same artificial MULU.L-stall
; trick established throughout this track.
;
;   MULU.L D6,D7        ; long artificial stall
;   CAS.L D0,D1,(A2)     ; producer: mismatch, D0 <- $DEADBEEF (this beat)
;   MOVE.L D0,(A3)       ; <-- NEXT: write D0, should be blocked from preview

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d0
        move.l  #$22222222,d1
        move.l  #$DEADBEEF,d3
        move.l  d3,$300
        movea.l #$300,a2
        movea.l #$330,a3
        move.l  #$AAAAAAAA,d3
        move.l  d3,(a3)
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        cas.l   d0,d1,(a2)       ; <-- producer: mismatch, D0 <- $DEADBEEF
        move.l  d0,(a3)          ; <-- NEXT: write D0, should be blocked from preview
        stop    #$2700
        dc.w    $2700
