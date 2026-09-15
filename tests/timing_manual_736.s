; tests/timing_manual_736.s -- reproduces MC68030UM.pdf Figure 7-36's own
; Synchronous Read-Modify-Write Cycle Timing -- CIIN Asserted: TAS's own
; locked read-then-write (RMC held throughout), this time terminated via
; /STERM instead of /DSACKx for both the read and write phase.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3010,a0
        move.b  #$00,(a0)
        move.l  #1,d7
        mulu.l  d7,d7           ; artificial stall -- see timing_manual_725.s
        tas     (a0)            ; RMW: locked read-then-write, /STERM-terminated
        stop    #$2700
        dc.w    $2700
