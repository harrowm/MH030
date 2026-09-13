; tests/timing_preview_cas_match2.s -- Track 3 #15 (CAS) verification,
; variant 2: forces preview_ok to actually FIRE live for CAS's own
; MATCH/write-completion arm (`cas_after_r`), using the same artificial
; MULU.L-stall trick established throughout this track.
;
;   MULU.L D6,D7        ; long artificial stall
;   CAS.L D0,D1,(A2)     ; producer: match, M[A2] <- D1 (real bus write)
;   MOVE.L (A3),D3       ; <-- NEXT: ordinary read, should preview correctly

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$DEADBEEF,d0
        move.l  #$22222222,d1
        move.l  d0,$300
        movea.l #$300,a2
        movea.l #$330,a3
        move.l  #$C0FFEE00,d5
        move.l  d5,(a3)
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        cas.l   d0,d1,(a2)       ; <-- producer: match, M[$300] <- $22222222
        move.l  (a3),d3          ; <-- NEXT: ordinary read, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
