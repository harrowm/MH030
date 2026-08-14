; tests/memind12.s — Phase 120: CMP2/CHK2's own indexed EA, previously
; entirely unimplemented (no f_mode==110 case arm existed at all in
; eu_seq.sv, unlike every other family in this rollout which was merely
; brief-limited). Exercises both brief and full-format bd, reusing the
; dyn_bit_get_Dn deferred-register trick already proven for CHK's own
; indexed form (Phase 84/86) to swap Rn into rd_b at the read-ack cycle.
;
;   CMP2.L ($8,A0,D1.L),D2    -- brief; EA = A0+$8+D1 = $20C
;   CHK2.L ($100,A0,D1.L),D3  -- full (word bd); EA = A0+$100+D1 = $304
;
; Both EAs hold {lower=$00000005, upper=$00000015}. D2=D3=$10 (in bounds
; for both, so CHK2 doesn't trap -- keeps the test a plain read/compare,
; no exception-frame handling needed).
;
; A0=$200, D1=$4.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$4,d1

        move.l  #$00000005,d4
        move.l  d4,($20c)      ; CMP2 lower bound
        move.l  #$00000015,d4
        move.l  d4,($210)      ; CMP2 upper bound

        move.l  #$00000005,d4
        move.l  d4,($304)      ; CHK2 lower bound
        move.l  #$00000015,d4
        move.l  d4,($308)      ; CHK2 upper bound

        move.l  #$10,d2
        cmp2.l  ($8,a0,d1.l),d2        ; brief; in bounds

        move.l  #$10,d3
        chk2.l  ($100,a0,d1.l),d3      ; full; in bounds, no trap

        stop    #$2700
        dc.w    $2700
