; tests/memind4.s — reproduces tb/ea_modes_tb.sv's "mem-ind P3" case exactly
; (opcode 0x2430, ext 0x1951: IS=1 [index suppressed], I/IS=001 [pre-indexed,
; null od]) via Musashi cosim, to settle whether P3's own comment/expected
; values ("post-indexed (IS=1)", outer = MEM[A0]+D1) are correct 68020
; semantics or share the same IS-vs-pre/post conflation the RTL had.
;
; A0=$100, D1=$40. M32[$100]=$500 (pointer). If the test's own assumption
; is right, outer EA = $500+$40 = $540. If IS=1 genuinely means "no index
; register anywhere in this EA" (independent of pre/post), outer EA should
; just be the pointer itself, $500 -- no Xn addition at all.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$100,a0
        move.l  #$40,d1
        move.l  #$500,d4
        move.l  d4,($100)          ; M32[$100] = $500 (pointer)
        move.l  #$AAAA0001,d4
        move.l  d4,($500)          ; value at MEM[pointer] (IS=1 hypothesis)
        move.l  #$AAAA0002,d4
        move.l  d4,($540)          ; value at MEM[pointer+D1] (old test's hypothesis)

        dc.w    $2430, $1951        ; exact P3 encoding: MOVE.L ([A0]),D2 with IS=1

        stop    #$2700
        dc.w    $2700
