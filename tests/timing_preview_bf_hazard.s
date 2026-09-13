; tests/timing_preview_bf_hazard.s -- Track 3 #5 (bitfield-mem)
; verification: BFEXTU's own memory-EA form (non-mutating, single read
; phase) writes its extracted result to Dn via its own direct
; bf_dn_wr_en/bf_mem_dn_r port -- NOT through ex_dest_reg/wb_dest_reg --
; on the exact same cycle bf_mem_final_ack fires (the new preview
; trigger). `bf_hazard` must block NEXT from previewing that same Dn
; with a stale (pre-BFEXTU) value.
;
;   BFEXTU (A0){0:8},D0   ; producer: D0 <- top 8 bits of M[A0] (=$AB)
;   MOVE.L D0,(A1)        ; <-- NEXT: write-source D0, previewed via
;                         ;     preview_is_write/rd_prev_c
;
; If bf_hazard did not correctly protect this, NEXT's own write could
; preview a STALE D0 -- a genuinely wrong bus write, not just a missed
; optimization.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        movea.l #$300,a0
        move.l  #$AB000000,d3
        move.l  d3,(a0)          ; M[$300] = $AB000000 -- top byte is the field BFEXTU extracts
        movea.l #$320,a1
        move.l  #$CCCCCCCC,d3
        move.l  d3,(a1)          ; M[$320] = old value, must be overwritten by D0's real value ($AB)
        bra.w   target

        org     $200
target:
        bfextu  (a0){0:8},d0     ; <-- producer: D0 <- $000000AB (final beat is the hazard point)
        move.l  d0,(a1)          ; <-- NEXT: write D0 to M[$320], should write $AB
        stop    #$2700
        dc.w    $2700
