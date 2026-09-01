; tests/memind26.s -- deferred-items closure plan Stage 8 (plan.md): the
; one sub-case Phase 143's own memind20.s left out of scope -- MOVE
; (d16,An),(bd,An,Xn) with a LONG (32-bit) destination base displacement.
; Phase 143 only ever exercised word bd for the (d16,An)-src arm (its own
; 2-word baseline puts the descriptor at q2, one word further out than the
; shared fi_is_full/fi_bd template assumes, needing its own q3_word-based
; extraction that was word-bd-only until this stage); this test is the
; first to exercise its own new long-bd path (q3_word/ext34_data[15:0]).
;
; Same "base register set above the 4KB cosim window, large-magnitude
; displacement forces full-format encoding" technique as memind13.s/16.s/
; 17.s/20.s's own second instruction.
;
;   MOVE.L ($8,A4),(-$10000,A5,D1.L)   -- (d16,An) src, LONG bd dst.
;                                          EA = A5-$10000+D1 = $404
;
; A4=$980, A5=$10400, D1=$4. Src value M32[$988]=$77778888.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$77778888,d4
        move.l  d4,($988)

        movea.l #$980,a4
        movea.l #$10400,a5
        move.l  #$4,d1

        move.l  ($8,a4),(-$10000,a5,d1.l)

        stop    #$2700
        dc.w    $2700
