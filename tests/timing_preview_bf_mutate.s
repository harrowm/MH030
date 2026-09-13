; tests/timing_preview_bf_mutate.s -- Track 3 #5 (bitfield-mem)
; verification: the MUTATING path (BFCLR, phase 1's own memory write
; ack, no Dn destination at all -- bf_dn_wr_en is structurally 0 for
; every mutating op) exercises the SECOND half of bf_mem_final_ack's
; own OR-condition (`bf_mem_phase_r` alone, not the non-mutating
; sub-case tested by timing_preview_bf_hazard.s). Confirms bf_hazard
; stays naturally inert (no Dn write to protect) and the ordinary
; preview still engages correctly for whatever genuinely follows.
;
; Uses a FULL 32-bit-wide field ({0:32}) deliberately: a first attempt
; with a narrow {0:8} field found a genuine, PRE-EXISTING, unrelated bug
; -- bf_mem_run_r's own read/write dispatch (`mem_siz`,
; `eu_seq_execute.svh`) is hardwired to always access a full longword
; regardless of the field's real offset+width footprint (confirmed via
; `git log -S` this predates Track 3 entirely -- last touched at Phase
; 261/ADDX-SUBX-mem, which never touched this line). Real 68030 silicon
; presumably narrows the access to the field's own minimal byte span;
; Musashi's own reference correctly reads/writes a single BYTE for an
; 8-bit field at offset 0, while this RTL always does a longword --
; genuinely out of scope for Track 3 (a pre-existing correctness gap in
; the family's own bus-dispatch sizing, unrelated to the preview
; mechanism this track is closing) and documented, not fixed, matching
; this project's own established deferred-finding precedent. Sidestepped
; here by using a field that genuinely needs the full longword by
; construction, so this test exercises ONLY the preview trigger, not the
; unrelated sizing gap.
;
;   BFCLR (A0){0:32}     ; producer: clears all 32 bits of M[A0], no Dn write
;   MOVE.L (A1),D2       ; <-- NEXT: ordinary read, previewed via the
;                        ;     new bf_mem_final_ack trigger

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$300,a0
        move.l  #$FFFFFFFF,d3
        move.l  d3,(a0)          ; M[$300] = $FFFFFFFF -- BFCLR should zero the top byte
        movea.l #$320,a1
        move.l  #$C0FFEE00,d3
        move.l  d3,(a1)          ; M[$320] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        bfclr   (a0){0:32}       ; <-- producer: M[$300] fully cleared -> $00000000
        move.l  (a1),d2          ; <-- NEXT: ordinary read, should read M[$320]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
