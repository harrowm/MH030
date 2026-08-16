; tests/memind19.s — Phase 142 (plan.md): MOVE (xxx).L,(bd,An,Xn) full-format
; indexed dst -- the abs.L-src arm of MOVE mem-to-mem's own indexed-dst
; family, deferred out of scope in Phase 122 ("Sub-scope A"). Same
; word-layout shape as MOVE.L imm-src (Phase 141): abs.L src's own 2-word
; baseline (the address itself) pushes the dst descriptor to q3_word, one
; word further out than abs.W-src/(d16,PC)-src's own q2 position -- only
; WORD bd is achievable (value at q4/ext34_data[15:0]); long bd would need
; a genuine q5, out of scope (Stage 8). Unlike the imm-src arm, abs.L-src
; uses the real move_mm FSM (a genuine src-then-dst read/write), not the
; RMW "2-port trick", so it has no phantom-read quirk -- but it does hit
; the *other*, unrelated benign quirk already documented for memind.s/
; memind4.s/memind6.s/memind9.s/memind14.s: the DUT's real pipelined IFU
; prefetch fetches the next instruction word one slot earlier than
; Musashi's own interpretive re-fetch quirk expects. Confirmed by direct
; bus-log inspection: the actual write (`BUS W 00000304 deadbeef`) matches
; Musashi byte-for-byte; only the fetch-vs-read cycle order at the
; boundary differs. Not wired into `make cosim_memind`, same convention
; as those five predecessors.
;
;   MOVE.L ($600),($100,A0,D1.L)  -- word bd.  EA = A0+$100+D1 = $304
;
; A0=$200, D1=$4. Source value at M32[$600] = $DEADBEEF.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$DEADBEEF,d4
        move.l  d4,($600)

        movea.l #$200,a0
        move.l  #$4,d1

        move.l  ($600),($100,a0,d1.l)

        stop    #$2700
        dc.w    $2700
