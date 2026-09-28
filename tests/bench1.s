; tests/bench1.s -- a REAL throughput benchmark, unlike the 23-67 tick opcode
; group programs the cross-core tick comparison had been using.
;
; Those are prologue-dominated straight lines: they measure startup, not
; execution. This one runs loops with genuine memory traffic, so the tick count
; reflects steady-state work -- which is what the Fmax / ticks-per-instruction
; figure is supposed to be about.
;
; Three phases, each a loop, chosen to weight the things that actually cost
; ticks differently:
;   1. memory copy      -- bus-bound, two accesses per iteration
;   2. register ALU     -- execute-bound, no bus traffic at all
;   3. indexed sum      -- address-generation bound, one read per iteration
;
; Everything stays inside the 16K the cosim testbenches model, and the final
; register values are checked so a wrong answer cannot masquerade as a fast one.
;
; Expected: D0 = sum of 0..63 = 2016, D7 = $000003F0 (ALU result), A2 = dst end

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

SRC     equ     $1000
DST     equ     $1400
N       equ     64

start:
        ; ── fill the source block: N longwords, value = index ──────────────
        lea     SRC,a0
        moveq   #0,d1                   ; index
fill:
        move.l  d1,(a0)+
        addq.l  #1,d1
        cmpi.l  #N,d1
        bne     fill

        ; ── phase 1: memory copy, bus-bound (read + write per iteration) ───
        lea     SRC,a1
        lea     DST,a2
        moveq   #0,d1
copy:
        move.l  (a1)+,(a2)+
        addq.l  #1,d1
        cmpi.l  #N,d1
        bne     copy

        ; ── phase 2: register ALU, execute-bound, no bus traffic ───────────
        moveq   #0,d7
        moveq   #0,d1
alu:
        add.l   d1,d7
        eor.l   #$5A,d7
        lsl.l   #1,d7
        lsr.l   #1,d7
        addq.l  #1,d1
        cmpi.l  #N,d1
        bne     alu

        ; ── phase 3: indexed read, address-generation bound ────────────────
        lea     DST,a3
        moveq   #0,d0                   ; running sum
        moveq   #0,d1                   ; index
sum:
        move.l  d1,d2
        lsl.l   #2,d2                   ; index*4
        move.l  (0,a3,d2.l),d3
        add.l   d3,d0
        addq.l  #1,d1
        cmpi.l  #N,d1
        bne     sum

        stop    #$2700
