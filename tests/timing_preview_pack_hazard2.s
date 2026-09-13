; tests/timing_preview_pack_hazard2.s -- Track 3 #6 (PACK/UNPK-mem)
; verification, variant 2: forces preview_ok to actually FIRE live for
; the hazard case, using the same artificial MULU.L-stall trick
; Phase 256/258/260/262 established.
;
;   MULU.L D6,D7             ; long artificial stall
;   PACK  -(A2),-(A1),#0     ; producer: A1 predecrements to $31F THIS beat
;   MOVE.B (A1),D3           ; <-- NEXT: base=A1, should be blocked from preview

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.b  #$05,$30e
        move.b  #$05,$30f
        move.b  #$CC,$31f
        movea.l #$310,a2
        movea.l #$320,a1
        move.l  #$00030000,d6
        move.l  #$00040000,d7
        bra.w   target

        org     $200
target:
        mulu.l  d6,d7            ; artificial stall -- lets IFU readahead run ahead
        pack    -(a2),-(a1),#0   ; <-- producer: M[$31F] = $55, A1 predecrements to $31F
        move.b  (a1),d3          ; <-- NEXT: base=A1, should be blocked from preview
        stop    #$2700
        dc.w    $2700
