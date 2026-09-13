; tests/timing_preview_write_hazard.s -- Track 2 Stage 2.2 verification:
; a producer that writes the register the following-but-one instruction
; uses as its own write-DATA source, with an ordinary read in between
; (whose own ack is the exact cycle preview_ok would fire for the write
; preview).
;
;   MOVE.L (A2)+,D3     ; producer: D3 <- M[A2], A2 += 4
;   MOVE.L (A0),D0      ; CURRENT: plain (An) read -- triggers preview_ok
;   MOVE.L D3,(A1)      ; NEXT: plain register-source write -- previewed
;
; If preview_ok's own hazard_ex/hazard_wb checks didn't correctly cover
; dec_src_reg for a WRITE's own source register (Track 2 Stage 2.2's new
; rd_prev_c), this could preview a STALE D3 as the write data -- a
; genuinely wrong bus write, not just a missed optimization. Musashi has
; no such preview mechanism, so a correct DUT must match its bus trace
; exactly regardless of whether ITS OWN preview_ok fires here or not.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a2
        move.l  #$00000004,d4
        move.l  d4,(a2)          ; M[$300] = 4 -- this becomes D3 via the producer
        movea.l #$310,a0
        move.l  #$AAAAAAAA,d4
        move.l  d4,(a0)          ; M[$310] = $AAAAAAAA (CURRENT's own read target)
        movea.l #$320,a1
        bra.w   target

        org     $200
target:
        move.l  (a2)+,d3         ; <-- producer: D3 <- 4, A2 -> $304
        move.l  (a0),d0          ; <-- CURRENT: plain (An) read, triggers preview
        move.l  d3,(a1)          ; <-- NEXT: plain register-source write -- should write M[$320]=4
        stop    #$2700
        dc.w    $2700
