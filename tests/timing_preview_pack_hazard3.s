; tests/timing_preview_pack_hazard3.s -- Track 3 #6 (PACK/UNPK-mem)
; verification, variant 3: non-hazard control for variant 2. NEXT's own
; base register (A3) is NOT the register PACK writes (A1), so
; pack_hazard should read 0 and preview_ok should actually fire (=1)
; live.
;
;   MULU.L D6,D7             ; long artificial stall
;   PACK  -(A2),-(A1),#0     ; producer: A1 predecrements to $31F -- does NOT touch A3
;   MOVE.L (A3),D3           ; <-- NEXT: base=A3 (untouched by PACK)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.b  #$05,$30e
        move.b  #$05,$30f
        movea.l #$310,a2
        movea.l #$320,a1
        movea.l #$330,a3
        move.l  #$C0FFEE00,d5
        move.l  d5,(a3)          ; M[$330] -- NEXT's own real read target
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        pack    -(a2),-(a1),#0   ; <-- producer: M[$31F] = $55, A1 predecrements (A3 untouched)
        move.l  (a3),d3          ; <-- NEXT: base=A3, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700
