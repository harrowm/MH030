; tests/timing_preview_movep_hazard.s -- Track 3 #3 (MOVEP) verification:
; MOVEP's own final byte-beat ack (`movep_last`) is the new preview
; trigger. MOVEP writes a register via its own direct wr_en/movep_wr_sel
; port (always Dn, never An -- MOVEP's own EA is fixed d16(An), no
; auto-inc/dec), bypassing the generic hazard_ex/hazard_wb mechanism
; entirely, mirroring MOVEM's own shape (`movep_hazard`).
;
;   MOVEP.L $0(A2),D0   ; producer: loads D0 from 4 interleaved bytes
;   MOVE.L  D0,(A1)     ; <-- NEXT: plain write, D0 is the write-source
;                       ;     (dec_src_reg for a write == the value being
;                       ;     written, per the read/write field-role-
;                       ;     swap convention) -- previewed via
;                       ;     preview_is_write/rd_prev_c
;
; If movep_hazard did not correctly protect this, NEXT's own write could
; preview a STALE D0 (pre-MOVEP) value -- a genuinely wrong bus write,
; not just a missed optimization.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a2
        move.b  #$11,$0(a2)
        move.b  #$22,$2(a2)
        move.b  #$33,$4(a2)
        move.b  #$44,$6(a2)     ; MOVEP.L $0(A2),D0 assembles these 4 bytes -> D0=$11223344
        movea.l #$320,a1
        move.l  #$AAAAAAAA,d5
        move.l  d5,(a1)         ; M[$320] = old value, must be overwritten by D0's real value
        bra.w   target

        org     $200
target:
        movep.l $0(a2),d0        ; <-- producer: D0 <- $11223344 (last beat is the hazard point)
        move.l  d0,(a1)          ; <-- NEXT: write D0 to M[$320], should write $11223344
        stop    #$2700
        dc.w    $2700
