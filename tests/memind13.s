; tests/memind13.s — Phase 121: long (32-bit) base displacement for the
; full-format mode=110 EA, non-indirect case. fi_bd previously only ever
; returned a non-zero value for word-size bd (fi_bdsz==10); long bd
; (fi_bdsz==11) silently returned 0. Since every family already converted
; in Stages 1-3 reads fi_bd unconditionally via the
; `dec_ea_offset = fi_is_full ? fi_bd : <brief>` template, fixing fi_bd's
; own definition (to read the low half from q3_word, the same word MOVEM's
; own bd and abs.L reconstruction already reuse) fixes every one of those
; sites simultaneously -- this test exercises two of them (ADD memory-
; source, OR memory-dest RMW) as representative proof, mirroring Stage 2's
; own memind7.s pattern (CLR.L was tried first for the memory-dest half but
; hits an unrelated, pre-existing quirk: this testbench's CLR-to-indexed-EA
; performs an extra bus READ before the write that Musashi doesn't, present
; even for plain brief-form CLR.L -- confirmed via a standalone throwaway
; repro, not kept -- so switched to OR.L which memind7.s already proved
; compares cleanly).
;
; Base registers are set well above the 4KB memory-model window this
; project's cosim tests share (see CLAUDE.md); a large *negative* bd brings
; the actual computed EA back down into range, forcing full-format long-bd
; encoding (|$10000| is outside vasm's +-32768 brief-displacement range)
; while every byte the bus actually touches stays within bounds.
;
;   ADD.L (-$10000,A0,D1.L),D2  -- memory source: EA = A0-$10000+D1
;   OR.L  D3,(-$10000,A1,D1.L)  -- memory dest:   EA = A1-$10000+D1
;
; A0=$10200, A1=$10100, D1=$4. ADD target = $204. OR target = $104.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$10200,a0
        movea.l #$10100,a1
        move.l  #$4,d1

        move.l  #$00000005,d4
        move.l  d4,($204)      ; ADD target

        move.l  #$00000003,d2  ; ADD addend
        add.l   (-$10000,a0,d1.l),d2    ; D2 = 3 + M32[$204](5) = 8

        move.l  #$0000000F,d4
        move.l  d4,($104)      ; OR target

        move.l  #$000000F0,d3
        or.l    d3,(-$10000,a1,d1.l)    ; M32[$104] = $F0 | $0F = $FF

        stop    #$2700
        dc.w    $2700
