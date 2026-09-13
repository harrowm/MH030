; tests/timing_preview_movemm_hazard.s -- Track 3 #10 (MOVE mem-to-mem)
; verification: the NON-indexed destination auto-increment form
; (MOVE.L (A0),(A1)+) sets `move_mm_dst_an_upd_r`, so
; `move_mm_dst_an_wr_en` (A1's own postincrement update, via the same
; dedicated `an_wr_en` port MOVEM's own `movem_an_wr_en` uses) fires on
; the EXACT SAME cycle as this family's own final beat -- the MOVEM/PACK
; shape, protected by the new `move_mm_hazard`.
;
;   MOVE.L (A0),(A1)+   ; producer: A1 postincrements by 4 THIS beat,
;                       ; M[$320] = M[A0]
;   MOVE.L D3,(A1)      ; <-- NEXT: base=A1 (just postincremented),
;                       ;     must write to the NEW address, not stale

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a0
        move.l  #$DEADBEEF,d5
        move.l  d5,(a0)          ; M[$300] = $DEADBEEF (source operand)
        movea.l #$320,a1
        move.l  #$C0FFEE00,d3
        move.l  #$AAAAAAAA,d5
        move.l  d5,$324          ; M[$324] = old value, must be overwritten by D3
        bra.w   target

        org     $200
target:
        move.l  (a0),(a1)+       ; <-- producer: M[$320]=$DEADBEEF, A1 -> $324
        move.l  d3,(a1)          ; <-- NEXT: base=A1=$324 (just postincremented), writes D3
        stop    #$2700
        dc.w    $2700
