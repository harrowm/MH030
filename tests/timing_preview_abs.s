; tests/timing_preview_abs.s -- Track 1 Stage 2 verification (temporary,
; not part of the permanent §11.6 timing sweep): back-to-back register-
; indirect read then absolute-long read, isolated the same way
; tests/timing0.s/timing_preview.s are.
;
; Purpose: measure whether the second (absolute-addressed) read's own
; bus request begins the instant the first read's own ack arrives (the
; EU-side preview fast path extended to abs EA, Track 1 Stage 2,
; `~/.claude/plans/wobbly-honking-cascade.md`) or one cycle later.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3000,a0
        move.l  #$11111111,d4
        move.l  d4,(a0)
        move.l  #$22222222,d4
        move.l  d4,$00003020.l
        bra.w   target

        org     $200
target:
        nop                        ; runway: lets the IFU prefetch ahead
        nop                        ; far enough that instr #2's own
        nop                        ; extension words are already queued
        nop                        ; by the time instr #1 dispatches
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        move.l  (a0),d0            ; <-- instruction under test #1: (An)
        move.l  $00003020.l,d1     ; <-- instruction under test #2: (xxx).L, immediately follows
        stop    #$2700
        dc.w    $2700
