; tests/timing/d0_bfffo_early.s -- Phase 162 Stage D0: BFFFO Dn scan-depth
; check -- the set bit sits at the very first (MSB) position of a 32-bit
; field, the shallowest possible scan. Paired with d0_bfffo_late.s (set bit
; at the very last position, the deepest possible scan).
;
;   bfffo   d2{0:32},d3   -- D2=$80000000, first set bit at offset 0
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$80000000,d2
        move.l  #$FFFFFFFF,d3
        bra.w   target

        org     $200
target:
        bfffo   d2{0:32},d3
after:
        stop    #$2700
        dc.w    $2700
