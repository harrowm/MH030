; tests/timing_manual_732.s -- reproduces MC68030UM.pdf Figure 7-32's own
; Synchronous Read with CIIN Asserted and CBACK Negated: a single
; MOVE.L (An),Dn terminated via /STERM instead of /DSACKx.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3010,a0
        move.l  (a0),d0         ; synchronous read, terminated by /STERM
        stop    #$2700
        dc.w    $2700
