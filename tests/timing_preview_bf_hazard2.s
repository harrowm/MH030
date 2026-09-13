; tests/timing_preview_bf_hazard2.s -- Track 3 #5 (bitfield-mem)
; verification, variant 2: forces preview_ok to actually FIRE live for
; the hazard case, using the same artificial MULU.L-stall trick
; Phase 256/258/260 established.
;
;   MULU.L D6,D7            ; long artificial stall
;   BFEXTU (A0){0:8},D0     ; producer: D0 <- $AB (final beat is the hazard point)
;   MOVE.L D0,(A1)          ; <-- NEXT: write D0, should be blocked from preview

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$300,a0
        move.l  #$AB000000,d3
        move.l  d3,(a0)
        movea.l #$320,a1
        move.l  #$CCCCCCCC,d3
        move.l  d3,(a1)
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        bfextu  (a0){0:8},d0     ; <-- producer: D0 <- $AB
        move.l  d0,(a1)          ; <-- NEXT: write D0 to M[$320], should write $AB
        stop    #$2700
        dc.w    $2700
