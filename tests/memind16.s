; tests/memind16.s — Phase 138 (plan.md): MOVEM's own full-format mode=110
; EA with a non-null LONG base displacement. Phase 119 (memind11.s) added
; word-size bd support; fi_bdsz==2'b11 (long) fell through to the wrong
; brief-8-bit fallback. movem_ext_count (m68030_seq.sv) already sized this
; case correctly (mask+descriptor+bd_hi+bd_lo = 4 ext words) -- only the
; eu_seq.sv VALUE extraction was missing, fixed this phase by extending the
; same ternary memind11.s's own word-bd branch uses, reusing q3_word (bd
; high half) + ext34_data[15:0]=q4 (bd low half, the same already-wired 4th
; extension word MOVE.L #imm32,abs.L has used since before this rollout).
;
; Same "base register set above the 4KB cosim window, large negative bd
; brings the EA back in range" technique as memind13.s -- |$10000| is
; outside vasm's +-32768 brief-displacement range, forcing full-format
; long-bd encoding while every touched byte stays in bounds.
;
;   MOVEM.L D0-D1,(-$10000,A0,D2.L)   -- store; EA = A0-$10000+D2 = $304
;   MOVEM.L (-$10000,A0,D2.L),D3-D4   -- load;  same EA, reads back what was
;                                         just stored (D3=D0's value, D4=D1's)
;
; A0=$10300, D2=$4.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$10300,a0
        move.l  #$4,d2

        move.l  #$CCCC2222,d0
        move.l  #$DDDD3333,d1

        movem.l d0-d1,(-$10000,a0,d2.l)   ; M32[$304]=D0, M32[$308]=D1

        movem.l (-$10000,a0,d2.l),d3-d4   ; D3=M32[$304], D4=M32[$308]

        stop    #$2700
        dc.w    $2700
