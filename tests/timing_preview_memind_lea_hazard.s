; tests/timing_preview_memind_lea_hazard.s -- Track 3 #12 (memory-
; indirect, Group B) verification: LEA's own memind resolution (via
; memind_addr_only_r) writes the resolved address DIRECTLY to An via
; `memind_addr_wr_en` on the EXACT SAME cycle as the new
; `memind_inner_final_ack` trigger -- `memind_addr_hazard` must block
; NEXT from previewing that same An with a stale value.
;
;   LEA ([$100,A0],D1.L),A2   ; producer: A2 <- M32[A0+$100]+D1 (this beat)
;   MOVE.L (A2),D3            ; <-- NEXT: base=A2 (just loaded THIS
;                             ;     cycle) -- must not preview using a
;                             ;     STALE (pre-LEA) A2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a0
        move.l  #$4,d1
        move.l  #$310,d4
        move.l  d4,$400          ; M32[A0+$100] = $310 (the pointer LEA reads)
        move.l  #$C0FFEE00,d4
        move.l  d4,$314          ; M[$314] -- NEXT's own real read target ($310+$4)
        bra.w   target

        org     $200
target:
        lea     ([$100,a0],d1.l),a2   ; <-- producer: A2 <- $310+$4 = $314 (this beat)
        move.l  (a2),d3               ; <-- NEXT: base=A2=$314 (just loaded), reads $C0FFEE00
        stop    #$2700
        dc.w    $2700
