; tests/memind33.s — general ALU-with-EA-source genuine memory-indirect EA
; (plan.md, Phase 238's own deferred proposal): DIVU.L's own genuine
; indirect EA -- specifically exercises dec_memind_rd_siz (DIVU's own
; dec_siz reflects its 32-bit RESULT, but the memory OPERAND read must
; stay 16-bit regardless of addressing mode; memind_siz_r historically
; just captured dec_siz directly, which would have wrongly read a
; longword here). The bus trace's own siz=10 (word) on the resolved-EA
; read is the direct proof.
;
;   Pre-indexed, word bd, null od: ([$100,A0,D1.L])
;
; A0=$2000, D1=$8 -> inner=$2108, pointer at M32[$2108]=$3000 -> EA=$3000.
; M16[$3000]=4 (word-sized divisor), D3=20 (dividend) -> DIVU quotient=5,
; remainder=0 -> D3=$00000005. Stored to $3100 for comparison.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$8,d1

        move.l  #$3000,d4
        move.l  d4,($2108)      ; M32[a0+$100+d1] = $3000 (pointer)

        move.l  #$00040000,($3000)  ; M16[pointer] = 4 (top half of a longword
                                     ; write, sidesteps an unrelated word-write
                                     ; bus-log quirk this test's own first draft
                                     ; hit with move.w -- see plan.md's own
                                     ; writeup for this stage)

        move.l  #20,d3          ; dividend

        divu.w  ([$100,a0,d1.l]),d3   ; pre-indexed, word bd, null od

        move.l  d3,($3100)      ; store the combined result for comparison

        stop    #$2700
        dc.w    $2700
