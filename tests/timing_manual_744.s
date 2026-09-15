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
; Explicitly lowers SR's own interrupt mask to 0 before looping. Found,
; via direct trace (project_int_pending_level7_mask_gap.md), that this
; RTL's own int_pending formula (rtl/m68030_exc.sv) is a plain level
; comparison (requested > mask) with NO edge-triggered/non-maskable
; special case for level 7 -- since reset leaves SR's mask at 7, a
; level-7 request asserted before anything lowers the mask is NEVER
; recognized (request(7) > mask(7) is false). Every existing interrupt
; test in this project happens to inject after other code has already
; lowered the mask, so this gap was never exercised before. Worked
; around here (matches how a real program would behave regardless --
; SR mask is essentially always lowered from its reset default well
; before any interrupt-driven code path matters); flagged as a real,
; separate, unfixed finding, not silently worked around without note.
        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3010,a0
        move.l  (a0),d0         ; READ CYCLE
        move.w  #$2000,sr       ; lower interrupt mask to 0 (S=1,mask=0)
loop:
        bra.s   loop

        org     $7C             ; level-7 autovector = vector 31, offset $7C
handler7:
        rte
