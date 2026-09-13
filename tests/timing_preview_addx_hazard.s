; tests/timing_preview_addx_hazard.s -- Track 3 #4 (ADDX/SUBX-mem)
; verification: ADDX -(Ay),-(Ax)'s own final beat (phase 2's write ack,
; `addx_mem_final_ack`) is the new preview trigger. Unlike MOVEM/MOVEP,
; no dedicated hazard signal was needed: the ALU result is written to
; MEMORY (not a register), and both Ay/Ax's own predecrement-pointer
; updates commit at EARLIER phases (0 and 1 respectively), strictly
; before phase 2 ever begins -- so by the time this new trigger fires,
; Ax already holds its final, correct (already-decremented) value.
;
;   ADDX.L  -(A2),-(A1)   ; producer: A2,A1 predecrement by 4 each,
;                         ; M[A1-4] = M[A2-4] + M[A1-4] + X, A1/A2 updated
;   MOVE.L  (A1),D3       ; <-- NEXT: base=A1 (already decremented),
;                         ;     should read the FRESH ADDX result
;                         ;     (same address ADDX just wrote)
;
; If the previewed address used a STALE (pre-decrement) A1, or the
; result value weren't genuinely visible yet, this would read the wrong
; address/value -- a genuinely wrong bus read, not just a missed
; optimization.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; tools/m68ksim's own reference model wraps addresses modulo its
        ; 4KB memory window -- every address below stays inside [0,$FFF].
        move.w  #0,ccr           ; clear X (and all other CCR bits)
        move.l  #5,d4
        move.l  d4,$30c           ; source operand ADDX will read at A2-4
        move.l  #10,d4
        move.l  d4,$31c           ; dest operand ADDX will read (and overwrite) at A1-4
        movea.l #$310,a2          ; predecrements to $30C for the read
        movea.l #$320,a1          ; predecrements to $31C for the read+write
        bra.w   target

        org     $200
target:
        addx.l  -(a2),-(a1)      ; <-- producer: M[$31C] = M[$30C]+M[$31C]+X = 5+10+0 = 15
        move.l  (a1),d3          ; <-- NEXT: base=A1=$31C (already decremented), reads 15
        stop    #$2700
        dc.w    $2700
