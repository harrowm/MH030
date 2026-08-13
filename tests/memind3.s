; tests/memind3.s — memory-indirect EA: word bd AND word od both present
; (3 total extension words: descriptor + bd + od), exercising the q3_word
; data path added for this case. Also covers the null-bd + word-od case
; (2 ext words, pre-indexed) as a second instruction.
;
;   Post-indexed, word bd, word od: ([$10,A0],D1.L,$8) -> EA = M32[A0+$10] + D1 + $8
;   Pre-indexed,  null bd, word od: ([A0,D1.L],$8)     -> EA = M32[A0+D1] + $8
;
; A0 = $100, D1 = $100.
;   #1: pointer read from M32[$110] (=$200); EA = $200 + $100 + $8 = $308
;   #2: pointer read from M32[$200] (=$400); EA = $400 + $8 = $408

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$100,a0
        move.l  #$100,d1

        move.l  #$200,d4
        move.l  d4,($110)       ; M32[$110] = $200
        move.l  #$400,d4
        move.l  d4,($200)       ; M32[$200] = $400
        move.l  #$DEAD0003,d4
        move.l  d4,($308)       ; value at EA #1
        move.l  #$DEAD0004,d4
        move.l  d4,($408)       ; value at EA #2

        move.l  ([$10,a0],d1.l,$8),d2   ; post-indexed, word bd, word od
        move.l  ([a0,d1.l],$8),d3       ; pre-indexed, null bd, word od

        stop    #$2700
        dc.w    $2700
