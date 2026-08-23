; tests/timing/a2_swap.s -- Phase 161 Part A Stage A2: Special-Purpose MOVE
; table "SWAP Dn" row. MC68030UM.pdf 11-39: Head=4,Tail=0, NCC=4(0/1/0).
;
;   SWAP D1   ($12340000 -> $00001234)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$12340000,d1
        bra.w   target

        org     $200
target:
        swap    d1
        stop    #$2700
        dc.w    $2700
