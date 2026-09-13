; tests/timing_preview_movem_hazard2.s -- Track 3 #1 (MOVEM) verification,
; variant 2: forces preview_ok to actually FIRE live for the MOVEM case
; (variant 1, timing_preview_movem_hazard.s, proved end-state correctness
; but dec_valid was 0 at movem_last -- the prefetch queue hadn't reached
; the next instruction yet, the same "isolated, zero-head-start" queue-
; depth limitation Track 1/2 already documented). Mirrors the established
; fix: a long MULU.L before the sequence gives the IFU's own ambient
; readahead enough idle bus time to run several instructions ahead.
;
;   MULU.L  D6,D7            ; long artificial stall -- lets q_cnt build up
;   MOVEM.L (A2)+,D0-D1/A0   ; loads D0, D1, A0 (in that register order)
;   MOVE.L  (A0),D2          ; <-- NEXT: uses A0 (just loaded) as its own base

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$300,a2
        move.l  #$00000011,d3
        move.l  d3,(a2)         ; M[$300] = $11 -- becomes D0
        move.l  #$00000022,d3
        move.l  d3,$4(a2)       ; M[$304] = $22 -- becomes D1
        move.l  #$00000320,d3
        move.l  d3,$8(a2)       ; M[$308] = $320 -- becomes A0 (the hazard register)
        move.l  #$CCCCCCCC,d3
        move.l  d3,$320         ; M[$320] = $CCCCCCCC (NEXT's own real read target)
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        movem.l (a2)+,d0-d1/a0   ; <-- producer: loads D0=$11,D1=$22,A0=$320 (last)
        move.l  (a0),d2          ; <-- NEXT: base=A0, should read M[$320]=$CCCCCCCC
        stop    #$2700
        dc.w    $2700
