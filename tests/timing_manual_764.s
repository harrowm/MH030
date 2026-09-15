; tests/timing_manual_764.s -- reproduces MC68030UM.pdf Figure 7-64's own
; Initial Reset Operation Timing: the bus stays high-impedance while
; /RESET is held, then the ISP (initial SSP/PC) read starts once it's
; released.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
loop:
        bra.s   loop
