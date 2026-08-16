; tests/memind17.s — Phase 140 (plan.md): genuine memory-indirect EA with a
; LONG (32-bit) base displacement AND a word outer displacement together --
; the specific combination fi_od's own old formula silently mis-extracted
; (aliased onto bd's own high half, ext_data[31:16]/q2, instead of reading
; od's real value one word further out at q4/ext34_data[15:0] -- see
; eu_seq.sv's fi_od comment for the full derivation). fi_bd's own long-bd
; extraction (Phase 121) was already correct in isolation; this is the
; first test combining it with genuine indirection.
;
; Same "base register set above the 4KB cosim window, large negative bd
; brings the pointer-read address back into range" technique as
; memind13.s/memind16.s -- |$10000| is outside vasm's +-32768 brief-
; displacement range, forcing full-format long-bd encoding.
;
;   Post-indexed, long bd, word od:
;     ([-$10000,A0],D1.L,$8) -> EA = M32[A0-$10000] + D1 + $8
;
; A0=$10200, D1=$100.
;   pointer read from M32[$200] (=$300); EA = $300 + $100 + $8 = $408

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$10200,a0
        move.l  #$100,d1

        move.l  #$300,d4
        move.l  d4,($200)       ; M32[$200] = $300 (pointer)
        move.l  #$DEAD0011,d4
        move.l  d4,($408)       ; value at final EA

        move.l  ([-$10000,a0],d1.l,$8),d2   ; post-indexed, long bd, word od

        stop    #$2700
        dc.w    $2700
