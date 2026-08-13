; tests/memind.s — memory-indirect EA (([bd,An],Xn,od) / ([bd,An,Xn],od))
; investigation, per plan.md Phase 107's decode-bit hypothesis.
;
; Minimal case first: null base displacement, null outer displacement, so
; only one extension word is needed (isolates the pre/post-indexed decode
; bit from the separate multi-extension-word question).
;
;   Post-indexed: ([A0],D1.L)   -> EA = M32[A0] + D1
;   Pre-indexed:  ([A0,D1.L])   -> EA = M32[A0 + D1]
;
; A0 = $100, D1 = $100.
;   Post: pointer read from M32[$100] (=$200); EA = $200 + $100 = $300
;   Pre:  pointer read from M32[$100+$100=$200] (=$300); EA = $300 + 0 = $300
; Different pointer-read addresses ($100 vs $200) even though both land on
; the same final EA ($300) -- exactly what a bus-trace cosim diff needs to
; catch a pre/post mixup that a register-only check would miss.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$100,a0
        move.l  #$100,d1

        move.l  #$200,d4
        move.l  d4,($100)       ; M32[$100] = $200  (post-indexed pointer)
        move.l  #$300,d4
        move.l  d4,($200)       ; M32[$200] = $300  (pre-indexed pointer)
        move.l  #$DEAD0001,d4
        move.l  d4,($300)       ; value at the common final EA

        move.l  ([a0],d1.l),d2         ; post-indexed, null bd, null od
        move.l  ([a0,d1.l]),d3         ; pre-indexed,  null bd, null od

        stop    #$2700
        dc.w    $2700
