; tests/timing_preview_d16.s -- Track 1 Stage 3 verification (temporary,
; not part of the permanent §11.6 timing sweep): back-to-back plain
; register-indirect read then (d16,An) read, isolated the same way
; tests/timing0.s/timing_preview.s are.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$3000,a0
        movea.l #$3010,a1
        move.l  #$11111111,d4
        move.l  d4,(a0)
        move.l  #$22222222,d4
        move.l  d4,$10(a1)
        bra.w   target

        org     $200
target:
        divu.w  #1,d3           ; artificial-stall filler: bus-idle for
                                 ; many cycles, unlike NOP (which fetches
                                 ; a new opcode about as fast as it
                                 ; retires, leaving no real surplus
                                 ; window) -- lets the IFU build genuine
                                 ; prefetch depth ahead of target's own
                                 ; two instructions.
        move.l  (a0),d0         ; <-- instruction under test #1: (An)
        move.l  $10(a1),d1      ; <-- instruction under test #2: (d16,An), immediately follows
        stop    #$2700
        dc.w    $2700
