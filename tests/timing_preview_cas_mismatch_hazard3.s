; tests/timing_preview_cas_mismatch_hazard3.s -- Track 3 #15 (CAS)
; verification, variant 3: non-hazard control for variant 2. NEXT's own
; write-source (D5) is NOT the register CAS writes on mismatch (D0), so
; cas_hazard should read 0 and preview_ok should actually fire (=1).
;
;   MULU.L D6,D7        ; long artificial stall
;   CAS.L D0,D1,(A2)     ; producer: mismatch, D0 <- $DEADBEEF -- D5 untouched
;   MOVE.L D5,(A3)       ; <-- NEXT: write-source=D5 (untouched by CAS)

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
        move.l  #$C0FFEE00,d5    ; D5 -- NEXT's own write-source, untouched by CAS
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        cas.l   d0,d1,(a2)       ; <-- producer: mismatch, D0 <- $DEADBEEF (D5 untouched)
        move.l  d5,(a3)          ; <-- NEXT: write D5 to M[$330], should write $C0FFEE00
        stop    #$2700
        dc.w    $2700
