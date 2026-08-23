; tests/timing/a2_move_ea_d16an.s -- Phase 161 Part A Stage A2: MOVE table
; "*EA,(d16,An)" row (source=Dn, fea(Dn)=0). MC68030UM.pdf 11-37:
; Head=2,Tail=0, NCC=5(0/1/1).
;
;   MOVE.L D1,(4,A0)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #$11111111,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.l  d1,(4,a0)
        move.l  #$cafebabe,d2
        stop    #$2700
        dc.w    $2700
