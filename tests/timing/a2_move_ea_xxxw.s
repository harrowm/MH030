; tests/timing/a2_move_ea_xxxw.s -- Phase 161 Part A Stage A2: MOVE table
; "*EA,XXX.W" row (source=Dn, so fea(Dn)=(0,0,0) adds nothing).
; MC68030UM.pdf 11-37: Head=2,Tail=0, NCC=5(0/1/1). Total = fea(Dn) + row.
;
;   MOVE.L D1,$1000.W

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.l  d1,$1000.w
        move.l  #$cafebabe,d2
        stop    #$2700
        dc.w    $2700
