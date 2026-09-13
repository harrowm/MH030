; tests/timing_preview_cas_mismatch_hazard.s -- Track 3 #15 (CAS)
; verification, mismatch path: CAS.L D0,D1,(A2)'s own MISMATCH
; completion (`cas_get_du_r && !cas_z_r`) loads Dc (D0) via the SEPARATE
; `wr2_en`/`wr2_sel` direct port on the EXACT SAME cycle as the new
; `cas_final_ack` trigger. `cas_hazard` must block NEXT from previewing
; that same D0 with a stale (pre-CAS) value.
;
;   CAS.L D0,D1,(A2)   ; producer: M[A2] != D0 -> mismatch, D0 <- M[A2]
;                      ; (this beat)
;   MOVE.L D0,(A3)     ; <-- NEXT: write-source=D0 (just loaded THIS
;                      ;     cycle) -- must not preview using a STALE D0

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.l  #$11111111,d0    ; Dc -- deliberately WRONG (mismatch)
        move.l  #$22222222,d1    ; Du -- would-be update value (unused on mismatch)
        move.l  #$DEADBEEF,d3
        move.l  d3,$300          ; M[$300] -- the REAL value, != D0 -> mismatch
        movea.l #$300,a2
        movea.l #$330,a3
        move.l  #$AAAAAAAA,d3
        move.l  d3,(a3)          ; M[$330] = old value, must be overwritten by D0
        bra.w   target

        org     $200
target:
        cas.l   d0,d1,(a2)       ; <-- producer: mismatch, D0 <- $DEADBEEF (this beat)
        move.l  d0,(a3)          ; <-- NEXT: write D0 to M[$330], should write $DEADBEEF
        stop    #$2700
        dc.w    $2700
