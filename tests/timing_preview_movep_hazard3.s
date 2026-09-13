; tests/timing_preview_movep_hazard3.s -- Track 3 #3 (MOVEP) verification,
; variant 3: non-hazard control for variant 2. NEXT's own write-source
; (D3) is NOT the register MOVEP writes (D0), so movep_hazard should read
; 0 and preview_ok should actually fire (=1) live.
;
;   MULU.L  D6,D7          ; long artificial stall
;   MOVEP.L $0(A2),D0      ; producer: D0 <- $11223344 -- does NOT touch D3
;   MOVE.L  D3,(A1)        ; <-- NEXT: write-source D3 (untouched by MOVEP)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$300,a2
        move.b  #$11,$0(a2)
        move.b  #$22,$2(a2)
        move.b  #$33,$4(a2)
        move.b  #$44,$6(a2)
        movea.l #$320,a1
        move.l  #$AAAAAAAA,d3
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        movep.l $0(a2),d0        ; <-- producer: D0 <- $11223344, D3 untouched
        move.l  d3,(a1)          ; <-- NEXT: write D3 (=$AAAAAAAA) to M[$320]
        stop    #$2700
        dc.w    $2700
