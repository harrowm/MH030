; tests/smoke.s — Phase 73 bare-metal smoke test
; Assembled with: vasmm68k_mot -Fbin -m68030 smoke.s -o smoke.bin
;
; Four-instruction sequence that exercises toolchain + EU pipeline:
;   0x0008: NOP              (no-op; consumes first IFU queue slot)
;   0x000A: MOVEQ #42,D0    (D0 ← 42; one-word immediate)
;   0x000C: ADD.L D0,D0     (D0 ← 84; requires second bus fetch at 0x000C)
;   0x000E: STOP opcode
;   0x0010: STOP immediate   ($2700 → SR = supervisor, I=7)
;
; Expected: D0 = 84 (0x54) when STOP executes.
; stop_seen fires on second instruction fetch (rd_word=0xD0804E72 at 0x000C).

        org     0
        dc.l    $00010000       ; reset SSP  (stack at 64KB)
        dc.l    start           ; reset PC

start:
        nop                     ; 0x0008: 4E71
        moveq   #42,d0          ; 0x000A: 702A  → D0 = 42
        add.l   d0,d0           ; 0x000C: D080  → D0 = 84
        stop    #$2700          ; 0x000E: 4E72 + 0x0010: 2700  (halt, SR=$2700)
