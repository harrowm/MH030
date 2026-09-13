; tests/timing_preview_idx_current_idx.s -- Track 2 Stage 2.1 verification:
; proves the new dedicated rd_prev_a/rd_prev_b ports let indexed-EA preview
; fire even when the CURRENT instruction is ITSELF indexed -- a case Track
; 1 Stage 4 deliberately excluded (its own !ex_is_idx guard), since it
; reused the current instruction's own rd_b port for Xn.
;
;   MOVE.L (0,A2,D6.L),D0   ; CURRENT: indexed read (uses rd_b for D6 today)
;   MOVE.L (0,A1,D3.L),D1   ; NEXT: indexed read -- should now ALSO preview

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a2
        move.l  #$00000000,d6   ; Xn for CURRENT: offset 0
        move.l  #$AAAAAAAA,d4
        move.l  d4,(a2)          ; M[$300] = $AAAAAAAA (CURRENT's own target, A2+0+D6)
        movea.l #$310,a1
        move.l  #$00000004,d3   ; Xn for NEXT: offset 4
        move.l  #$BBBBBBBB,d4
        move.l  d4,$4(a1)        ; M[$314] = $BBBBBBBB (NEXT's own target, A1+0+D3)
        bra.w   target

        org     $200
target:
        move.l  (0,a2,d6.l),d0  ; <-- CURRENT: indexed read (itself uses Xn)
        move.l  (0,a1,d3.l),d1  ; <-- NEXT: indexed read, immediately follows
        stop    #$2700
        dc.w    $2700
