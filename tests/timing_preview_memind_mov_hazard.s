; tests/timing_preview_memind_mov_hazard.s -- Track 3 #12 (memory-
; indirect) verification: MOVE-via-memind's own outer-read completion
; writes the resolved VALUE directly to Dn via `memind_wr_en` on the
; EXACT SAME cycle as the new `memind_outer_final_ack` trigger --
; `memind_wr_hazard` must block NEXT from previewing that same Dn (as a
; write-source) with a stale value.
;
;   MOVE.L ([$10,A0],D1.L),D2   ; producer: D2 <- M32[M32[A0+$10]+D1] (this beat)
;   MOVE.L D2,(A3)              ; <-- NEXT: write-source=D2 (just loaded
;                               ;     THIS cycle) -- must not preview
;                               ;     using a STALE D2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$100,a0
        move.l  #$100,d1
        move.l  #$200,d4
        move.l  d4,$110          ; pointer: M32[A0+$10] = $200
        move.l  #$DEADBEEF,d4
        move.l  d4,$300          ; value at final EA ($200+$100=$300)
        movea.l #$330,a3
        move.l  #$AAAAAAAA,d4
        move.l  d4,(a3)          ; M[$330] = old value, must be overwritten by D2
        bra.w   target

        org     $200
target:
        move.l  ([$10,a0],d1.l),d2   ; <-- producer: D2 <- $DEADBEEF (this beat)
        move.l  d2,(a3)               ; <-- NEXT: write D2 to M[$330], should write $DEADBEEF
        stop    #$2700
        dc.w    $2700
