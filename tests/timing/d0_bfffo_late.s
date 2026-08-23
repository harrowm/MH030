; tests/timing/d0_bfffo_late.s -- Phase 162 Stage D0: same as
; d0_bfffo_early.s but the set bit sits at the very LAST (LSB) position of
; the 32-bit field -- the deepest possible scan. If this RTL's own
; measured clock count matches d0_bfffo_early.s exactly, BFFFO's own gap
; is flat regardless of scan depth, not data-dependent.
;
;   bfffo   d2{0:32},d3   -- D2=$00000001, first set bit at offset 31
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$00000001,d2
        move.l  #$FFFFFFFF,d3
        bra.w   target

        org     $200
target:
        bfffo   d2{0:32},d3
after:
        stop    #$2700
        dc.w    $2700
