; tests/memind24.s — Phase 149 (plan.md): MOVE An,(d8,An,Xn) -- the An-source
; sibling of memind15.s's Dn-source case, exercising dec_c_reg's own is_an
; bit (the {(f_mode==3'b001), f_reg} encoding on rd_c) for the first time.
;
;   MOVE.L A2,($100,A0,D1.L)  -- EA = A0+$100+D1
;
; A0=$200, D1=$4, A2=$99887766 (an arbitrary 32-bit value used as data, not
; a real address). Target = $304.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$4,d1
        movea.l #$99887766,a2

        move.l  a2,($100,a0,d1.l)

        stop    #$2700
        dc.w    $2700
