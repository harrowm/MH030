; tests/timing_manual_738.s -- reproduces MC68030UM.pdf Figure 7-38's own
; Long-Word Operand Request from $07 with Burst Request and Wait Cycle:
; a D-cache miss with DBE (burst enable) set triggers a 4-longword burst
; line fill, terminated via /STERM per beat with /CBREQ-/CBACK handshake.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        move.l  #$1100,d7       ; DBE=1 (bit12), dcache_en=1 (ED, bit8)
        movec   d7,cacr
        move.l  #1,d6
        mulu.l  d6,d6           ; artificial stall -- see timing_manual_725.s;
                                 ; gives CACR's own write time to settle before
                                 ; the burst-triggering read below dispatches --
                                 ; found while re-verifying this diagram after a
                                 ; later biu_burst_ctrl.sv fix (project CBACK
                                 ; per-beat sampling): without this, the read
                                 ; raced CACR and dispatched as a genuine
                                 ; non-burst single-longword miss FIRST, with
                                 ; the real burst only starting on a SEPARATE,
                                 ; second access -- a pre-existing test-timing
                                 ; artifact, not something the RTL fix itself
                                 ; introduced (confirmed via direct trace).
        movea.l #$3000,a0       ; 16-byte-aligned -- a clean burst line
        move.l  (a0),d0         ; D-cache miss -> triggers burst fill
loop:
        bra.s   loop
