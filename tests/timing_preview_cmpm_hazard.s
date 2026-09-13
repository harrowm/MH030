; tests/timing_preview_cmpm_hazard.s -- Track 3 #11 (CMPM) verification:
; CMPM (Ay)+,(Ax)+'s own final beat (phase 2's read ack, `cmpm_final_ack`)
; coincides with Ax's OWN postincrement update (`cmpm_ax_wr_en`, via the
; dedicated an_wr_en port) -- CMPM has only 2 phases, so there is no
; earlier phase for Ax's update to land at, unlike ADDX-mem's own
; 3-phase timing. `cmpm_hazard` must block NEXT from previewing that
; same Ax with a stale (pre-postincrement) value.
;
;   CMPM.L (A2)+,(A1)+   ; producer: A2,A1 postincrement by 4 each (Ay=A2,Ax=A1)
;   MOVE.L (A1),D3       ; <-- NEXT: base=A1 (just postincremented THIS
;                        ;     cycle) -- must not preview using a STALE
;                        ;     (pre-postincrement) A1
;
; If cmpm_hazard did not correctly protect this, NEXT's own read could
; use the WRONG (pre-postincrement) address -- a genuinely wrong bus
; read, not just a missed optimization.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.l  #$11111111,d3
        move.l  d3,$300          ; M[$300] (Ay operand)
        move.l  d3,$320          ; M[$320] (Ax operand, equal -> Z=1, harmless)
        move.l  #$C0FFEE00,d3
        move.l  d3,$324          ; M[$324] -- NEXT's own real read target
        movea.l #$300,a2
        movea.l #$320,a1
        bra.w   target

        org     $200
target:
        cmpm.l  (a2)+,(a1)+      ; <-- producer: A2->$304, A1->$324 (last beat is the hazard point)
        move.l  (a1),d3          ; <-- NEXT: base=A1=$324 (just postincremented), reads $C0FFEE00
        stop    #$2700
        dc.w    $2700
