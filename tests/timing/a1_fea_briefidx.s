; tests/timing/a1_fea_briefidx.s — Phase 161 Part A Stage A1: fea
; "(d8,An,Xn)" brief-format-extension-word row.
; MC68030UM.pdf 11-27: (d8,An,Xn) Head=4,Tail=2, NCC=6(1/1/0).
; Combined with MOVE EA,Dn op-table: total r/p/w=1/2/0.
;
;   MOVE.L (4,A0,D1.L),D2   -- EA = A0 + D1 + d8 = $2000 + 4 + 4 = $2008

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #4,d1
        move.l  #$DEADBEEF,d2
        move.l  d2,($2008)
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.l  (4,a0,d1.l),d2
        stop    #$2700
        dc.w    $2700
