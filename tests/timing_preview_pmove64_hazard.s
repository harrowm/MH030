; tests/timing_preview_pmove64_hazard.s -- Track 3 #7 (PMOVE64)
; verification: PMOVE CRP/SRP's own 2-phase FSM (phase 0: bus cycle at
; An, phase 1: bus cycle at An+4) final beat is `pmove64_final_ack`, the
; new preview trigger. No dedicated hazard signal exists (CRP/SRP are
; internal MMU state, never a Dn/An register; the EA is fixed (An),
; no auto-inc/dec is even decoded) -- this test's own job is confirming
; the trigger engages correctly and the bus trace matches Musashi
; exactly, the same shape as CMP2's own non-trapping verification.
;
;   PMOVE (A0),CRP     ; producer: loads CRP from M[A0]/M[A0+4]
;                      ; (DT=2, a valid descriptor type, so no MMU
;                      ; Configuration Exception fires)
;   MOVE.L (A1),D2     ; <-- NEXT: ordinary read, previewed via the
;                      ;     new pmove64_final_ack trigger

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a0
        move.l  #$12345670,d3
        move.l  d3,(a0)          ; M[$300] = CRP hi word
        move.l  #$00000002,d3
        move.l  d3,$4(a0)        ; M[$304] = CRP lo word, DT=2 (valid, no trap)
        movea.l #$320,a1
        move.l  #$C0FFEE00,d3
        move.l  d3,(a1)          ; M[$320] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        pmove   (a0),crp         ; <-- producer: loads CRP (2 bus cycles)
        move.l  (a1),d2          ; <-- NEXT: ordinary read, should read M[$320]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
