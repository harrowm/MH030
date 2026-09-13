; tests/timing_preview_movep_hazard2.s -- Track 3 #3 (MOVEP) verification,
; variant 2: forces preview_ok to actually FIRE live for MOVEP's own
; hazard case, using the same artificial MULU.L-stall trick Phase 256/258
; established to give the IFU's own readahead a head start.
;
;   MULU.L  D6,D7          ; long artificial stall
;   MOVEP.L $0(A2),D0      ; producer: D0 <- $11223344 (last beat is the hazard point)
;   MOVE.L  D0,(A1)        ; <-- NEXT: write D0, should be blocked from preview

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
        move.l  #$AAAAAAAA,d5
        move.l  d5,(a1)
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        movep.l $0(a2),d0        ; <-- producer: D0 <- $11223344
        move.l  d0,(a1)          ; <-- NEXT: write D0 to M[$320], should write $11223344
        stop    #$2700
        dc.w    $2700
