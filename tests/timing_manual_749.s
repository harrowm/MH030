; tests/timing_manual_749.s -- reproduces MC68030UM.pdf Figure 7-49's own
; Bus Error without DSACKx: an ordinary read to a non-responding device
; is terminated by /BERR alone (never asserting /DSACKx or /STERM),
; dispatching a genuine Bus Error exception (vector 2).

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

        org     8               ; vector 2 = Bus Error
        dc.l    handler

        org     $100
start:
        movea.l #$3010,a0
        move.l  (a0),d0         ; faults: /BERR asserted, no /DSACKx ever

        org     $200
handler:
        moveq   #99,d5
selfloop:
        bra.s   selfloop
