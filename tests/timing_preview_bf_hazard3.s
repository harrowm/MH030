; tests/timing_preview_bf_hazard3.s -- Track 3 #5 (bitfield-mem)
; verification, variant 3: non-hazard control for variant 2. NEXT's own
; write-source (D3) is NOT the register BFEXTU writes (D0), so
; bf_hazard should read 0 and preview_ok should actually fire (=1) live.
;
;   MULU.L D6,D7            ; long artificial stall
;   BFEXTU (A0){0:8},D0     ; producer: D0 <- $AB -- does NOT touch D3
;   MOVE.L D3,(A1)          ; <-- NEXT: write-source D3 (untouched by BFEXTU)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$300,a0
        move.l  #$AB000000,d3
        move.l  d3,(a0)
        movea.l #$320,a1
        move.l  #$AAAAAAAA,d3
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        bfextu  (a0){0:8},d0     ; <-- producer: D0 <- $AB, D3 untouched
        move.l  d3,(a1)          ; <-- NEXT: write D3 (=$AAAAAAAA) to M[$320]
        stop    #$2700
        dc.w    $2700
