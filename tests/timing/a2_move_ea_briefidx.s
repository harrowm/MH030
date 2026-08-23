; tests/timing/a2_move_ea_briefidx.s -- Phase 161 Part A Stage A2: MOVE
; table "*EA,(d8,An,Xn)" row (source=Dn, fea(Dn)=0). MC68030UM.pdf 11-38:
; Head=4,Tail=0, NCC=7(0/1/1). Also directly re-validates Phase 149's own
; rd_c fix for MOVE Dn,(d8,An,Xn) -- a genuine single-phase write, no
; phantom read, so w=1 not 2.
;
;   MOVE.L D1,(4,A0,D3.L)   -- EA = A0 + D3 + 4 = $3000 + 8 + 4 = $300C

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #8,d3
        move.l  #$11111111,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.l  d1,(4,a0,d3.l)
        move.l  #$cafebabe,d2
        stop    #$2700
        dc.w    $2700
