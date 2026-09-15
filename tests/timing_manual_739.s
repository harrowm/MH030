; tests/timing_manual_739.s -- reproduces MC68030UM.pdf Figure 7-39's own
; Long-Word Operand Request from $07 with Burst Request -- CBACK Negated
; Early: a D-cache miss with DBE (burst enable) set triggers a burst line
; fill, but the peripheral negates /CBACK after the first beat, aborting
; the burst early (real 68030 semantics: the in-flight beat still
; completes normally, but no further beats follow).

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        move.l  #$1100,d7       ; DBE=1 (bit12), dcache_en=1 (ED, bit8)
        movec   d7,cacr
        move.l  #1,d6
        mulu.l  d6,d6           ; artificial stall -- gives CACR's own write
                                 ; time to settle before the burst-triggering
                                 ; read below dispatches (see timing_manual_738.s)
        movea.l #$3000,a0       ; 16-byte-aligned -- a clean burst line
        move.l  (a0),d0         ; D-cache miss -> triggers burst fill (aborted early)
loop:
        bra.s   loop
