; tests/timing_preview_pmove64_hazard2.s -- Track 3 #7 (PMOVE64)
; verification, variant 2: forces preview_ok to actually FIRE live,
; using the same artificial MULU.L-stall trick Phase 256/258/260/262/263
; established.
;
;   MULU.L D6,D7        ; long artificial stall
;   PMOVE (A0),CRP       ; producer: loads CRP (2 bus cycles, DT=2 valid)
;   MOVE.L (A1),D2       ; <-- NEXT: ordinary read, should preview correctly

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$300,a0
        move.l  #$12345670,d3
        move.l  d3,(a0)
        move.l  #$00000002,d3
        move.l  d3,$4(a0)
        movea.l #$320,a1
        move.l  #$C0FFEE00,d3
        move.l  d3,(a1)
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        pmove   (a0),crp         ; <-- producer: loads CRP (2 bus cycles)
        move.l  (a1),d2          ; <-- NEXT: ordinary read, should read M[$320]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
