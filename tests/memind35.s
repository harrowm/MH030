; tests/memind35.s — general ALU-with-EA-source genuine memory-indirect EA
; (plan.md, Phase 238's own deferred proposal): ADDA.L's own genuine
; indirect EA -- exercises the An-destination path (dec_dyn_bit_is_an=1,
; the swap brings in An not Dn) and dyn_bit_get_Dn's own is_an-qualified
; rd_a_sel/rd_b_sel mux arms under the new memind timing.
;
;   Pre-indexed, word bd, null od: ([$100,A0,D1.L])
;
; A0=$2000, D1=$8 -> inner=$2108, pointer at M32[$2108]=$3000 -> EA=$3000.
; M32[$3000]=$100, A2=$2000 (accumulator) -> ADDA.L result = A2=$2100.
; Stored to $3100 for comparison.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$8,d1

        move.l  #$3000,d4
        move.l  d4,($2108)      ; M32[a0+$100+d1] = $3000 (pointer)

        move.l  #$100,d4
        move.l  d4,($3000)      ; M32[pointer] = $100

        movea.l #$2000,a2       ; accumulator

        adda.l  ([$100,a0,d1.l]),a2   ; pre-indexed, word bd, null od

        move.l  a2,($3100)      ; store the combined result for comparison

        stop    #$2700
        dc.w    $2700
