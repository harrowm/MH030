; tests/timing/a2_exg.s -- Phase 161 Part A Stage A2: Special-Purpose MOVE
; table "EXG Ry,Rx" row. MC68030UM.pdf 11-39: Head=4,Tail=0, NCC=4(0/1/0).
; D1 directly watched: after exchange D1 must hold D4's old value.
;
;   EXG D1,D4

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d1
        move.l  #$44444444,d4
        bra.w   target

        org     $200
target:
        exg     d1,d4
        stop    #$2700
        dc.w    $2700
