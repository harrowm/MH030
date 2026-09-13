; tests/timing_preview_rmw_hazard.s -- Track 3 #13 (general RMW)
; verification: ASL.W -(A2)'s own 2-phase FSM (read then write, via
; ORDINARY non-locked bus cycles -- confirmed `mem_rmw` is asserted only
; for TAS, not this family) writes A2's own predecrement update via
; `mem_rmw_an_wr_en` on the EXACT SAME cycle as the new
; `mem_rmw_final_ack` trigger. `mem_rmw_hazard` must block NEXT from
; previewing that same A2 with a stale (pre-decrement) value.
;
; A2 starts at $322 (predecrements by 2 -- the shift-memory family is
; ALWAYS word-sized, no `.L` form exists for it) landing on the
; 4-byte-aligned $320, deliberately avoiding addr&2==2. A first attempt
; landing on $31E ($320-2) found a genuine, PRE-EXISTING tooling quirk
; in tools/m68ksim.c's own reference logging: for a WORD READ at an
; address where addr&2==2 (not longword-aligned), it logs the ADDRESS
; field rounded down to the containing longword boundary (e.g. $31C
; instead of the real $31E), while WRITES at the identical address log
; correctly. This is a logging-only artifact in the reference tool's own
; read-hook, unrelated to Track 3, the RTL, or this family specifically
; -- confirmed no existing test in this project's own cosim suite had
; ever full-compared (not reads-only) a word read at an addr%4==2
; address before. Documented, not fixed (out of scope for Track 3);
; sidestepped here by choosing an aligned landing address instead.
;
; The 3 leading NOPs settle a benign IFU-readahead fetch-reordering
; artifact (already documented elsewhere in this project) enough that
; the CRITICAL portion of the trace -- the producer's own read+write and
; NEXT's own hazard-protected read -- matches Musashi byte-for-byte in
; the identical cycle order (confirmed directly). A residual mismatch
; remains further out, entirely AFTER both instructions of interest have
; completed and been verified correct: Musashi re-reads its own
; just-fetched opcode word a second time at that point (a quirk of
; tools/m68ksim's own internal bookkeeping, not a real bus event) --
; harmless and out of scope, verified via direct trace inspection rather
; than chased further.
;
;   ASL.W -(A2)      ; producer: A2 predecrements by 2 THIS beat,
;                    ; M[A2-2] <<= 1
;   MOVE.W (A2),D3   ; <-- NEXT: base=A2 (just predecremented), must not
;                    ; preview using a STALE (pre-decrement) A2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.w  #$1234,$320      ; M[$320] -- ASL operand (predec by 2 from $322)
        movea.l #$322,a2
        bra.w   target

        org     $200
target:
        nop
        nop
        nop
        asl.w   -(a2)            ; <-- producer: M[$320] = $2468, A2 -> $320
        move.w  (a2),d3          ; <-- NEXT: base=A2=$320 (just predecremented), reads $2468
        nop
        nop
        stop    #$2700
        dc.w    $2700
