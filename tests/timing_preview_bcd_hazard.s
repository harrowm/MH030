; tests/timing_preview_bcd_hazard.s -- Track 3 #9 (BCD-mem) verification:
; ABCD -(Ay),-(Ax)'s own final beat (phase 2's write ack, `bcds_final_ack`)
; is the new preview trigger. Structurally identical to ADDX/SUBX-mem:
; both Ay/Ax predecrement-pointer updates commit at EARLIER phases (0/1),
; strictly before phase 2, so no dedicated hazard signal exists -- this
; test's own job is confirming the trigger engages correctly and NEXT
; can safely use Ax's own just-decremented value.
;
;   ABCD.B -(A2),-(A1)   ; producer: A2,A1 predecrement by 1 each,
;                        ; M[A1-1] = BCD(M[A2-1] + M[A1-1] + X)
;   MOVE.B (A1),D3       ; <-- NEXT: base=A1 (already decremented),
;                        ;     reads the FRESH ABCD result (same address
;                        ;     ABCD just wrote)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.w  #0,ccr           ; clear X
        move.b  #$05,$30f        ; M[$30F] -- ABCD source operand (predec by 1 from $310)
        move.b  #$07,$31f        ; M[$31F] -- ABCD dest operand (predec by 1 from $320)
        movea.l #$310,a2
        movea.l #$320,a1
        bra.w   target

        org     $200
target:
        abcd    -(a2),-(a1)      ; <-- producer: M[$31F] = BCD(5+7+0) = $12
        move.b  (a1),d3          ; <-- NEXT: base=A1=$31F (just predecremented), reads $12
        stop    #$2700
        dc.w    $2700
