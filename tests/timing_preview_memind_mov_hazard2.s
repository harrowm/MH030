; tests/timing_preview_memind_mov_hazard2.s -- Track 3 #12 (memory-
; indirect) verification, variant 2: non-hazard control for
; timing_preview_memind_mov_hazard.s. NEXT's own write-source (D5) is
; NOT the register the producer writes (D2), so memind_wr_hazard should
; read 0 and preview_ok should actually fire (=1).
;
;   MOVE.L ([$10,A0],D1.L),D2   ; producer: D2 <- $DEADBEEF -- does NOT touch D5
;   MOVE.L D5,(A3)              ; <-- NEXT: write-source=D5 (untouched by the producer)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$100,a0
        move.l  #$100,d1
        move.l  #$200,d4
        move.l  d4,$110
        move.l  #$DEADBEEF,d4
        move.l  d4,$300
        movea.l #$330,a3
        move.l  #$C0FFEE00,d5    ; D5 -- NEXT's own write-source, untouched by producer
        bra.w   target

        org     $200
target:
        move.l  ([$10,a0],d1.l),d2   ; <-- producer: D2 <- $DEADBEEF (D5 untouched)
        move.l  d5,(a3)               ; <-- NEXT: write D5 to M[$330], should write $C0FFEE00
        stop    #$2700
        dc.w    $2700
