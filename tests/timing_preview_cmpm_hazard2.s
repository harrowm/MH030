; tests/timing_preview_cmpm_hazard2.s -- Track 3 #11 (CMPM) verification,
; variant 2: non-hazard control for timing_preview_cmpm_hazard.s. NEXT's
; own base register (A3) is NOT the register CMPM's own final beat
; updates (A1=Ax), so cmpm_hazard should read 0 and preview_ok should
; actually fire (=1).
;
;   CMPM.L (A2)+,(A1)+   ; producer: A2,A1 postincrement -- A3 untouched
;   MOVE.L (A3),D3       ; <-- NEXT: base=A3 (untouched by the producer)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d3
        move.l  d3,$300
        move.l  d3,$320
        movea.l #$300,a2
        movea.l #$320,a1
        movea.l #$330,a3
        move.l  #$C0FFEE00,d5
        move.l  d5,(a3)          ; M[$330] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        cmpm.l  (a2)+,(a1)+      ; <-- producer: A2->$304, A1->$324 (A3 untouched)
        move.l  (a3),d3          ; <-- NEXT: base=A3, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
