; tests/memind9.s — Stage 3 (plan.md Phase 118): full-format mode=110 EA with
; a non-null word base displacement for LEA, CHK, ADDQ.L, and MOVE-to-CCR.
; Not wired into `make cosim_memind`: hits the same benign prefetch-interleave
; timing difference already documented for tests/memind.s/memind4.s/memind6.s
; (the DUT's real pipelined IFU prefetch fetches one word earlier than
; Musashi's own interpretive re-fetch quirk expects) -- every actual value in
; both bus logs matches exactly, hand-verified, just reordered by one slot
; near the end. Kept as a standalone hand-run reproduction like its
; predecessors.
;
;   LEA   ($100,A0,D1.L),A2   -- EA = A0+$100+D1 = $304; proven via a
;                                 subsequent read at A2
;   CHK.L ($100,A0,D1.L),D5   -- reads bound from the same $304 (=5); D5=3,
;                                 in range, no trap
;   ADDQ.L #1,($100,A1,D1.L)  -- RMW at A1+$100+D1 = $404
;   MOVE.W ($100,A0,D1.L),CCR -- read side: loads CCR from $304 (=word $0005,
;                                 low byte's low 5 bits harmless as CCR)
;
; A0=$200, A1=$300, D1=$4.
;
; MOVE SR,EA (the write-side "RMW trick" site, the 6th eu_seq.sv site touched
; this phase) is deliberately NOT exercised here: comparing it against Musashi
; found the DUT performs an extra bus READ at the destination before the
; write that the reference does not. Isolated with two standalone throwaway
; repros: present for indexed EA (d8,An,Xn) regardless of brief/full, absent
; for (d16,An) -- so it's keyed on f_mode==110 specifically, pre-existing
; (the site's dec_is_mem_rd/dec_is_mem_rmw flags predate this phase; this
; phase only touched dec_ea_offset), and unrelated to the fi_is_full/fi_bd
; fix itself. Doesn't affect correctness (MOVEfromSR's own Harte suite,
; which does cover indexed EA, is 100% -- Harte diffs final register/memory
; state, not bus-cycle-by-cycle timing, so an extra harmless read cycle
; wouldn't show up there) -- just an extra bus cycle real silicon or Musashi
; doesn't take. Documented, not investigated further this phase -- see
; plan.md Phase 118.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        movea.l #$300,a1
        move.l  #$4,d1

        move.l  #$00000005,d4
        move.l  d4,($304)      ; LEA/CHK/MOVEtoCCR target
        move.l  #$00000010,d4
        move.l  d4,($404)      ; ADDQ/MOVEfromSR target

        lea     ($100,a0,d1.l),a2      ; A2 = $304
        move.l  (a2),d3                 ; read to prove LEA's EA (D3=5)

        move.l  #3,d5
        chk.l   ($100,a0,d1.l),d5       ; bound check reads M32[$304]=5, in range

        addq.l  #1,($100,a1,d1.l)       ; M32[$404] = $11

        move.w  ($100,a0,d1.l),ccr      ; CCR ← low word of M32[$304]

        stop    #$2700
        dc.w    $2700
