; tests/pack_order1.s -- PACK's own real source-read order
; (project_pack_source_read_order_bug.md fix, plan.md): the source read
; is 2 SEPARATE byte reads via 2 independent 1-byte predecrements, the
; FIRST landing in the HIGH byte and the SECOND in the LOW byte of the
; intermediate 16-bit value -- the opposite of a standard big-endian
; word read -- not a single 16-bit word access.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$120,a0
        move.l  #$0000ABCD,d0
        move.l  d0,(a0)         ; M[$120..$123] = 00 00 AB CD
        movea.l #$124,a0        ; Ay -- predecrements to $122
        movea.l #$140,a1        ; Ax -- predecrements to $13F
        pack    -(a0),-(a1),#0  ; src = {M[$123],M[$122]} = 0xCDAB -> 0xDB
        stop    #$2700
        dc.w    $2700
