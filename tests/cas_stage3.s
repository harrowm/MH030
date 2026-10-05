; tests/cas_stage3.s -- dedicated CAS regression for the Stage 3 fix
; (docs/mh030p_architecture.md section 8): cas_eq/cas_skip_wr moved from a
; live ALU read into a registered decision, one cycle after mem_got. CAS has
; zero Harte coverage (68020+-only) and tb/mh030p_core_tb.sv has no CAS case
; at all, so this is the only regression this specific fix gets.
;
; Two CAS.L cycles back to back, deliberately with NO other instruction in
; between, to directly exercise the one-cycle-later timing the fix adds:
;   1. MATCH:    mem == Dc -> mem <- Du, Z=1, Dc unchanged
;   2. MISMATCH: mem != Dc -> Dc <- mem, Z=0, mem unchanged
;
; D7 accumulates a bitmask of failures; D0 = D7 at STOP (0 = all pass).
; Falls straight through on every check -- a failed check sets a bit in D7
; and continues, so one bad run reports every symptom, not just the first.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

MEMLOC  equ     $2000

start:
        moveq   #0,d7                   ; failure bitmask

        ; ── seed memory with a known value ──────────────────────────────────
        move.l  #$12345678,d0
        lea     MEMLOC,a0
        move.l  d0,(a0)

        ; ── CAS #1: match (Dc == mem) -> mem <- Du, Z set, Dc unchanged ─────
        move.l  #$12345678,d0           ; Dc = mem's current value
        move.l  #$AABBCCDD,d1           ; Du = update value
        cas.l   d0,d1,(a0)
        beq     c1_zok
        bset    #0,d7                   ; Z should have been set
c1_zok:
        cmpi.l  #$12345678,d0           ; Dc must be UNCHANGED on a match
        beq     c1_dcok
        bset    #1,d7
c1_dcok:
        move.l  (a0),d2
        cmpi.l  #$AABBCCDD,d2           ; memory must now hold Du
        beq     c1_memok
        bset    #2,d7
c1_memok:

        ; ── CAS #2: mismatch (Dc != mem, mem is now $AABBCCDD) ──────────────
        ; -- mem <- unchanged, Dc <- mem's value, Z clear.
        move.l  #$99999999,d0           ; Dc deliberately wrong
        move.l  #$FFFFFFFF,d1           ; Du -- must NOT reach memory
        cas.l   d0,d1,(a0)
        bne     c2_zok
        bset    #3,d7                   ; Z should have been CLEAR
c2_zok:
        cmpi.l  #$AABBCCDD,d0           ; Dc must now hold the memory value
        beq     c2_dcok
        bset    #4,d7
c2_dcok:
        move.l  (a0),d3
        cmpi.l  #$AABBCCDD,d3           ; memory must be UNCHANGED
        beq     c2_memok
        bset    #5,d7
c2_memok:

        move.l  d7,d0
        stop    #$2700
