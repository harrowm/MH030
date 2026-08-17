; tests/memind22.s — Phase 147 (plan.md): MOVE #imm,(bd,An,Xn) and
; MOVE (xxx).L,(bd,An,Xn) full-format indexed dst with a LONG base
; displacement -- the last two of the three sites Phase 145's genuine q5
; plumbing unlocked (Phase 146 did the third, genuine memory-indirect).
; Both arms' own 3-word baseline (imm32/abs.L + descriptor, at q1/q2/q3)
; previously only supported word bd (value at q4); long bd's own low half
; is one word further out still, at q5.
;
;   MOVE.L #$13572468,(-$10000,A0,D1.L)   -- imm-src, long bd (forced via
;                                             the usual out-of-brief-range
;                                             technique). EA = A0-$10000+D1
;                                                          = $204
;   MOVE.L $10900,(-$10000,A2,D1.L)       -- abs.L-src, long bd. Source
;                                             address deliberately > $FFFF
;                                             so vasm can't fold it to
;                                             abs.W (an earlier draft used
;                                             ($800), which fit in 16 bits
;                                             and silently assembled as
;                                             abs.W -- a DIFFERENT, older
;                                             decode arm (Phase 118) with
;                                             no long-bd support at all,
;                                             not this phase's new code).
;                                             EA = A2-$10000+D1 = $404
;
; A0=$10200, A2=$10400, D1=$4. Source value for the abs.L-src case at
; M32[$10900] (aliases M32[$900] in this testbench's 16KB wraparound
; memory model) = $2468ACE0.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$10200,a0
        movea.l #$10400,a2
        move.l  #$4,d1

        move.l  #$2468ACE0,d4
        move.l  d4,$10900

        move.l  #$13572468,(-$10000,a0,d1.l)
        move.l  $10900,(-$10000,a2,d1.l)

        stop    #$2700
        dc.w    $2700
