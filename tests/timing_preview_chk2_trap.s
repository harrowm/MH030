; tests/timing_preview_chk2_trap.s -- Track 3 #2 (CMP2/CHK2) verification:
; CHK2's own trap-on-completion case. `chk_trap` fires on the exact same
; cycle `cmp2_run_r && mem_ack` (the new preview trigger's own condition)
; would otherwise fire preview_ok -- the new `cmp2_final_ack = cmp2_run_r
; && mem_ack && !chk_trap` exclusion must suppress the preview entirely
; here, else a phantom bus read for the never-executed fall-through
; instruction would be dispatched (the same "unrequested phantom cycle"
; bug class Phase 254 flagged as a real correctness issue, not just a
; missed optimization). Verified by full bus-trace comparison against
; Musashi: if the exclusion works, our own trace exactly matches
; Musashi's (trap dispatch, no M[$320] read); if it doesn't, an extra
; read cycle at $320 appears in the DUT trace that Musashi's never has.
;
;   CHK2.L (A1),D2     ; D2=$5, OUT of range [$10,$20] -- traps (vector 6)
;   MOVE.L (A3),D4     ; <-- would-be NEXT (never reached if trap works)

        org     0
        dc.l    $00010000
        dc.l    start

        ; start: is placed well clear of the vector 6 slot ($18) that
        ; setup writes below -- an earlier draft placed start at address
        ; 8, which put the $18 write squarely inside that same setup
        ; code's own later instruction bytes (genuine self-modifying-code
        ; corruption, not an RTL bug: the vector write landed inside a
        ; still-unexecuted MOVE.L's own immediate operand, corrupting it
        ; before it was ever fetched).
        org     $100
start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.l  #handler,$18    ; vector 6 (CHK/CHK2) -> handler (VBR=0 at reset)
        movea.l #$300,a1
        move.l  #$00000010,d3
        move.l  d3,(a1)          ; M[$300] = lower bound = $10
        move.l  #$00000020,d3
        move.l  d3,$4(a1)        ; M[$304] = upper bound = $20
        move.l  #$00000005,d2    ; D2 = $5, OUT of range [$10,$20] -- must trap
        movea.l #$320,a3
        move.l  #$DEADBEEF,d3
        move.l  d3,(a3)          ; M[$320] -- must NEVER be read if the trap correctly redirects
        bra.w   target

        org     $200
target:
        chk2.l  (a1),d2          ; <-- CHK2, D2 out of range -- traps, no fall-through
        move.l  (a3),d4          ; <-- would-be NEXT, unreachable if trap works
        stop    #$2700

        org     $400
handler:
        stop    #$2700
        dc.w    $2700
