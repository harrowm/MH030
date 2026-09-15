; tests/pack_order2.s -- UNPK's own real destination-write order
; (project_pack_source_read_order_bug.md fix, plan.md): the destination
; write is 2 SEPARATE byte writes via 2 independent 1-byte predecrements,
; the FIRST (HIGH byte) landing at An-1 and the SECOND (LOW byte) at
; An-2 (the final An value) -- the opposite of a standard big-endian
; word write -- not a single 16-bit word access.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$160,a0
        move.l  #$AB,d0
        move.b  d0,(a0)         ; M[$160] = $AB
        movea.l #$161,a0        ; Ay -- predecrements to $160
        movea.l #$182,a1        ; Ax -- predecrements to $180
        unpk    -(a0),-(a1),#0  ; src=$AB -> temp=$0A0B; writes $0A@$181, $0B@$180
        stop    #$2700
        dc.w    $2700
