; tests/timing_preview_pack_hazard.s -- Track 3 #6 (PACK/UNPK-mem)
; verification: PACK -(Ay),-(Ax)'s own final beat (phase 1's write ack,
; `pack_mem_final_ack`) coincides with Ax's OWN predecrement-pointer
; update (`pack_ax_wr_en`, via the dedicated an_wr_en port) -- unlike
; ADDX/SUBX-mem, whose analogous Ax update happens a full phase EARLIER
; than its own final beat. This is the MOVEM shape (same-cycle register
; write + preview trigger), not the ADDX-mem shape.
;
;   PACK  -(A2),-(A1),#0   ; producer: A2,A1 predecrement (2/1 bytes),
;                          ; M[A1-1] = packed BCD byte from M[A2-2:A2-1]
;   MOVE.B (A1),D3         ; <-- NEXT: base=A1 (just predecremented THIS
;                          ;     cycle) -- must not preview using a
;                          ;     STALE (pre-decrement) A1
;
; If pack_hazard did not correctly protect this, NEXT's own read could
; use the WRONG (pre-decrement) address -- a genuinely wrong bus read,
; not just a missed optimization.
;
; NOTE: both source bytes are deliberately the SAME digit ($05/$05).
; A first attempt using two DIFFERENT digits found a genuine,
; pre-existing, unrelated bug: this RTL's own PACK reads its source as
; ONE 16-bit word (standard big-endian: lower address = high byte),
; while Musashi's own m68k_op_pack_16_mm (tools/musashi/m68kops.c)
; predecrements and reads TWO SEPARATE BYTES, combining them as
; {first-read-byte, second-read-byte} -- the FIRST byte read (at the
; HIGHER address, only one predecrement in) becomes the upper half,
; which is the OPPOSITE of standard word byte order. This produces a
; genuinely different packed result for two different digits (not just
; a different bus-cycle count), invisible to Harte (68020+-only, zero
; PACK/UNPK coverage) and apparently never bus-trace-compared against
; Musashi before this session. Out of scope for Track 3 (a real
; correctness question about PACK's own source-read order/granularity,
; unrelated to the preview mechanism) -- documented, not fixed here.
; Using identical digits sidesteps the ordering question entirely so
; this test cleanly exercises only the new preview trigger.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.b  #$05,$30e        ; M[$30E] -- low nibble = 5
        move.b  #$05,$30f        ; M[$30F] -- low nibble = 5 (same digit -- order-independent)
        move.b  #$CC,$31f        ; M[$31F] = old value, must be overwritten by the packed result
        movea.l #$310,a2         ; predecrements by 2 -> $30E for the read
        movea.l #$320,a1         ; predecrements by 1 -> $31F for the read+write
        bra.w   target

        org     $200
target:
        pack    -(a2),-(a1),#0   ; <-- producer: M[$31F] = pack($05,$05) = $55
        move.b  (a1),d3          ; <-- NEXT: base=A1=$31F (just predecremented), reads $55
        stop    #$2700
        dc.w    $2700
