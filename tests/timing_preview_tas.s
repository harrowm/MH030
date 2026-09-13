; tests/timing_preview_tas.s -- Track 3 #14 (TAS) verification: TAS
; (A2)'s own final beat (the RMW-locked write's own ack, `tas_final_ack`)
; is the new preview trigger. No dedicated hazard signal exists (TAS
; writes no Dn/An register through any port -- only the memory byte
; itself and CCR) -- this test's own job is confirming the trigger
; engages correctly and, critically for this GENUINELY bus-locked
; family, that arbitration continuity/bus-lock release still matches
; Musashi exactly (no phantom bus activity around the lock boundary).
;
;   TAS (A2)         ; producer: RMW-locked read+write at M[A2]
;   MOVE.L (A3),D3   ; <-- NEXT: ordinary read, previewed via the new
;                    ;     tas_final_ack trigger

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a2
        move.b  #$05,$300        ; M[$300] -- TAS operand (bit 7 clear, N=0)
        movea.l #$330,a3
        move.l  #$C0FFEE00,d5
        move.l  d5,(a3)          ; M[$330] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        tas     (a2)             ; <-- producer: RMW-locked, M[$300] bit7 set -> $85
        move.l  (a3),d3          ; <-- NEXT: ordinary read, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
