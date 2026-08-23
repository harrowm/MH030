; tests/timing/a2_move_ea_xxxl.s -- Phase 161 Part A Stage A2: MOVE table
; "*EA,XXX.L" row (source=Dn, fea(Dn)=0). MC68030UM.pdf 11-37:
; Head=0,Tail=0, NCC=7(0/2/1).
;
;   MOVE.L D1,$10000.L

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.l  d1,$10000.l
        move.l  #$cafebabe,d2
        stop    #$2700
        dc.w    $2700
