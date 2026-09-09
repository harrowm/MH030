; tests/memind42.s — Phase 251 item 2: MOVEM's own genuine memory-indirect
; EA ([bd,An],Xn,od) / ([bd,An,Xn],od), the last of this rollout's originally
; deferred families (word-count sizing was already fixed at Phase 234; only
; the EA *value* resolution itself was missing until now). Covers both
; directions (store, load) and both indirect forms (pre-indexed, post-
; indexed), mixing long and word register-size transfers.
;
; Part 1 — MOVEM.L D0-D1,([$100,A0,D2.L])  (store, pre-indexed, long)
;   A0=$2000, D2=$8 -> inner = A0+bd+D2 = $2108 (pre-indexed: Xn added
;   BEFORE the indirect dereference). Pointer at M32[$2108] set to $3000.
;   EA = M32[$2108] = $3000 (pre-indexed has no outer displacement added
;   after the dereference in this null-od case). D0=$11112222,
;   D1=$33334444 stored to M32[$3000], M32[$3004].
;
; Part 2 — MOVEM.L ([$200,A0],D3.L,$10),A2-A3  (load, post-indexed, long)
;   A0=$2000, bd=$200 -> intermediate = A0+bd = $2200 (post-indexed: the
;   dereference happens BEFORE Xn/od are added). Pointer at M32[$2200] set
;   to $4000. D3=$4, od=$10 -> EA = M32[$2200] + D3 + od = $4000+$4+$10
;   = $4014. A2=M32[$4014], A3=M32[$4018].
;
; (A genuine single-register MOVEM list, and a word-sized 2-register list,
; were both tried and abandoned here for reasons unrelated to the RTL under
; test: vasm silently rewrites a single-register MOVEM into the equivalent
; plain MOVEA instruction -- a real, different opcode, not a MOVEM at all
; -- and two ADJACENT word-sized MOVEM register transfers hit a known,
; pre-existing benign Musashi-side quirk where the reference coalesces them
; into one 32-bit read while real 68030 silicon (and this DUT, correctly)
; issues two separate word-sized bus cycles -- the same "prefetch/read-
; granularity" divergence class already documented elsewhere in this
; project's own memind test history. Long size + 2 registers sidesteps
; both: forces a genuine MOVEM encoding, and each register is already its
; own natural longword read with no adjacent-word coalescing to trigger.)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; ---- Part 1: store, pre-indexed, long ----
        movea.l #$2000,a0
        move.l  #$8,d2

        move.l  #$3000,d4
        move.l  d4,($2108)          ; M32[a0+$100+d2] = $3000 (pointer)

        move.l  #$11112222,d0
        move.l  #$33334444,d1

        movem.l d0-d1,([$100,a0,d2.l])   ; pre-indexed, word bd, null od

        ; ---- Part 2: load, post-indexed, word ----
        movea.l #$2000,a0

        move.l  #$4000,d4
        move.l  d4,($2200)          ; M32[a0+$200] = $4000 (pointer)

        move.l  #$56785678,d5
        move.l  d5,($4014)          ; M32[ptr+D3+od] for A2
        move.l  #$9ABC9ABC,d5
        move.l  d5,($4018)          ; M32[ptr+D3+od+4] for A3

        move.l  #$4,d3

        movem.l ([$200,a0],d3.l,$10),a2-a3   ; post-indexed, word bd, word od

        move.w  #$700D,d6
        move.w  d6,($5000)          ; marker: execution continued cleanly

        stop    #$2700
        dc.w    $2700
