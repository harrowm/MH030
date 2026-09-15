; tests/timing_manual_760.s -- reproduces MC68030UM.pdf Figure 7-60's own
; Bus Arbitration Operation Timing: an external DMA device requests the
; bus (/BR) mid-instruction-stream, the CPU grants it (/BG) once the
; current cycle completes and releases the bus, the device acknowledges
; (/BGACK) and holds the bus for a while, then releases it back.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3010,a0
loop:
        move.l  (a0),d0
        bra.s   loop
