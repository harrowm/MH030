; tests/timing_preview_idx_hazard.s -- Track 1 Stage 4 hazard verification
; (`~/.claude/plans/wobbly-honking-cascade.md`): a producer that writes the
; SAME register the following-but-one instruction uses as its own Xn index
; register for an indexed EA preview, with an ordinary read in between
; (the one whose own ack is the exact cycle preview_ok would fire on).
;
;   MOVE.L (A2)+,D3     ; producer: D3 <- M[A2], A2 += 4
;   MOVE.L (A0),D0      ; CURRENT: plain (An) read -- triggers preview_ok
;   MOVE.L (0,A1,D3.L),D1  ; NEXT: indexed EA using D3 as Xn -- previewed
;
; If preview_ok's own hazard_ex/hazard_wb checks did NOT correctly cover
; dec_dst_reg (Xn) the way they already do for dec_src_reg, this could
; preview D1's own address using a STALE D3 (pre-producer-write) value --
; a genuinely wrong bus address/data, not just a missed optimization.
; Musashi has no such preview mechanism at all, so a correct DUT must
; match its bus trace exactly regardless of whether ITS OWN preview_ok
; fires here or not.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window (Phase 237's own already-documented aliasing
        ; gotcha) -- every address below stays inside [0,$FFF] and clear
        ; of this test's own code (0-$30ish, $200-$212ish).
        movea.l #$300,a2       ; producer's own source pointer
        move.l  #$00000004,d4
        move.l  d4,(a2)        ; M[$300] = 4 -- this becomes D3 via the producer
        movea.l #$310,a0       ; CURRENT's own base
        movea.l #$310,a1       ; NEXT's own base (same page, offset via D3)
        move.l  #$AAAAAAAA,d4
        move.l  d4,(a0)        ; M[$310] = $AAAAAAAA (CURRENT's own read target)
        move.l  #$BBBBBBBB,d4
        move.l  d4,$4(a1)      ; M[$314] = $BBBBBBBB (NEXT's real target: A1+0+D3(4))
        bra.w   target

        org     $200
target:
        move.l  (a2)+,d3        ; <-- producer: D3 <- 4, A2 -> $2004
        move.l  (a0),d0         ; <-- CURRENT: plain (An) read, triggers preview
        move.l  (0,a1,d3.l),d1  ; <-- NEXT: indexed EA, Xn=D3 -- should read M[$3004]=$BBBBBBBB
        stop    #$2700
        dc.w    $2700
