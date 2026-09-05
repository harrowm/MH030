; tests/memind37.s — CHK2's own genuine memory-indirect EA (plan.md,
; deferred item from Phase 238, now implemented): same FSM merge as CMP2
; (tests/memind36.s), but exercises CHK2's own is_chk2 selector
; (cmp2_is_chk2_r, ext[11]=1) and, unlike memind36, the POST-indexed form
; (Xn added to the pointer, not the inner address) for family-wide
; addressing-mode diversity. Deliberately kept to the NON-trapping case
; (tested value within bounds) -- CHK2's own trap-taken exception frame
; semantics are Harte/cosim-covered exhaustively elsewhere; this test's own
; job is proving the genuine-indirect EA resolution and FSM merge, not
; re-verifying CHK2's own trap dispatch from scratch.
;
;   Post-indexed, word bd, null od: ([$100,A0],D1.L)
;
; A0=$2000, bd=$100 -> inner=$2100, pointer at M32[$2100]=$3000 -> lower
; bound EA = pointer+D1 = $3000+$8=$3008, upper bound EA=$300C (size=L).
; Lower=10, upper=20, D3=15 (within [10,20]) -> no trap -> falls through to
; the post-CHK2 MOVE, proving the whole sequence completed cleanly.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$8,d1

        move.l  #$3000,d4
        move.l  d4,($2100)      ; M32[a0+$100] = $3000 (pointer, no d1 here)

        move.l  #10,d4
        move.l  d4,($3008)      ; lower bound at pointer+d1

        move.l  #20,d4
        move.l  d4,($300c)      ; upper bound

        move.l  #15,d3          ; tested value, within [10,20] -- must not trap

        chk2.l  ([$100,a0],d1.l),d3   ; post-indexed, word bd, null od

        move.l  #$0000600D,d5   ; only reached if CHK2 did not trap
        move.l  d5,($3100)

        stop    #$2700
        dc.w    $2700
