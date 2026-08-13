; tests/memind2.s — memory-indirect EA with a non-null (word) base
; displacement, to check whether ext_count/decode correctly fetches the
; extra extension word needed once bd is present (a second, independent
; question from the pre/post-indexed bit fix in tests/memind.s).
;
;   Post-indexed: ([$10,A0],D1.L)   -> EA = M32[A0+$10] + D1
;
; A0 = $100, D1 = $100.
;   pointer read from M32[$110] (=$200); EA = $200 + $100 = $300

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$100,a0
        move.l  #$100,d1

        move.l  #$200,d4
        move.l  d4,($110)       ; M32[$110] = $200  (post-indexed pointer)
        move.l  #$DEAD0002,d4
        move.l  d4,($300)       ; value at the final EA

        move.l  ([$10,a0],d1.l),d2      ; post-indexed, word bd, null od

        stop    #$2700
        dc.w    $2700
