; tests/timing_preview_movem_hazard.s -- Track 3 #1 (MOVEM) verification
; (`~/.claude/plans/wobbly-honking-cascade.md`): MOVEM.L (A2)+,D0-D1/A0
; loads A0 as its own LAST register in the list, then the immediately
; following instruction uses that SAME A0 as its own base register for
; an ordinary read.
;
;   MOVEM.L (A2)+,D0-D1/A0   ; loads D0, D1, A0 (in that register order)
;   MOVE.L  (A0),D2          ; <-- NEXT: uses A0 (just loaded) as its own base
;
; If preview_ok's own new movem_hazard check did NOT correctly cover
; movem_wr_en's own load of A0 (the final register in the list), this
; could preview D2's own address using a STALE A0 (pre-MOVEM) value --
; a genuinely wrong bus address, not just a missed optimization. Musashi
; has no such preview mechanism, so a correct DUT must match its bus
; trace exactly regardless of whether ITS OWN preview_ok fires here.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a2        ; MOVEM's own source pointer
        move.l  #$00000011,d3
        move.l  d3,(a2)         ; M[$300] = $11 -- becomes D0
        move.l  #$00000022,d3
        move.l  d3,$4(a2)       ; M[$304] = $22 -- becomes D1
        move.l  #$00000320,d3
        move.l  d3,$8(a2)       ; M[$308] = $320 -- becomes A0 (the hazard register)
        move.l  #$CCCCCCCC,d3
        move.l  d3,$320         ; M[$320] = $CCCCCCCC (NEXT's own real read target)
        bra.w   target

        org     $200
target:
        movem.l (a2)+,d0-d1/a0  ; <-- producer: loads D0=$11,D1=$22,A0=$320 (last)
        move.l  (a0),d2         ; <-- NEXT: base=A0, should read M[$320]=$CCCCCCCC
        stop    #$2700
        dc.w    $2700
