; tests/memind34.s — general ALU-with-EA-source genuine memory-indirect EA
; (plan.md, Phase 238's own deferred proposal): CMP.L's own genuine indirect
; EA -- exercises the "no register write at all, flags only" path (CMP sets
; no dec_writes_reg, unlike ADD/SUB/AND/OR, so memind_wr_en's own gating on
; !ex_is_mem_src must correctly suppress the raw-write path here too, or
; D2 would get corrupted with the raw read value even though CMP must
; never write it). Verified via CONTROL FLOW: since CMP produces no
; register result to compare directly, the CCR's own Z flag is proven via
; a conditional branch immediately after -- a genuinely wrong CCR would
; make the DUT take the OTHER branch, producing a completely different
; (and therefore mismatching) bus trace.
;
;   Pre-indexed, word bd, null od: ([$100,A0,D1.L])
;
; A0=$2000, D1=$8 -> inner=$2108, pointer at M32[$2108]=$3000 -> EA=$3000.
; M32[$3000]=5, D2=5 (equal) -> CMP sets Z=1 -> BEQ taken -> D5=$600D.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$8,d1

        move.l  #$3000,d4
        move.l  d4,($2108)      ; M32[a0+$100+d1] = $3000 (pointer)

        move.l  #5,d4
        move.l  d4,($3000)      ; M32[pointer] = 5

        move.l  #5,d2           ; equal to M32[$3000] -> Z=1 expected

        cmp.l   ([$100,a0,d1.l]),d2   ; pre-indexed, word bd, null od

        beq.b   match
        move.l  #$0000BAD1,d5
        bra.b   done
match:
        move.l  #$0000600D,d5
done:
        move.l  d5,($3100)      ; store the branch outcome for comparison
        move.l  d2,($3104)      ; and D2 itself, proving CMP never wrote it

        stop    #$2700
        dc.w    $2700
