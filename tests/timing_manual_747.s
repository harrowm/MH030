; tests/timing_manual_747.s -- reproduces MC68030UM.pdf Figure 7-47's own
; Breakpoint Acknowledge Cycle Timing: BKPT #7 dispatches a CPU-space read
; at address bkpt_num*4 ($1C), the peripheral supplies a substitute opcode
; word via ordinary /DSACK response (matches tb/stall_fsm_tb.sv's own
; established BKPT-live-substitution convention), and execution continues
; with the substituted instruction.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

        org     $1C             ; BKPT #7's own fixed CPU-space address (7*4)
        dc.w    $702A           ; substitute opcode: MOVEQ #42,D0

        org     $100
start:
        movea.l #$3010,a0
        move.l  (a0),d0         ; READ CYCLE
        bkpt    #7
loop:
        bra.s   loop
