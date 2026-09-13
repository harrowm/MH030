; tests/timing_preview_cas_match.s -- Track 3 #15 (CAS) verification,
; match path: CAS.L D0,D1,(A2)'s own MATCH completion (`cas_after_r`,
; one cycle after the real bus write's own ack) is the SECOND arm of the
; new `cas_final_ack` trigger -- the write goes to MEMORY, not a
; register, so no hazard signal is needed for this path; this test's own
; job is confirming the trigger engages correctly (and, given CAS's own
; bus-locked nature, that the sequence's own arbitration/AS-continuity
; still matches Musashi exactly) for the MATCH/write-completion arm
; specifically, distinct from the mismatch arm already covered above.
;
;   CAS.L D0,D1,(A2)   ; producer: M[A2] == D0 -> match, M[A2] <- D1
;                      ;  (real bus write, then 1-cycle cooldown)
;   MOVE.L (A3),D3     ; <-- NEXT: ordinary read, previewed via the
;                      ;     cas_after_r arm of cas_final_ack

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.l  #$DEADBEEF,d0    ; Dc -- matches the real memory value
        move.l  #$22222222,d1    ; Du -- new value to write on match
        move.l  d0,$300          ; M[$300] = $DEADBEEF (matches D0 -> match)
        movea.l #$300,a2
        movea.l #$330,a3
        move.l  #$C0FFEE00,d5
        move.l  d5,(a3)          ; M[$330] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        cas.l   d0,d1,(a2)       ; <-- producer: match, M[$300] <- $22222222
        move.l  (a3),d3          ; <-- NEXT: ordinary read, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
