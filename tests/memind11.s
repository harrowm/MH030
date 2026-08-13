; tests/memind11.s — Stage 4 (plan.md Phase 119): MOVEM's own full-format
; mode=110 EA with a non-null word base displacement. Unlike every other
; family in this rollout, MOVEM's baseline already needs 2 extension words
; (register mask + EA descriptor) before any full-format concept applies, so
; a non-null bd needs a genuine THIRD extension word (q3_word) rather than
; reusing the [31:16] slot a single-EA family's own bd would occupy (that
; slot is the mask here) -- see is_movem_idx_full/movem_ext_count in
; m68030_seq.sv and the matching eu_seq.sv decode-block comment.
;
;   MOVEM.L D0-D1,($100,A0,D2.L)   -- store; EA = A0+$100+D2 = $304
;   MOVEM.L ($100,A0,D2.L),D3-D4   -- load;  same EA, reads back what was
;                                      just stored (D3=D0's value, D4=D1's)
;
; A0=$200, D2=$4.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$4,d2

        move.l  #$AAAA0000,d0
        move.l  #$BBBB1111,d1

        movem.l d0-d1,($100,a0,d2.l)   ; M32[$304]=D0, M32[$308]=D1

        movem.l ($100,a0,d2.l),d3-d4   ; D3=M32[$304], D4=M32[$308]

        stop    #$2700
        dc.w    $2700
