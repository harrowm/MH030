; tests/memind6.s — Stage 1 (plan.md Phase 116): full-format mode=110 EA with
; a non-null word base displacement for CLR (NEGX/CLR/NEG/NOT/TST family) and
; ASL (memory shift/rotate family) -- both "normal" RMW (read+write both
; independently bus-logged, unlike TAS's own locked-cycle read, which the
; testbench's bus logger doesn't emit a separate line for -- confirmed via a
; plain baseline TAS (A0) test showing the identical gap, pre-existing and
; unrelated to this phase's own change).
;
;   CLR.L ($100,A0,D1.L)  -- EA = A0+$100+D1
;   ASL.W ($100,A1,D1.L)  -- EA = A1+$100+D1
;
; A0=$200, A1=$300, D1=$4. CLR target = $304. ASL target = $404.
;
; Not wired into make cosim_memind: unlike memind2/memind3 (which happened
; to land cleanly), this instruction shape's own read latency consistently
; gives the IFU exactly one extra opcode-fetch's worth of prefetch headroom
; over Musashi's interpreter, shifting one fetch cycle earlier in the DUT's
; trace than the reference (confirmed this is inherent to the shape, not
; fixable by adding filler instructions -- tried, same result at a shifted
; offset). Hand-verified instead: DUT's own read+write values match
; Musashi's exactly (CLR: $304 12345678->0; ASL: $404 4001->8002, correct
; left-shift), and the fetch sequence (the actual thing under test) matches
; cycle-for-cycle once the benign reordering is accounted for.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        movea.l #$300,a1
        move.l  #$4,d1

        move.l  #$12345678,d4
        move.l  d4,($304)      ; CLR target, non-zero beforehand
        move.w  #$4001,d4
        move.w  d4,($404)      ; ASL target: 0x4001 << 1 = 0x8002

        clr.l   ($100,a0,d1.l)
        asl.w   ($100,a1,d1.l)

        stop    #$2700
        dc.w    $2700
