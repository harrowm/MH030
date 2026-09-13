; tests/timing_preview_movemm_idx.s -- Track 3 #10 (MOVE mem-to-mem
; indexed-dst) verification: MOVE (ea_src),(d8,An,Xn)'s own final beat
; (the write-phase ack, `move_mm_final_ack`) is the new preview trigger.
; This family is ALSO one of dyn_bit_get_Dn's 5 consumer families (its
; own swap fires at the SOURCE READ's own ack, a different cycle than
; this new trigger's own final WRITE ack) -- this test's own job is
; confirming no interaction/regression: the bus trace must match
; Musashi exactly for the indexed-destination case specifically (the
; higher-risk sub-case the plan's own item name flags).
;
;   MOVE.L (A0),(0,A1,D2.L)   ; producer: mem-to-mem, indexed dst = A1+D2
;   MOVE.L (A3),D4            ; <-- NEXT: ordinary read, previewed via
;                             ;     the new move_mm_final_ack trigger

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a0
        move.l  #$DEADBEEF,d5
        move.l  d5,(a0)          ; M[$300] = $DEADBEEF (source operand)
        movea.l #$310,a1
        move.l  #$10,d2          ; index -> dest EA = A1+D2 = $320
        movea.l #$330,a3
        move.l  #$C0FFEE00,d5
        move.l  d5,(a3)          ; M[$330] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        move.l  (a0),(0,a1,d2.l)  ; <-- producer: M[$320] = $DEADBEEF
        move.l  (a3),d4           ; <-- NEXT: ordinary read, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
