; tests/timing_preview_cas2_match.s -- Track 3 #16 (CAS2, the LAST
; family in this whole track) verification, match path: CAS2's own
; final beat (`cas2_after_r`, the unified cooldown step both match and
; mismatch funnel through) is the new preview trigger. No hazard signal
; exists (both of CAS2's own register writes, Dc1/Dc2 on mismatch,
; commit 1-2 cycles BEFORE this trigger, already safely settled) -- this
; test's own job is confirming the trigger engages correctly and,
; critically for this most heavily bus-locked family in the project,
; that the full 4-sub-cycle sequence's own arbitration/AS-continuity
; still matches Musashi exactly.
;
;   CAS2.L D0:D1,D2:D3,(A4):(A5)   ; producer: both compares match ->
;                                  ; M[A4]<-D2, M[A5]<-D3
;   MOVE.L (A6),D4                 ; <-- NEXT: ordinary read, previewed
;                                  ;     via the new cas2_final_ack trigger

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.l  #$11111111,d0    ; Dc1 -- matches M[$300]
        move.l  #$22222222,d1    ; Dc2 -- matches M[$310]
        move.l  #$AAAAAAAA,d2    ; Du1 -- new value for M[$300] on match
        move.l  #$BBBBBBBB,d3    ; Du2 -- new value for M[$310] on match
        move.l  d0,$300          ; M[$300] = $11111111 (matches Dc1)
        move.l  d1,$310          ; M[$310] = $22222222 (matches Dc2)
        movea.l #$300,a4
        movea.l #$310,a5
        movea.l #$330,a6
        move.l  #$C0FFEE00,d5
        move.l  d5,(a6)          ; M[$330] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        cas2.l  d0:d1,d2:d3,(a4):(a5)  ; <-- producer: both match, M[$300]<-D2, M[$310]<-D3
        move.l  (a6),d4                ; <-- NEXT: ordinary read, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
