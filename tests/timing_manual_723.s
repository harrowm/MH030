; tests/timing_manual_723.s -- reproduces MC68030UM.pdf Figure 7-23's own
; Long-Word Read -- 16-Bit Port: a single MOVE.L (An),Dn against a 16-bit
; dynamic-sizing port splits into 2 word sub-cycles.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$100,a0
        move.l  #1,d7
        mulu.l  d7,d7           ; artificial stall -- see timing_manual_725.s
        move.l  (a0),d0         ; LONGWORD READ -- 16-bit port, splits to 2 beats
        stop    #$2700
        dc.w    $2700
