; tests/memind18.s — Phase 141 (plan.md): MOVE #imm, (bd,An,Xn) full-format
; indexed dst -- the imm-src arm of MOVE mem-to-mem's own indexed-dst
; family, deferred out of scope in Phase 122 ("Sub-scope A") since it
; needs a genuine 4th extension word (q4) the project hadn't wired up yet
; at the time (added Phase 121/138/140's own q4 consumers).
;
; MOVE.B/W's own baseline (imm16 + descriptor, 2 ext words) supports BOTH
; word and long bd, same shape as abs.W-src/(d16,PC)-src (Phase 122).
; MOVE.L's own baseline (imm32 + descriptor, 3 ext words) only has room for
; a WORD bd (via the last available word, q4) -- long bd would need a
; genuine q5, out of scope (Stage 8).
;
; Not wired into `make cosim_memind`: this arm's own pre-existing
; dec_is_mem_rmw "2-port trick" (unchanged by this phase -- only
; dec_ea_offset was touched) performs a real bus READ before the write
; that Musashi doesn't, same quirk already documented for memind9.s
; (MOVE SR,(ea)) and memind15.s (MOVE Dn,(d8,An,Xn) register-src). All
; three EA computations and every written value were hand-verified to
; match Musashi exactly (data/addresses identical: $304<-$1234,
; $204<-$5678, $504<-$9ABCDEF0) once the phantom reads are accounted for.
;
;   MOVE.W #$1234,($100,A0,D1.L)      -- word bd.  EA = A0+$100+D1  = $304
;   MOVE.W #$5678,(-$10000,A2,D1.L)   -- long bd (forced via the same
;                                         out-of-brief-range technique as
;                                         tests/memind13.s/16.s/17.s).
;                                         EA = A2-$10000+D1 = $204
;   MOVE.L #$9ABCDEF0,($100,A3,D1.L)  -- word bd, MOVE.L (its only
;                                         achievable full-format case).
;                                         EA = A3+$100+D1 = $504
;
; A0=$200, A2=$10200, A3=$400, D1=$4.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        movea.l #$10200,a2
        movea.l #$400,a3
        move.l  #$4,d1

        move.w  #$1234,($100,a0,d1.l)
        move.w  #$5678,(-$10000,a2,d1.l)
        move.l  #$9ABCDEF0,($100,a3,d1.l)

        stop    #$2700
        dc.w    $2700
