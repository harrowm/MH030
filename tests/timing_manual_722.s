; tests/timing_manual_722.s -- reproduces MC68030UM.pdf Figure 7-22's own
; Long-Word Read -- 8-Bit Port with CLOUT Asserted: a single MOVE.L (An),Dn
; against an 8-bit dynamic-sizing port splits into 4 individual byte
; sub-cycles (biu_sizing_fsm.sv's own dynamic bus sizing FSM).

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$100,a0
        move.l  #1,d7
        mulu.l  d7,d7           ; artificial stall -- see timing_manual_725.s
        move.l  (a0),d0         ; LONGWORD READ -- 8-bit port, splits to 4 beats
        stop    #$2700
        dc.w    $2700
