; tests/timing_manual_726.s -- reproduces MC68030UM.pdf Figure 7-26's own
; word-write-then-byte-write-then-byte-write chain (word @ +0, byte @
; +2, byte @ +3), the write-cycle mirror of Figure 7-21, via REAL
; decoded instructions.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3010,a0
        move.l  #$abcd1234,d4
        move.l  d4,(a0)         ; scratch-fill so unwritten lanes read something recognisable
        move.l  #$1000,d0
        moveq   #86,d1          ; $56
        moveq   #120,d2         ; $78
        move.l  #1,d7
        mulu.l  d7,d7           ; artificial stall -- see timing_manual_chain.s
        move.w  d0,(a0)         ; WORD write @ $3010
        move.b  d1,(2,a0)       ; BYTE write @ $3012
        move.b  d2,(3,a0)       ; BYTE write @ $3013
        move.l  (a0),d3         ; trailing read-back -- watch register for $finish
        stop    #$2700
        dc.w    $2700
