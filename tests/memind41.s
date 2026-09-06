; tests/memind41.s -- docs/*.md review (plan.md §Phase 247 item #9): CAS/CAS2
; real bus-trace cosim test against Musashi. Building item #9's own CAS timing
; benchmark (tests/timing/a8_cas_success.s) found that this project's own RTL
; had CAS's Dc/Du register-field bit positions swapped, and CAS2's had both
; the extension-word ORDER and the within-word bit positions wrong, relative
; to real 68030 hardware -- confirmed via Musashi's own m68k_op_cas_32_ai/
; m68k_op_cas2_32 and independently via vasm's own assembled bytes. Never
; caught before: Harte has no CAS/CAS2 coverage at all (68000 corpus, both are
; 68020+), and (confirmed via grep) no cosim/bus-trace test against Musashi
; had ever exercised either instruction. This is that missing test, closing
; the actual root cause, not just re-testing the fix in isolation.
;
;   CAS.L D1,D2,(A0)  -- D1(Dc)=mem[$200]=$AAAABBBB -> match, D2(Du)=$12345678
;                        writes to mem[$200]; read back into D3 for bus-trace
;                        visibility.
;   CAS2.L D4:D6,D5:D7,(A0):(A1) -- D4(Dc1)=mem[$210], D6(Dc2)=mem[$220] both
;                        match -> D5(Du1)/D7(Du2) write to mem[$210]/mem[$220].

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$AAAABBBB,($200)
        move.l  #$AAAABBBB,d1        ; Dc
        move.l  #$12345678,d2        ; Du
        cas.l   d1,d2,(a0)
        move.l  ($200),d3            ; read back -- must be $12345678

        movea.l #$210,a0
        movea.l #$220,a1
        move.l  #$11112222,($210)
        move.l  #$33334444,($220)
        move.l  #$11112222,d4        ; Dc1
        move.l  #$55556666,d5        ; Du1
        move.l  #$33334444,d6        ; Dc2
        move.l  #$77778888,d7        ; Du2
        cas2.l  d4:d6,d5:d7,(a0):(a1)

        stop    #$2700
        dc.w    $2700
