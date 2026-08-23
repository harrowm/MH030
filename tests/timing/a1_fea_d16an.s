; tests/timing/a1_fea_d16an.s — Phase 161 Part A Stage A1: fea "(d16,An)"
; row (the classic, single-extension-word mode=101 form -- NOT the newer
; 68020+ "full format extension word" (d16,An,Xn) mode already covered by
; tests/timing0.s).
; MC68030UM.pdf 11-26: (d16,An) Head=2,Tail=2, NCC=4(1/0/0).
; Combined with MOVE EA,Dn op-table: total r/p/w=1/1/0.
;
;   MOVE.L (4,A0),D2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$DEADBEEF,d1
        move.l  d1,($2004)
        bra.w   target

        org     $200
target:
        move.l  (4,a0),d2
        stop    #$2700
        dc.w    $2700
