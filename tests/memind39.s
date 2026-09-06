; tests/memind39.s — Scc's own genuine memory-indirect EA (Stage 9c, plan.md
; §Phase 245): Scc-to-memory dispatches through the generic (non-locked)
; mem_rmw_run_r FSM shared with ADDQ/SUBQ-to-memory and dynamic bit-ops --
; architecturally the same shape as the general ALU-EA stage (Phase 243),
; not TAS's own RMW-lock restructuring. Verified via the full bus trace: the
; discarded read at the resolved address followed by the write of the
; decode-time-computed FF/00 byte proves the memind-resolved address flows
; correctly into mem_rmw_addr_r's own new memind capture branch.
;
;   Post-indexed, word bd, null od: ([$100,A0],D1.L)
;
; A0=$2000, D1=$8 -> inner=$2100, pointer at M32[$2100]=$3000 -> Scc target
; = pointer+D1 = $3008. TST.B D0 (D0=0) sets Z=1 before SEQ, so SEQ writes
; $FF to the resolved address.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$8,d1
        moveq   #0,d0

        move.l  #$3000,d4
        move.l  d4,($2100)      ; M32[a0+$100] = $3000 (pointer, no d1 here)

        move.b  #$00,($3008)    ; Scc target byte, initial value irrelevant

        tst.b   d0              ; Z=1

        seq.b   ([$100,a0],d1.l)   ; post-indexed, word bd, null od

        move.w  #$600D,d5
        move.w  d5,($3100)      ; marker: execution continued cleanly

        stop    #$2700
        dc.w    $2700
