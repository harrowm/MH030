; tests/timing_manual_chain.s -- reproduces MC68030UM.pdf Figure 7-21's
; own word-read-then-byte-read-then-byte-read chain (word @ +0, byte @
; +2, byte @ +3, all within the same test longword) via REAL decoded
; instructions driven through the full EU/decode pipeline, for a direct,
; apples-to-apples comparison against the manual figure -- unlike
; tests/timing_preview.s (two back-to-back LONGWORD reads only), this
; exercises the WORD/BYTE preview paths specifically, and unlike
; timing_diagrams/tb/read_cycle_tb.sv (drives m68030_biu directly, no
; preview possible by construction), this goes through real decode.
;
; The MULU.L stall is the established Phase 256 technique: (2,a0)/(3,a0)
; are `(d16,An)` forms needing their own 16-bit extension word, and this
; project's own "isolated, zero-head-start" construction otherwise can't
; get the IFU's own readahead far enough ahead in time -- a long,
; bus-silent ALU-only instruction gives the IFU genuine idle time to
; prefetch past it during its own multi-cycle execution. No isolating
; branch is used (unlike timing_preview.s's own deliberate "zero head
; start" construction) -- this program falls straight through, letting
; the IFU prefetch ahead naturally during the MULU.L, matching how the
; debug-trace MULU.L variants throughout Track 3 were built.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3010,a0
        move.l  #$12345678,d4
        move.l  d4,(a0)
        moveq   #0,d0
        moveq   #0,d1
        moveq   #0,d2
        move.l  #1,d7
        mulu.l  d7,d7           ; artificial stall -- see header
        move.w  (a0),d0         ; word read  @ $3010 -> D31-D16 = $1234
        move.b  (2,a0),d1       ; byte read  @ $3012 -> D15-D8  = $56
        move.b  (3,a0),d2       ; byte read  @ $3013 -> D7-D0   = $78
        stop    #$2700
        dc.w    $2700
