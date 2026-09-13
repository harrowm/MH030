; tests/timing_preview_cas2_mismatch.s -- Track 3 #16 (CAS2)
; verification, mismatch path: CAS2's own MISMATCH completion (Dc1/Dc2
; loaded via cas2_dc1_wr_r/cas2_dc2_wr_r, THEN cas2_after_r -- confirmed
; both writes commit 1-2 cycles BEFORE this new trigger, already safely
; settled by the time it fires) exercises the second structural path
; through cas2_final_ack, distinct from the match path above.
;
;   CAS2.L D0:D1,D2:D3,(A4):(A5)   ; producer: Dc1 mismatches ->
;                                  ; D0<-M[A4], D1<-M[A5]
;   MOVE.L (A6),D4                 ; <-- NEXT: ordinary read, previewed
;                                  ;     via cas2_final_ack

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.l  #$99999999,d0    ; Dc1 -- deliberately WRONG (mismatch)
        move.l  #$22222222,d1    ; Dc2 -- would also be compared but Dc1 already mismatches
        move.l  #$AAAAAAAA,d2    ; Du1 -- unused (mismatch, no write)
        move.l  #$BBBBBBBB,d3    ; Du2 -- unused (mismatch, no write)
        move.l  #$DEADBEEF,d6
        move.l  d6,$300          ; M[$300] = $DEADBEEF (!= D0 -> mismatch)
        move.l  #$22222222,d6
        move.l  d6,$310          ; M[$310] = $22222222
        movea.l #$300,a4
        movea.l #$310,a5
        movea.l #$330,a6
        move.l  #$C0FFEE00,d5
        move.l  d5,(a6)          ; M[$330] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        cas2.l  d0:d1,d2:d3,(a4):(a5)  ; <-- producer: mismatch, D0<-$DEADBEEF, D1<-$22222222
        move.l  (a6),d4                ; <-- NEXT: ordinary read, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
