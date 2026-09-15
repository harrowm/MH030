; tests/timing_manual_754.s -- reproduces MC68030UM.pdf Figure 7-54's own
; Asynchronous Late Retry: a write cycle where the device asserts DSACKx
; (indicating success) but a fault is detected late and /BERR + /HALT
; assert anyway, forcing a retry -- the retried write then completes
; cleanly with no further fault.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

        org     $100
start:
        movea.l #$3010,a0
        move.l  #$AABBCCDD,(a0) ; write -- late BERR+HALT on the first attempt only
        stop    #$2700          ; halts outright -- no further fetches to pollute
                                 ; the diagram's own "last N cycles" capture window
        dc.w    $2700
