; tests/memind20.s — Phase 143 (plan.md): MOVE (An)/(An)+/-(An)/(d16,An),
; (bd,An,Xn) full-format indexed dst -- the plain-memory-src arm of MOVE
; mem-to-mem's own indexed-dst family, the last (and hardest) of the three
; deferred out of scope in Phase 122 ("Sub-scope A").
;
; Two genuinely different code paths, both exercised here: (An)/(An)+/
; -(An)-src has a 1-word baseline (dst descriptor alone, at q1) -- the
; exact shape the shared fi_is_full/fi_bd template already handles, so
; reused directly (both word AND long bd achievable, same as every other
; single-EA-word family). (d16,An)-src has a 2-word baseline (its own d16
; word comes first, pushing the dst descriptor to q2) -- needs its own
; q3_word-based extraction, same "one word further out" shape as MOVEM's
; own bespoke extraction (Phase 138) and MOVE.B/W's own imm-src arm (Phase
; 141); only WORD bd is achievable there.
;
; A genuine, real bug was found and fixed building this test: an early
; attempt hung the simulator outright. Root cause -- this arm's own 1-word
; baseline (unlike every other MOVE mem-to-mem arm converted in this
; rollout, whose baseline was already >=2 words) sits exactly on the
; ext_count 1-vs-2+ threshold where m68030_seq.sv's own eu_ext_data packing
; convention flips which half of ext_data holds q1 -- a real bd pushes
; ext_count to 2+, moving the descriptor from ext_data[15:0] to
; ext_data[31:16] and corrupting every fi_is_full/fi_bd-based read (and,
; unnoticed until traced, dst_reg/xn_wl/xn_scale too). The existing
; is_memind_full swap solves exactly this problem already, but is keyed on
; f_mode==110 (mode110_ea_src) -- a field this arm's own f_mode (010/011/
; 100, the SOURCE's own mode) never matches, since the descriptor here
; lives in the separate f_move_dst_mode_s field instead. Fixed by folding
; is_move_mm_plainsrc_idxdst_full into the same swap condition -- zero new
; eu_seq.sv extraction code needed once the swap was correct.
;
; Compares cleanly against Musashi apart from the same benign prefetch-
; interleave reordering already documented for memind9.s/memind14.s/
; memind19.s (the DUT's real pipelined IFU prefetch fetches one word
; earlier than Musashi's own interpretive re-fetch quirk expects) --
; confirmed by isolating the BUS W lines directly: all three writes
; ($304<-$11112222, $204<-$33334444, $504<-$55556666) match byte-for-byte.
; Not wired into `make cosim_memind`, same convention as those three.
;
;   MOVE.L (A0)+,($100,A1,D1.L)     -- (An)+ src, word bd.
;                                       EA = A1+$100+D1 = $304
;   MOVE.L (A2),(-$10000,A3,D1.L)   -- (An) src, long bd (forced via the
;                                       usual out-of-brief-range technique).
;                                       EA = A3-$10000+D1 = $204
;   MOVE.L ($8,A4),($100,A5,D1.L)   -- (d16,An) src, word bd.
;                                       EA = A5+$100+D1 = $504
;
; A0=$800, A1=$200, A2=$900, A3=$10200, A4=$980, A5=$400, D1=$4.
; Src values: M32[$800]=$11112222, M32[$900]=$33334444, M32[$988]=$55556666.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11112222,d4
        move.l  d4,($800)
        move.l  #$33334444,d4
        move.l  d4,($900)
        move.l  #$55556666,d4
        move.l  d4,($988)

        movea.l #$800,a0
        movea.l #$200,a1
        movea.l #$900,a2
        movea.l #$10200,a3
        movea.l #$980,a4
        movea.l #$400,a5
        move.l  #$4,d1

        move.l  (a0)+,($100,a1,d1.l)
        move.l  (a2),(-$10000,a3,d1.l)
        move.l  ($8,a4),($100,a5,d1.l)

        stop    #$2700
        dc.w    $2700
