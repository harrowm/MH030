; tests/memind27.s — deferred-items closure follow-up (plan.md, ext_count
; de-duplication Stage 1): MOVE (bd,An_src,Xn_src),<memory dst> in
; full-format, both the sub-cases found and fixed via the exhaustive
; opcode-sweep overlap-detection testbench (tb/ext_count_overlap_tb.sv).
;
; A real, previously-undiscovered bug: m68030_seq.sv's ext_count chain
; classified this whole family via is_memind_full (mode110_ea_src's own
; generic "indexed source, full format" match), which only counts the
; source's own extension word(s) -- silently ignoring that, for a MOVE
; mem-to-mem instruction specifically, the destination is ALSO memory and
; needs its own extension word too (0 more for dst=(An)/(An)+/-(An), 1
; more for dst=(d16,An)). eu_seq.sv's own dedicated decode for this shape
; (the f_mode==110 arm inside its "dst = memory (An)/.../.../(d16,An)"
; block) already correctly accounted for the destination in its OWN
; ext_count expectations (see its own header comment), but had never been
; exercised with a genuinely FULL-format source before -- it only ever read
; a fixed 8-bit brief displacement byte, silently misreading a full-format
; extension word's own unrelated bits as if they were one. Fixed with a new
; is_move_idx_src_memdst_full classifier (correctly positioned ahead of
; is_memind_full in the chain) plus a matching eu_seq.sv fix reading
; fi_is_full/fi_bd via the standard template for dst != (d16,An), and a
; direct high-half read (with the is_memind_full swap deliberately excluded
; for just this one sub-case -- see m68030_seq.sv's own eu_ext_data
; comment) for dst == (d16,An) specifically, scoped to null base
; displacement there (word/long bd would need a genuine 3rd/4th extension
; word this arm doesn't have -- documented, not attempted).
;
;   MOVE.L ($100,A0,D1.L),(A2)       -- dst=(An), full-format WORD bd.
;                                        EA_src = A0+$100+D1 = $304
;   MOVE.L (An_src,D1.L)[null bd],   -- dst=(d16,An), full-format, genuinely
;          ($8,A3)                     NULL bd (bdsz=01, no bd word at all)
;                                        -- exercises the dst==(d16,An)
;                                        fix's own claimed-correct scope
;                                        exactly. vasm has no mnemonic
;                                        syntax to request this specific
;                                        encoding without also requesting
;                                        genuine memory-indirect (a
;                                        different, harder, unrelated
;                                        addressing mode) -- confirmed via
;                                        a standalone assembler probe (both
;                                        plain `(a0,d1.l)` and `.w`/`.l`
;                                        suffixes either give brief format
;                                        or force a real bd WORD to exist,
;                                        never bdsz=01 alone) -- so this one
;                                        instruction is hand-encoded via
;                                        `dc.w` instead (opcode 0x2770 +
;                                        ext word 0x1910 -- 0x1920's own
;                                        bits[5:4] changed from 10(word) to
;                                        01(null), everything else identical
;                                        to the first instruction's own
;                                        real, vasm-assembled ext word,
;                                        confirmed byte-for-byte against
;                                        that instruction's own assembled
;                                        output before being hand-adjusted)
;                                        + the dst's own d16 word (0x0008).
;                                        Musashi decodes these raw bytes
;                                        completely independently of vasm,
;                                        so a correct comparison here is a
;                                        genuine, independent cross-check of
;                                        the hand-derivation, not just an
;                                        assembler-trusting one.
;                                        EA_src = A0+D1 = $204 (no bd)
;
; A0=$200, D1=$4, A2=$500, A3=$600.
; Src values: M32[$304]=$AABBCCDD, M32[$204]=$11223344.
; Expected: M32[$500]=$AABBCCDD (dst=(A2)), M32[$608]=$11223344 (dst=($8,A3)).

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$AABBCCDD,d4
        move.l  d4,($304)
        move.l  #$11223344,d4
        move.l  d4,($204)

        movea.l #$200,a0
        movea.l #$500,a2
        movea.l #$600,a3
        move.l  #$4,d1

        move.l  ($100,a0,d1.l),(a2)
        dc.w    $2770, $1910, $0008     ; MOVE.L (A0,D1.L)[full,null bd],($8,A3)

        stop    #$2700
        dc.w    $2700
