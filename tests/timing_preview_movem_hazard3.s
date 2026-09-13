; tests/timing_preview_movem_hazard3.s -- Track 3 #1 (MOVEM) verification,
; variant 3: non-hazard control for variant 2. NEXT's own base register
; (A1) is NOT one MOVEM writes, so movem_hazard should read 0 and
; preview_ok should actually fire (=1) live, proving the mechanism
; positively engages for MOVEM, not just correctly stays inert.
;
;   MULU.L  D6,D7            ; long artificial stall -- lets q_cnt build up
;   MOVEM.L (A2)+,D0-D1/A0   ; loads D0, D1, A0 -- does NOT touch A1
;   MOVE.L  (A1),D2          ; <-- NEXT: base=A1 (untouched by MOVEM)

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
        move.l  d3,$8(a2)       ; M[$308] = $320 -- becomes A0
        move.l  #$00000340,a1
        move.l  #$CCCCCCCC,d3
        move.l  d3,$340         ; M[$340] = $CCCCCCCC (NEXT's own real read target, via A1)
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        movem.l (a2)+,d0-d1/a0   ; <-- producer: loads D0=$11,D1=$22,A0=$320
        move.l  (a1),d2          ; <-- NEXT: base=A1 (untouched), should read M[$340]=$CCCCCCCC
        stop    #$2700
        dc.w    $2700
