; tests/timing_manual_725.s -- reproduces MC68030UM.pdf Figure 7-25's own
; Read-Write-Write-Read longword chain (zero-wait-state portion only;
; the figure's own final "read with wait states" segment isn't
; reproduced here, a separate, cosmetic feature not central to what
; this diagram demonstrates -- the chaining of DIFFERENT cycle
; DIRECTIONS back to back with zero idle gap, now closed for both
; read-as-CURRENT and write-as-CURRENT, wobbly-honking-cascade.md).

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3010,a0
        move.l  #$11111111,d4
        move.l  d4,(a0)
        moveq   #0,d0
        move.l  #$22222222,d1
        move.l  #$33333333,d2
        moveq   #0,d3
        move.l  #1,d7
        mulu.l  d7,d7           ; artificial stall -- see timing_manual_chain.s
        move.l  (a0),d0         ; READ
        move.l  d1,(a0)         ; WRITE
        move.l  d2,(a0)         ; WRITE
        move.l  (a0),d3         ; READ
        stop    #$2700
        dc.w    $2700
