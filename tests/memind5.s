; tests/memind5.s — Stage 1 (plan.md Phase 116): full-format mode=110 EA with
; a non-null word base displacement for TAS and NBCD (the "unary memory
; operand" family, An+Xn only, no third register). Confirms the same
; ext_count/fi_bd fix Phase 115 made for MOVE also works for these via the
; generalized is_memind_full mechanism.
;
;   TAS.B ($100,A0,D1.L)  -- EA = A0+$100+D1  (full format, no indirection)
;   NBCD  ($100,A1,D1.L)  -- EA = A1+$100+D1
;
; A0=$200, A1=$300, D1=$4. TAS target = $200+$100+$4 = $304.
; NBCD target = $300+$100+$4 = $404.
;
; Not wired into make cosim_memind: TAS is a genuinely bus-locked RMW cycle
; (AS stays asserted across read+write, no release between phases -- see
; CLAUDE.md's own BIU spec) and this testbench's bus logger doesn't emit a
; separate BUS R line for the read phase of a locked cycle -- confirmed via
; a plain baseline `TAS (A0)` test showing the identical gap, pre-existing
; and unrelated to this phase's own change, so buscmp.py can never cleanly
; match a TAS trace regardless of correctness. Hand-verified instead: DUT's
; own final write values (TAS: $304=$D5 = $55|$80; NBCD: $404=$88, correct
; BCD-negate of $12) match Musashi's exactly when the logs are inspected
; directly, and both instructions' own opcode+extension-word fetch sequence
; (the actual thing this test exists to verify -- that the bd word gets
; fetched at all) matches Musashi's cycle-for-cycle.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        movea.l #$300,a1
        move.l  #$4,d1

        move.b  #$55,d4
        move.b  d4,($304)      ; TAS target byte, bit7 clear beforehand
        move.b  #$12,d4
        move.b  d4,($404)      ; NBCD target byte (BCD digit)

        tas.b   ($100,a0,d1.l)
        nbcd    ($100,a1,d1.l)

        stop    #$2700
        dc.w    $2700
