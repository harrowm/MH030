; tests/timing_preview_cmp2_hazard.s -- Track 3 #2 (CMP2/CHK2) verification:
; CMP2's own second (upper-bound) read ack is `cmp2_final_ack`
; (cmp2_run_r && mem_ack && !chk_trap), the new preview_current_ready
; trigger. CMP2 never traps, so this exercises the ordinary "final beat,
; safe to preview NEXT" case directly.
;
;   CMP2.L (A0),D1     ; D1=$18 in range [$10,$20] -- no trap, sets CCR only
;   MOVE.L (A2),D4     ; <-- NEXT: ordinary read, should preview correctly
;
; CMP2/CHK2 write no general register (only CCR via cmp2_sr_wr_en) --
; unlike MOVEM there is no register-value hazard to prove; this test's
; purpose is confirming the bus trace (and therefore the previewed
; address) matches Musashi exactly for this family's own final-beat
; trigger.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a0
        move.l  #$00000010,d3
        move.l  d3,(a0)          ; M[$300] = lower bound = $10
        move.l  #$00000020,d3
        move.l  d3,$4(a0)        ; M[$304] = upper bound = $20
        move.l  #$00000018,d1    ; D1 = $18, in range [$10,$20]
        movea.l #$310,a2
        move.l  #$CCCCCCCC,d3
        move.l  d3,(a2)          ; M[$310] = $CCCCCCCC (NEXT's own real read target)
        bra.w   target

        org     $200
target:
        cmp2.l  (a0),d1          ; <-- producer/current: CMP2, in range, no trap
        move.l  (a2),d4          ; <-- NEXT: ordinary read, previewed via cmp2_final_ack
        stop    #$2700
        dc.w    $2700
