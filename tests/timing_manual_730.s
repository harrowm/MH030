; tests/timing_manual_730.s -- reproduces MC68030UM.pdf Figure 7-30's own
; Asynchronous Byte Read-Modify-Write Cycle -- 32-Bit Port: TAS's own
; locked read-then-write (AS held continuously across both phases).

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3010,a0
        move.b  #$00,(a0)
        move.l  #1,d7
        mulu.l  d7,d7           ; artificial stall -- see timing_manual_725.s
        tas     (a0)            ; RMW: locked read-then-write
        stop    #$2700
        dc.w    $2700
