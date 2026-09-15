; tests/timing_manual_744.s -- reproduces MC68030UM.pdf Figure 7-44/7-45's
; own Interrupt Acknowledge / Autovector Operation Timing: an ordinary read,
; followed by a genuine level-7 interrupt taken at the next instruction
; boundary (IACK bus cycle, autovectored), followed by the exception frame
; being pushed (the "WRITE STACK" phase both figures show).
;
; Loops in place after the read (matching tb/stall_fsm_tb.sv's own
; established "quiescent self-loop" convention for interrupt injection)
; rather than using STOP -- found, via direct trace, that recognizing an
; already-pending interrupt while genuinely STOPped takes much longer
; than recognizing one between ordinary instructions in this RTL.
;
; No longer lowers SR's own interrupt mask before looping (an earlier
; version of this test did, working around a real RTL gap --
; project_int_pending_level7_mask_gap.md -- where m68030_exc.sv's
; int_pending formula had no edge-triggered/non-maskable case for level
; 7, so a level-7 request asserted before anything lowered SR's own
; reset-default mask of 7 was never recognized. Fixed since (a sticky
; edge-detect latch, `nmi_pending_r`, ORed into int_pending); this test
; now exercises the harder, original scenario directly -- reset-default
; mask still at 7, and the request still recognized.
;
; The vector table entry at $7C stores a POINTER to the handler (real
; 68k semantics -- m68030_exc.sv's own EXC_FETCH state performs a real
; bus read of the table entry and loads THAT VALUE as the new PC), not
; the handler's own code directly. An earlier version of this test
; placed `rte` straight at $7C, which happened to still produce a
; correct-looking dispatch WAVEFORM (this diagram only needs the early
; IACK/frame-push cycles, not full completion) but would never actually
; complete a round-trip through RTE -- found while re-verifying the
; level-7 fix end-to-end (a pre-existing, unrelated test-construction
; bug, not an RTL one).
        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC
        org     $7C             ; level-7 autovector = vector 31, offset $7C
        dc.l    handler7        ; pointer to the real handler, below

        org     $100
start:
        movea.l #$3010,a0
        move.l  (a0),d0         ; READ CYCLE
loop:
        bra.s   loop

        org     $200
handler7:
        rte
