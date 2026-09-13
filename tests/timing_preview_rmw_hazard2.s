; tests/timing_preview_rmw_hazard2.s -- Track 3 #13 (general RMW)
; verification, variant 2: non-hazard control for
; timing_preview_rmw_hazard.s. NEXT's own base register (A3) is NOT the
; register the producer's own predecrement updates (A2), so
; mem_rmw_hazard should read 0 and preview_ok should actually fire (=1).
;
;   ASL.W -(A2)   ; producer: A2 predecrements -- does NOT touch A3
;   MOVE.L (A3),D3   ; <-- NEXT: base=A3 (untouched by the producer)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #$1234,$320
        movea.l #$322,a2
        movea.l #$330,a3
        move.l  #$C0FFEE00,d5
        move.l  d5,(a3)          ; M[$330] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        asl.w   -(a2)            ; <-- producer: M[$320]=$2468, A2 -> $320 (A3 untouched)
        move.l  (a3),d3          ; <-- NEXT: base=A3, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
