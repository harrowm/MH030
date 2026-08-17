; tests/memind21.s — Phase 146 (plan.md): genuine memory-indirect EA with
; BOTH a long (32-bit) base displacement AND a long outer displacement
; together -- the one combination flatly impossible before Phase 145/146
; added genuine q5 (5th extension word) plumbing: descriptor+bd_hi+bd_lo+
; od_hi+od_lo = 5 extension words = 6 total (opcode+5), one word beyond
; what the IFU could ever drain before this phase. fi_od's own formula
; previously returned 0 unconditionally for fi_iis[1:0]==2'b11 (long od);
; now it correctly reads od_hi/od_lo from q4/q5 when bd is also long.
;
; Same "base register set above the 4KB cosim window, large-magnitude
; displacement forces full-format encoding" technique as
; memind13.s/16.s/17.s, applied to BOTH bd and od simultaneously.
;
;   Post-indexed, long bd, long od:
;     ([-$10000,A0],D1.L,-$20000) -> EA = M32[A0-$10000] + D1 - $20000
;
; A0=$10200, D1=$4.
;   pointer read from M32[$200] (=$20200); EA = $20200 + $4 - $20000 = $204

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$10200,a0
        move.l  #$4,d1

        move.l  #$20200,d4
        move.l  d4,($200)        ; M32[$200] = $20200 (pointer)
        move.l  #$DEAD0021,d4
        move.l  d4,($204)        ; value at final EA

        move.l  ([-$10000,a0],d1.l,-$20000),d2   ; post-indexed, long bd, long od

        stop    #$2700
        dc.w    $2700
