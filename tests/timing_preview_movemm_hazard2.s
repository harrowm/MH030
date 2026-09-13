; tests/timing_preview_movemm_hazard2.s -- Track 3 #10 (MOVE mem-to-mem)
; verification, variant 2: non-hazard control for
; timing_preview_movemm_hazard.s. NEXT's own base register (A3) is NOT
; the register the producer's own postincrement updates (A1), so
; move_mm_hazard should read 0 and preview_ok should actually fire (=1).
;
;   MOVE.L (A0),(A1)+   ; producer: A1 postincrements -- does NOT touch A3
;   MOVE.L (A3),D4      ; <-- NEXT: base=A3 (untouched by the producer)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$300,a0
        move.l  #$DEADBEEF,d5
        move.l  d5,(a0)
        movea.l #$320,a1
        movea.l #$330,a3
        move.l  #$C0FFEE00,d5
        move.l  d5,(a3)          ; M[$330] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        move.l  (a0),(a1)+       ; <-- producer: M[$320]=$DEADBEEF, A1 -> $324 (A3 untouched)
        move.l  (a3),d4          ; <-- NEXT: base=A3, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
